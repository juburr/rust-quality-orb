#!/bin/bash
#
# Installs rustup for the install_rustup command, verified against the checksum
# table in this file before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (rustup only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# rust-quality-orb installs several tools, so it has one such script per
# tool, in src/install/<tool>/.
#
# Add the checksums for a new release with:
#   src/install/rustup/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing rustup needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="rust-quality-orb-rustup"
TOOL_NAME="rustup"
TOOL_BINARY="rustup"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME: rustup's CARGO_HOME, where rustup-init
# puts rustup and a proxy for each toolchain binary (cargo, rustc, ...) in
# bin. A CARGO_HOME set in the environment is the default instead.
TOOL_DEFAULT_INSTALL_DIR=".cargo"
if [[ -z "${PARAM_INSTALL_PATH:-}" && -n "${CARGO_HOME:-}" ]]; then
    PARAM_INSTALL_PATH=${CARGO_HOME}
fi

# rustup installs Rust toolchains, and switches between them by the
# rust-toolchain.toml of the directory it runs in. This installs rustup
# itself from rustup-init, verified against the checksum table, and then a
# toolchain. rustup checks every toolchain file it downloads against the
# SHA-256 the release's channel manifest lists, and the manifest against its
# published SHA-256, both from static.rust-lang.org (it does not check the
# manifest's GPG signature). install_rust installs a Rust release pinned by
# this orb's own checksum table instead.

# tool_asset_name VERSION ARCH: the file to download, rustup-init, which
# installs itself as rustup. The glibc build: a musl rustup-init would
# install musl toolchains by default.
tool_asset_name() {
    printf 'rustup-init\n'
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf '%s/rustup/archive/%s/%s/%s\n' "${RQ_DOWNLOAD_BASE_URL:-https://static.rust-lang.org}" "$1" "$(rq_gnu_triple "$2")" "$3"
}

# tool_archive_member VERSION ARCH: empty, since the download is the binary.
tool_archive_member() {
    :
}

# tool_version BINARY: prints the installed version without using the
# network.
tool_version() {
    "$1" --version
}

# >>> rust-quality-orb install helpers >>>
# Identical in every tool definition of rust-quality-orb, so change them in
# all of them together. They run inside the shared install logic, through
# tool_install, and only after orb_init has read the parameters (except the
# triple functions, which only map names).

# rq_musl_triple ARCH: the Rust target of the static Linux builds for ARCH.
rq_musl_triple() {
    case "$1" in
        amd64) printf 'x86_64-unknown-linux-musl\n' ;;
        arm64) printf 'aarch64-unknown-linux-musl\n' ;;
        *) printf 'unknown-%s\n' "$1" ;;
    esac
}

# rq_gnu_triple ARCH: the Rust target of the glibc Linux builds for ARCH,
# which Rust and rustup are installed as.
rq_gnu_triple() {
    case "$1" in
        amd64) printf 'x86_64-unknown-linux-gnu\n' ;;
        arm64) printf 'aarch64-unknown-linux-gnu\n' ;;
        *) printf 'unknown-%s\n' "$1" ;;
    esac
}

