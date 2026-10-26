#!/bin/bash
#
# Prints checksum table entries for a Rust release, ready to paste into the
# sha512sums table in install.sh. A development helper: the orb never runs it.
#
#   src/install/rust/install_hash.sh -v <version> [-a "<arch> ..."] [-c <checksum>]
#
#   -a  architectures to hash (default: every one install.sh supports)
#   -c  a checksum for the asset from another official source, as
#       SHA-256:<hex> or SHA1:<hex>, for a release whose published checksums
#       don't cover it (verify_upstream finds nothing); or NONE to add an
#       entry that is not anchored to any published checksum. -c never
#       overrides a failure to fetch or verify what Rust published: re-run
#       once the source is reachable.
#
# The table pins each release's channel manifest, which is the same for every
# architecture, so each architecture gets the same entry. Each manifest's
# signature is checked before its entries are printed (see verify_upstream).
# Needs gpg. Entries go to stdout and everything else to stderr, so the
# output can be pasted as is.

set -euo pipefail

# >>> upstream verification >>>
# The key the Rust project signs its releases with ("Rust Language (Tag and
# Release Signing Key) <rust-key@rust-lang.org>"). Its fingerprint is pinned
# here; the key itself is fetched from static.rust-lang.org, so a changed key
# fails verification instead of vouching for itself.
RUST_KEY_FINGERPRINT="108F66205EAEB0AAA8DD5E1C85AB96E6FA1BE5FE"
RUST_KEY_URL="https://static.rust-lang.org/rust-key.gpg.ascii"

# verify_upstream VERSION ARCH ASSET: checks the manifest against its
# signature (channel-rust-<version>.toml.asc), made with the key whose
# fingerprint is RUST_KEY_FINGERPRINT, and against its published SHA-256,
# then checks that it lists rustc, cargo, rust-std, clippy, rustfmt and
# llvm-tools for ARCH. Returns 0 when it all holds, 2 when no signature was
# published, and 1 otherwise.
verify_upstream() {
    local url triple package sha rc=0
    url=$(tool_asset_urls "$1" "$2" "${3##*/}" | head -n 1)
    if ! command -v gpg > /dev/null; then
        echo "ERROR: gpg is required to check the signature on the Rust manifest."
        return 1
    fi
    hash_fetch "${url}.asc" manifest.asc || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        echo "Rust $1 publishes no signature for its manifest."
        return 2
    elif [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    hash_fetch "${RUST_KEY_URL}" rust-key.asc || return 1
    mkdir -p gnupg
    chmod 0700 gnupg
    if ! gpg --homedir gnupg --batch --quiet --import rust-key.asc > gpg-import.log 2>&1; then
        echo "ERROR: could not import the Rust release key:"
        sed 's/^/  /' gpg-import.log
        return 1
    fi
    # VALIDSIG's last field is the fingerprint of the primary key, whichever
    # of its subkeys made the signature.
    gpg --homedir gnupg --batch --status-fd 1 --verify manifest.asc "$3" > gpg-status.log 2> gpg-verify.log || true
    if ! awk -v fpr="${RUST_KEY_FINGERPRINT}" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == fpr { found = 1 } END { exit !found }' gpg-status.log; then
        echo "ERROR: ${3##*/} is not signed by the Rust release key (${RUST_KEY_FINGERPRINT}):"
        sed 's/^/  /' gpg-verify.log
        return 1
    fi
    echo "ok: ${3##*/} is signed by the Rust release key."
    hash_fetch "${url}.sha256" manifest.sha256 || return 1
    sha=$(awk '{ print $1; exit }' manifest.sha256)
    if [[ "$(sha256sum "$3" | awk '{ print $1 }')" != "${sha}" ]]; then
        echo "ERROR: ${3##*/} does not match its published SHA-256."
        return 1
    fi
    echo "ok: ${3##*/} matches its published SHA-256."
    if ! awk -v version="$1" '$0 == "[pkg.rust]" { f = 1; next } /^\[/ { f = 0 }
        f && $1 == "version" { value = $0; sub(/^[^"]*"/, "", value); split(value, words, " "); found = words[1] == version }
        END { exit !found }' "$3"; then
        echo "ERROR: ${3##*/} is not the manifest of Rust $1."
        return 1
    fi
    triple=$(rq_gnu_triple "$2")
    for package in rustc cargo rust-std clippy-preview rustfmt-preview llvm-tools-preview; do
        if ! awk -v section="[pkg.${package}.target.${triple}]" '$0 == section { f = 1; next } /^\[/ { f = 0 } f && $0 == "available = true" { found = 1 } END { exit !found }' "$3"; then
            echo "ERROR: the Rust $1 manifest has no ${package} for ${triple}."
            return 1
        fi
    done
    echo "ok: it lists rustc, cargo, rust-std, clippy, rustfmt and llvm-tools for ${triple}."
}
# <<< upstream verification <<<

# >>> shared install_hash logic >>>
# Everything from here to the end marker is identical in the install_hash.sh
# of every juburr orb. The tool definition, and with it the asset names and
# URLs, is read from install.sh so the two scripts cannot disagree.

hash_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

hash_usage() {
    printf 'Usage: %s -v <version> [-a "<arch> ..."] [-c SHA-256:<hex> | -c SHA1:<hex> | -c NONE]\n' "$0" >&2
    exit 1
}

# hash_fetch URL DEST [CURL_ARG...]: downloads URL to DEST for verify_upstream.
# Returns 0 on success, 2 when the server says there is no such file (404),
# and 1 on any other failure, which must never be read as "not published".
hash_fetch() {
    local url=$1 dest=$2 code rc=0
    shift 2
    # Without -f, curl exits 0 on an HTTP error, so a non-zero exit is a
    # transfer failure, such as a connection that closed partway.
    code=$(curl -sSL --proto '=https' --proto-redir '=https' --retry 5 --connect-timeout 30 \
        -o "${dest}" -w '%{http_code}' "$@" "${url}") || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: could not download ${url} (curl exit code ${rc})."
        return 1
    fi
    case "${code}" in
        200) return 0 ;;
        404) return 2 ;;
        *)
            echo "ERROR: could not download ${url} (HTTP status ${code:-none})."
            return 1
            ;;
    esac
}