# rq_download_base_url DEFAULT: sets RQ_DOWNLOAD_BASE_URL from the
# download_base_url parameter, which replaces DEFAULT (https://github.com for
# a GitHub release, https://static.rust-lang.org for Rust and rustup) in the
# download URL, so the same file comes from an internal mirror such as
# Artifactory, Nexus or S3. The checksum table, not the mirror, decides what
# is installed.
rq_download_base_url() {
    local authority
    RQ_DOWNLOAD_BASE_URL=$(orb_subst "${PARAM_DOWNLOAD_BASE_URL:-}")
    RQ_DOWNLOAD_BASE_URL=${RQ_DOWNLOAD_BASE_URL%/}
    if [[ -z "${RQ_DOWNLOAD_BASE_URL}" ]]; then
        return 0
    fi
    # Credentials in the URL would show in the log and on curl's command
    # line, so they are refused before the URL is printed anywhere.
    authority=${RQ_DOWNLOAD_BASE_URL#*://}
    if [[ "${authority%%/*}" == *@* ]]; then
        orb_die "download_base_url must not hold credentials (user:password@ before the host): they would show in the log and on curl's command line."
    fi
    # Nor can a query or fragment, which can hold a token too, and would end
    # up in the middle of every download URL.
    if [[ "${RQ_DOWNLOAD_BASE_URL}" == *[?#]* ]]; then
        orb_die "download_base_url must not have a query or fragment (? or #): it could hold a token, which would show in the log."
    fi
    if [[ ! "${RQ_DOWNLOAD_BASE_URL}" =~ ^https://[^[:space:]\"\'\<\>\\]+$ ]]; then
        orb_die "download_base_url must be an https:// URL, not '${RQ_DOWNLOAD_BASE_URL}'."
    fi
    orb_info "  download mirror:  ${RQ_DOWNLOAD_BASE_URL} (in place of $1)"
}

# rq_install_record METHOD [FIELDS]: writes what was installed, and how,
# beside the binary as .<binary>.install.json, for the commands' run
# records. METHOD is prebuilt, or rustup for a toolchain rustup installed.
# FIELDS, when given, is more JSON members (such as "components":[...]) for
# the record. Every value is one this script validated or computed, so none
# needs JSON escaping.
rq_install_record() {
    local file="${ORB_BIN_DIR}/.${TOOL_BINARY}.install.json" sha512=""
    if command -v sha512sum > /dev/null 2>&1; then
        sha512=$(sha512sum "${ORB_BIN_DIR}/${TOOL_BINARY}" | awk '{ print $1 }')
    fi
    if ! orb_temp_beside "${file}" || ! printf '{"tool":"%s","version":"%s","arch":"%s","method":"%s","asset":"%s","asset_sha512":"%s","verify_checksums":"%s","binary_sha512":"%s"%s}\n' \
        "${TOOL_NAME}" "${ORB_VERSION}" "${ORB_ARCH}" "$1" "${ORB_ASSET_NAME}" "${ORB_EXPECTED_SHA512}" \
        "${ORB_VERIFY_CHECKSUMS}" "${sha512}" "${2:+,$2}" > "${ORB_TEMP}" || ! mv -f "${ORB_TEMP}" "${file}"; then
        orb_warn "Could not write ${file}; run records will not say how ${TOOL_NAME} was installed."
    fi
}

# rq_install_prebuilt: installs the release binary the shared install logic
# downloads and verifies, from the mirror when download_base_url is set.
rq_install_prebuilt() {
    rq_download_base_url https://github.com
    orb_install_binary
    rq_install_record prebuilt
}
# <<< rust-quality-orb install helpers <<<

# rq_rustup_list NAME VALUE: sets RQ_LIST to the words of a list parameter,
# separated by commas or spaces, with environment variables expanded. Each
# must be a component, target or toolchain name.
rq_rustup_list() {
    local value word
    value=$(orb_subst "$2")
    RQ_LIST=()
    for word in ${value//,/ }; do
        if [[ ! "${word}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            orb_die "${1} must list names of letters, digits, '.', '_' and '-', separated by commas or spaces, not '${word}'."
        fi
        RQ_LIST+=("${word}")
    done
}

# rq_toolchain_file: the rust-toolchain.toml (or rust-toolchain) that rustup
# would read in the current directory: the first in it or a parent.
rq_toolchain_file() {
    local dir=${PWD}
    while true; do
        if [[ -f "${dir}/rust-toolchain.toml" ]]; then
            printf '%s\n' "${dir}/rust-toolchain.toml"
            return 0
        elif [[ -f "${dir}/rust-toolchain" ]]; then
            printf '%s\n' "${dir}/rust-toolchain"
            return 0
        fi
        [[ "${dir}" == / || -z "${dir}" ]] && return 1
        dir=${dir%/*}
        dir=${dir:-/}
    done
}

# rq_export NAME VALUE: exports NAME=VALUE to later steps.
rq_export() {
    if [[ -n "${BASH_ENV:-}" ]]; then
        printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
    else
        orb_warn "BASH_ENV is not set, so ${1}=${2} is not exported to later steps. Set it yourself."
    fi
}

# Runs the verified rustup-init, which installs rustup into install_path/bin
# (CARGO_HOME) and its data into RUSTUP_HOME, then installs the toolchain:
# the toolchain parameter, or else the one rust-toolchain.toml names, or else
# stable. A rustup already there (as on cimg/rust) is replaced by the
# verified one, and toolchains it installed stay.
tool_install() {
    local init_dir init rustup_home toolchain_param toolchain="" file="" rustup log
    local -a components targets args
    rq_download_base_url https://static.rust-lang.org
    ORB_BIN_DIR="${ORB_INSTALL_PATH}/bin"
    # rustup_home: RUSTUP_HOME, or else ~/.rustup, or without HOME a
    # .rustup beside install_path.
    if [[ -n "${RUSTUP_HOME:-}" || -n "${HOME:-}" ]]; then
        rustup_home=$(orb_dir_param RUSTUP_HOME "${RUSTUP_HOME:-}" .rustup)
    else
        rustup_home="${ORB_INSTALL_PATH%/*}/.rustup"
    fi
    toolchain_param=$(orb_subst "${PARAM_TOOLCHAIN:-}")
    if [[ -n "${toolchain_param}" && ! "${toolchain_param}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        orb_die "toolchain must be a toolchain name, such as stable, 1.99.1 or nightly-2026-10-01, or none, not '${toolchain_param}'."
    fi
    rq_rustup_list components "${PARAM_COMPONENTS:-}"
    components=(${RQ_LIST[@]+"${RQ_LIST[@]}"})
    rq_rustup_list targets "${PARAM_TARGETS:-}"
    targets=(${RQ_LIST[@]+"${RQ_LIST[@]}"})
    orb_info "  CARGO_HOME:       ${ORB_INSTALL_PATH}"
    orb_info "  RUSTUP_HOME:      ${rustup_home}"

    orb_fetch_verified
    init_dir="${ORB_WORK_DIR}/init"
    init="${init_dir}/rustup-init"
    mkdir "${init_dir}"
    if ! cp "${ORB_VERIFIED_FILE}" "${init}" || ! chmod 0755 "${init}"; then
        orb_die "Could not prepare rustup-init in ${init_dir}."
    fi
    orb_smoke_test "${init}"
    if ! mkdir -p "${ORB_INSTALL_PATH}" "${rustup_home}"; then
        orb_die "Could not create ${ORB_INSTALL_PATH} or ${rustup_home}. Choose an install_path this job's user can write to without root."
    fi
    # A mirror of static.rust-lang.org serves the toolchains too.
    if [[ -n "${RQ_DOWNLOAD_BASE_URL:-}" && -z "${RUSTUP_DIST_SERVER:-}" ]]; then
        export RUSTUP_DIST_SERVER=${RQ_DOWNLOAD_BASE_URL}
        rq_export RUSTUP_DIST_SERVER "${RUSTUP_DIST_SERVER}"
    fi
    export CARGO_HOME=${ORB_INSTALL_PATH} RUSTUP_HOME=${rustup_home}
    log="${ORB_WORK_DIR}/rustup-init.log"
    orb_info "Running rustup-init ${ORB_VERSION}..."
    if ! "${init}" -y --no-modify-path --profile minimal --default-toolchain none > "${log}" 2>&1; then
        orb_warn "rustup-init's output:"
        sed 's/^/  /' "${log}" >&2
        orb_die "rustup-init could not install rustup into ${ORB_INSTALL_PATH}."
    fi
    rustup="${ORB_BIN_DIR}/rustup"
    if [[ ! -x "${rustup}" ]]; then
        orb_die "rustup-init did not install ${rustup}."
    fi
    rq_install_record prebuilt
    # Later steps find rustup's data where this step put it.
    if [[ -z "${HOME:-}" || "${ORB_INSTALL_PATH}" != "${HOME}/.cargo" ]]; then
        rq_export CARGO_HOME "${ORB_INSTALL_PATH}"
    fi
    if [[ -z "${HOME:-}" || "${rustup_home}" != "${HOME}/.rustup" ]]; then
        rq_export RUSTUP_HOME "${rustup_home}"
    fi

    if [[ "${toolchain_param}" == "none" ]]; then
        orb_info "toolchain is none, so no toolchain is installed."
        return 0
    fi
    args=(--profile minimal)
    if [[ "${#components[@]}" -gt 0 ]]; then
        args+=(--component "$(IFS=,; printf '%s' "${components[*]}")")
    fi
    if [[ "${#targets[@]}" -gt 0 ]]; then
        args+=(--target "$(IFS=,; printf '%s' "${targets[*]}")")
    fi
    if [[ -n "${toolchain_param}" ]]; then
        toolchain=${toolchain_param}
    elif file=$(rq_toolchain_file); then
        orb_info "Installing the toolchain ${file} names."
    else
        toolchain=stable
    fi
    if [[ -n "${toolchain}" ]]; then
        orb_info "Installing the ${toolchain} toolchain..."
        "${rustup}" toolchain install "${toolchain}" "${args[@]}" || orb_die "rustup could not install the ${toolchain} toolchain."
        # rust-toolchain.toml still overrides the default where it applies.
        "${rustup}" default "${toolchain}" || orb_die "rustup could not make ${toolchain} the default toolchain."
    else
        # With no name, rustup installs the toolchain the file names, with the
        # components and targets it lists.
        "${rustup}" toolchain install "${args[@]}" || orb_die "rustup could not install the toolchain ${file} names."
    fi
    orb_info "Active toolchain:"
    "${rustup}" show active-toolchain | sed 's/^/  /' || orb_die "rustup has no active toolchain here."
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
declare -A sha512sums=(
    ["1.29.2/amd64"]="d6a77833551d2b0c1ab4e04a6c880b8761f29ffd2859858aabe127d46e5e22a884bd4ac5a89b4ffc7f612eb08217ed71867a09fbae00a1268bd49a4750a7b6e4"
    ["1.29.2/arm64"]="388121fc05dbba75ff9473152ee0bd5ad01498956d9b88125e2856abeaa9cda80af00e2fd1e45e45c9586ea9e9f7927df920dcac1cd2be01dc67dc85ce738566"
    ["1.29.1/amd64"]="ccee644b6d3a342d4f71e6f2d17a670828d4f413330024ed0d9e59edfa3318b9200c5ed0158477cc68aa6c95fbbfe09be912133acf729f70437b82b94e007b4a"
    ["1.29.1/arm64"]="ef63fc310352134fe0635cc2a5ea8c9f6438a84fc8591209e4a8290f0169b849400dfa37ad2c2352bb10b79567d5dded2e2ddc13f2ae4389ad47ce3a40a39894"
    ["1.29.0/amd64"]="245e554e5203df236a4794e595f647bb9019b8664efb1ba1c7faef8f362f9dcc31c7b1475d54e75425962341180612db32ee94cc45256977ea631d75628f43db"
    ["1.29.0/arm64"]="397b6c4272d607eff6b39745fccb938d22cdbf6b850ade0c1003c4c1e16123b3e70fec4e6e13838fb6f3caf5c0ed57e8a36ae642560a5f6787bbc10103e976c7"
    ["1.28.2/amd64"]="8001042452984f280a5ecf7de5654980361c5cbdc003c20b3fcd98426317201d0e21dca40d5f1bbdb1e46c6945d10a05ce3cf6f3a730489b54d4ac19fd312478"
    ["1.28.2/arm64"]="b4adcc9d587b05b261cdae9bec589d262b7d5326bfad8d100bc8066f29ffdcb332053ae018566a5e8f3b2ee177b9eb1595e2c3712fb0a6e935da49c89a56ca59"
    ["1.28.1/amd64"]="37268362079cf312ab977aa31082ba8cf95a356a7983b1515fd08d51584901fa734c9b42917fb9c9260276cf51bdfb4fcda536a71d0682b682428d98f5fa4a5a"
    ["1.28.1/arm64"]="3b731ed44ebe774cab07ea1b7bb8353344b64ff5795f779ddc0336e0f0e8ee280e5957c00c53880d8b3daa0a505796c9b2f8713b95e8ceec891f3a4621e31811"
    ["1.28.0/amd64"]="2a4deeeb1c8123c7b43b9cb2db0bcfea73bc02388cc8b305372305568eeb79309e3f03be41141fb32833d325a1abcb31c3e051392dbbc60bd5e26f1806ab8ba8"
    ["1.28.0/arm64"]="3dbce92c5479af7b9c62592706c638e8498d1b7ed77ca00430ad8a041195216eeeea1c1472af105ecef4cac43abbc35449e70137eda365f1e14d08c80c026f1d"
)
# <<< checksum table <<<

orb_install_main