# hash_version_le A B: succeeds if version A sorts at or before version B.
hash_version_le() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]
}

# Loads install.sh's tool definition and shared functions, without its
# checksum table or main call.
INSTALL_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
# shellcheck source=/dev/null
source <(sed -n '/^# >>> tool definition >>>$/,/^# <<< shared install logic <<<$/p' "${INSTALL_SCRIPT}")
if ! declare -F tool_asset_name > /dev/null; then
    hash_die "Could not load the tool definition from ${INSTALL_SCRIPT}."
fi

VERSION=""
ARCHES=""
UPSTREAM_CHECKSUM=""
while getopts ':v:a:c:' flag; do
    case "${flag}" in
        v) VERSION=${OPTARG} ;;
        a) ARCHES=${OPTARG} ;;
        c) UPSTREAM_CHECKSUM=${OPTARG} ;;
        *) hash_usage ;;
    esac
done
VERSION=${VERSION#v}
if [[ -z "${VERSION}" ]]; then
    hash_usage
fi
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    hash_die "Invalid version '${VERSION}'."
fi
ARCHES=${ARCHES:-${TOOL_ARCHES}}
read -r -a ARCH_LIST <<< "${ARCHES}"
if [[ "${#ARCH_LIST[@]}" -eq 0 ]]; then
    hash_die "-a names no architecture. Supported: ${TOOL_ARCHES}."
fi
for arch in "${ARCH_LIST[@]}"; do
    if [[ " ${TOOL_ARCHES} " != *" ${arch} "* ]]; then
        hash_die "Unsupported architecture '${arch}'. Supported: ${TOOL_ARCHES}."
    fi
done
if [[ -n "${UPSTREAM_CHECKSUM}" && "${UPSTREAM_CHECKSUM}" != "NONE" ]]; then
    if [[ ! "${UPSTREAM_CHECKSUM}" =~ ^(SHA-256:[0-9a-f]{64}|SHA1:[0-9a-f]{40})$ ]]; then
        hash_die "-c must be SHA-256:<hex>, SHA1:<hex>, or NONE."
    fi
    if [[ "${#ARCH_LIST[@]}" -gt 1 ]]; then
        hash_die "-c describes one asset, so pick its architecture with -a."
    fi
fi
REQUIRED_TOOLS=(curl sha256sum sha512sum tar gzip)
if [[ "${UPSTREAM_CHECKSUM}" == SHA1:* ]]; then
    REQUIRED_TOOLS+=(sha1sum)
fi
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "${tool}" > /dev/null || hash_die "${tool} is required."
done

HASH_WORK_DIR=$(mktemp -d)
trap 'rm -rf "${HASH_WORK_DIR}"' EXIT

# check_upstream VERSION ARCH ASSET: anchors ASSET to what the project
# published, via verify_upstream (which returns 2 when nothing was published)
# and any checksum supplied with -c.
check_upstream() {
    local rc=0 expected actual
    (cd "${3%/*}" && verify_upstream "$1" "$2" "$3") >&2 || rc=$?
    if [[ "${rc}" -ne 0 && "${rc}" -ne 2 ]]; then
        hash_die "${3##*/} could not be verified against what ${TOOL_NAME} published for ${1}."
    fi
    # NONE only stands in for a checksum that was never published.
    if [[ "${UPSTREAM_CHECKSUM}" == "NONE" ]]; then
        if [[ "${rc}" -eq 2 ]]; then
            printf 'WARN: -c NONE: %s is not checked against any published checksum.\n' "${3##*/}" >&2
        fi
        return 0
    fi
    if [[ -n "${UPSTREAM_CHECKSUM}" ]]; then
        expected=${UPSTREAM_CHECKSUM#*:}
        case "${UPSTREAM_CHECKSUM%%:*}" in
            SHA-256) actual=$(sha256sum "$3" | awk '{ print $1 }') ;;
            SHA1) actual=$(sha1sum "$3" | awk '{ print $1 }') ;;
        esac
        if [[ "${actual}" != "${expected}" ]]; then
            hash_die "${3##*/} does not match the checksum given with -c (${actual})."
        fi
        printf 'ok: %s matches the checksum given with -c.\n' "${3##*/}" >&2
    elif [[ "${rc}" -eq 2 ]]; then
        hash_die "${TOOL_NAME} published no checksum for ${3##*/}. Supply one from another official source with -c," \
            "or pass -c NONE to add the entry unanchored."
    fi
}

ENTRIES=()
for arch in "${ARCH_LIST[@]}"; do
    # orb_extract works in ORB_WORK_DIR and names ORB_ASSET_NAME in messages.
    ORB_WORK_DIR="${HASH_WORK_DIR}/${arch}"
    ORB_ASSET_NAME=$(tool_asset_name "${VERSION}" "${arch}")
    member=$(tool_archive_member "${VERSION}" "${arch}")
    mkdir -p "${ORB_WORK_DIR}"
    mapfile -t urls < <(tool_asset_urls "${VERSION}" "${arch}" "${ORB_ASSET_NAME}")
    if ! orb_download "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${urls[@]}" >&2; then
        hash_die "Could not download ${ORB_ASSET_NAME}. If ${TOOL_NAME} ${VERSION} has no ${arch} build," \
            "leave ${arch} out with -a."
    fi
    check_upstream "${VERSION}" "${arch}" "${ORB_WORK_DIR}/${ORB_ASSET_NAME}"
    # Hashes the same file install.sh verifies, with the same checks on it.
    if ! orb_extract "${ORB_WORK_DIR}/${ORB_ASSET_NAME}" "${member}" >&2; then
        hash_die "Could not take ${member} from ${ORB_ASSET_NAME}."
    fi
    ENTRIES+=("$(printf '    ["%s/%s"]="%s"' "${VERSION}" "${arch}" "$(sha512sum "${ORB_VERIFIED_FILE}" | awk '{ print $1 }')")")
done
# Nothing is printed until every architecture has passed.
printf '%s\n' "${ENTRIES[@]}"
# <<< shared install_hash logic <<<
