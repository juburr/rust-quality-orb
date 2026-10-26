#!/bin/bash
#
# Installs Rust for the install_rust command, verified against the checksum
# table in this file before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (Rust only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# rust-quality-orb installs several tools, so it has one such script per
# tool, in src/install/<tool>/.
#
# Add the checksums for a new release with:
#   src/install/rust/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing Rust needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="rust-quality-orb-rust"
TOOL_NAME="Rust"
TOOL_BINARY="cargo"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME. It is the toolchain's root (the
# prefix it is installed under), and its bin directory goes first on the
# PATH, ahead of rustup's proxies in ~/.cargo/bin on images that have them.
TOOL_DEFAULT_INSTALL_DIR=".rust-quality-orb/rust"

# Installs one Rust release without rustup. Every release publishes a channel
# manifest, channel-rust-<version>.toml, signed with the Rust project's
# release key, that lists every component with the SHA-256 of its archive.
# The checksum table pins that manifest by SHA-512 (install_hash.sh checks
# its signature first), and each component downloaded is checked against the
# SHA-256 the manifest lists, so one table entry per release covers rustc,
# cargo, the standard library and any optional component.

# tool_asset_name VERSION ARCH: the file the checksum table describes: the
# release's channel manifest, the same for every architecture.
tool_asset_name() {
    printf 'channel-rust-%s.toml\n' "$1"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf '%s/dist/%s\n' "${RQ_DOWNLOAD_BASE_URL:-https://static.rust-lang.org}" "$3"
}

# tool_archive_member VERSION ARCH: empty, since the manifest is a plain file.
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

# The optional components the components parameter can add, by the name
# rustup gives them. Every installation has rustc, cargo and rust-std.
RQ_RUST_OPTIONAL_COMPONENTS="clippy rustfmt llvm-tools rust-src"

# rq_rust_tree DIR: whether DIR is a Rust installation this script may
# replace: one with bin/rustc and the rust-installer metadata every component
# archive's install.sh writes.
rq_rust_tree() {
    [[ -f "$1/bin/rustc" && -f "$1/lib/rustlib/rust-installer-version" ]]
}

# rq_rust_list NAME VALUE: sets RQ_LIST to the words of a list parameter,
# separated by commas or spaces, with environment variables expanded.
rq_rust_list() {
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

# rq_manifest_package NAME: the package name the manifest uses for the
# component rustup calls NAME, following its [renames] table (clippy is
# clippy-preview, for example).
rq_manifest_package() {
    local renamed
    renamed=$(awk -v section="[renames.$1]" '
        $0 == section { found = 1; next }
        /^\[/ { found = 0 }
        found && $1 == "to" { value = $0; sub(/^[^"]*"/, "", value); sub(/".*$/, "", value); print value; exit }
    ' "${ORB_VERIFIED_FILE}")
    printf '%s\n' "${renamed:-$1}"
}

# rq_manifest_entry PACKAGE TARGET: prints the archive URL and its SHA-256,
# on one line, for PACKAGE built for TARGET: the .tar.xz when xz is
# installed, else the .tar.gz. Prints nothing when the manifest doesn't list
# PACKAGE for TARGET as available.
rq_manifest_entry() {
    local prefix=""
    if command -v xz > /dev/null 2>&1; then
        prefix=xz_
    fi
    awk -v section="[pkg.$1.target.$2]" -v prefix="${prefix}" '
        function value(line) { sub(/^[^"]*"/, "", line); sub(/"[^"]*$/, "", line); return line }
        $0 == section { found = 1; next }
        /^\[/ { if (found) exit; next }
        found && $1 == "available" { available = $3 }
        found && $1 == prefix "url" { url = value($0) }
        found && $1 == prefix "hash" { hash = value($0) }
        END { if (available == "true" && url != "" && hash != "") print url, hash }
    ' "${ORB_VERIFIED_FILE}"
}

# rq_fetch_component FILE URL SHA256: downloads a component archive to FILE,
# from the cache when it holds a copy that matches SHA256, and checks it. A
# verified archive is cached when the manifest was verified.
rq_fetch_component() {
    local file=$1 url=$2 expected=$3 actual cached="" from_cache=false
    if [[ "${ORB_CACHING}" == "true" && -n "${ORB_EXPECTED_SHA512}" ]]; then
        cached="${ORB_CACHE_FILE%/*}/${file##*/}"
    fi
    if [[ -n "${cached}" && -f "${cached}" ]] && cp "${cached}" "${file}"; then
        from_cache=true
    elif ! orb_download "${file}" "${url}"; then
        orb_die "Could not download ${url}. Re-run the job if the download host was failing."
    fi
    actual=$(sha256sum "${file}" | awk '{ print $1 }')
    if [[ "${actual}" != "${expected}" && "${from_cache}" == "true" ]]; then
        orb_warn "The cached ${file##*/} does not match the manifest's SHA-256. Discarding it and downloading it again."
        rm -f "${cached}" 2> /dev/null || true
        from_cache=false
        orb_download "${file}" "${url}" || orb_die "Could not download ${url}. Re-run the job if the download host was failing."
        actual=$(sha256sum "${file}" | awk '{ print $1 }')
    fi
    if [[ "${actual}" != "${expected}" ]]; then
        orb_die "${file##*/} does not match the SHA-256 the Rust ${ORB_VERSION} manifest lists for it, so nothing was installed." \
            "Expected ${expected}, got ${actual}."
    fi
    orb_info "  ${file##*/}: matches the manifest's SHA-256${cached:+ ($([[ "${from_cache}" == "true" ]] && echo "from the cache" || echo "downloaded"))}."
    if [[ -n "${cached}" && "${from_cache}" == "false" ]]; then
        if ! { mkdir -p "${cached%/*}" && orb_temp_beside "${cached}" && cp "${file}" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${cached}"; }; then
            orb_warn "Could not save ${file##*/} to ${cached%/*}; continuing without the cache."
        fi
    fi
}

# Installs the release in install_path. The components are unpacked and
# installed with their own install.sh into a private directory beside
# install_path, whose cargo and rustc run once (orb_smoke_test) before it
# takes install_path's place, so a release that can't run here leaves an
# existing installation in place. install_path must be missing, hold no files
# (only empty directories, if any), or be an earlier Rust installation, so
# that a mistyped install_path such as $HOME is never moved aside and deleted.
tool_install() {
    local dir=${ORB_INSTALL_PATH%/*} name=${ORB_INSTALL_PATH##*/} staging="" host component package target entry url hash
    local file unpack manifest_version log rustc_version
    local -a components targets installed=() wanted installers
    rq_download_base_url https://static.rust-lang.org
    ORB_BIN_DIR="${ORB_INSTALL_PATH}/bin"
    rq_rust_list components "${PARAM_COMPONENTS:-}"
    components=(${RQ_LIST[@]+"${RQ_LIST[@]}"})
    for component in ${components[@]+"${components[@]}"}; do
        if [[ " ${RQ_RUST_OPTIONAL_COMPONENTS} " != *" ${component} "* ]]; then
            orb_die "components can name ${RQ_RUST_OPTIONAL_COMPONENTS// /, }, not '${component}'." \
                "rustc, cargo and the standard library are always installed. Use install_rustup for others."
        fi
    done
    rq_rust_list targets "${PARAM_TARGETS:-}"
    targets=(${RQ_LIST[@]+"${RQ_LIST[@]}"})
    if [[ -L "${ORB_INSTALL_PATH}" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} is a symbolic link. Point install_path at the directory itself."
    fi
    if [[ -e "${ORB_INSTALL_PATH}" && ! -d "${ORB_INSTALL_PATH}" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} exists and is not a directory."
    fi
    # Empty directories hold nothing to lose, such as a bin directory put on
    # the PATH before the install.
    if [[ -d "${ORB_INSTALL_PATH}" ]] && ! rq_rust_tree "${ORB_INSTALL_PATH}" \
        && [[ -n "$(find "${ORB_INSTALL_PATH}" -mindepth 1 ! -type d -print -quit 2>&1)" ]]; then
        orb_die "install_path ${ORB_INSTALL_PATH} holds something other than a Rust installation, which this install would replace." \
            "Choose a new or empty directory, or one an earlier install_rust installed into."
    fi
    orb_require_tools tar gzip sha256sum
    orb_info "  components:       rustc cargo rust-std${components[*]:+ ${components[*]}}"
    if [[ "${#targets[@]}" -gt 0 ]]; then
        orb_info "  targets:          ${targets[*]}"
    fi
    orb_fetch_verified
    manifest_version=$(awk '$0 == "[pkg.rust]" { found = 1; next } /^\[/ { found = 0 } found && $1 == "version" { sub(/^[^"]*"/, ""); sub(/[ "].*$/, ""); print; exit }' "${ORB_VERIFIED_FILE}")
    if [[ "${manifest_version}" != "${ORB_VERSION}" ]]; then
        orb_die "${ORB_ASSET_NAME} is the manifest of Rust '${manifest_version:-an unknown version}', not ${ORB_VERSION}."
    fi
    host=$(rq_gnu_triple "${ORB_ARCH}")

    # package:target pairs, in install order.
    wanted=("rustc:${host}" "cargo:${host}" "rust-std:${host}")
    for target in ${targets[@]+"${targets[@]}"}; do
        if [[ "${target}" != "${host}" ]]; then
            wanted+=("rust-std:${target}")
        fi
    done
    for component in ${components[@]+"${components[@]}"}; do
        package=$(rq_manifest_package "${component}")
        # rust-src is the same for every target, which the manifest
        # writes as the target "*", quotes included.
        if [[ "${component}" == rust-src ]]; then
            wanted+=("${package}:\"*\"")
        else
            wanted+=("${package}:${host}")
        fi
    done

    dir=${dir:-/}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if staging=$(mktemp -d "${dir%/}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    else
        orb_die "Could not install Rust to ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    mkdir "${ORB_WORK_DIR}/components"
    orb_info "Verifying each component against the SHA-256 the manifest lists for it..."
    for entry in "${wanted[@]}"; do
        package=${entry%%:*}
        target=${entry#*:}
        read -r url hash <<< "$(rq_manifest_entry "${package}" "${target}")"
        if [[ -z "${url}" ]]; then
            orb_die "Rust ${ORB_VERSION} has no ${package} for ${target//\"/}."
        fi
        if [[ ! "${hash}" =~ ^[0-9a-f]{64}$ || "${url}" != https://static.rust-lang.org/dist/* || "${url##*/}" == .* || "${url}" == *[[:space:]]* ]]; then
            orb_die "The manifest's entry for ${package} (${target//\"/}) is malformed."
        fi
        # The mirror serves the same paths as static.rust-lang.org.
        url="${RQ_DOWNLOAD_BASE_URL:-https://static.rust-lang.org}${url#https://static.rust-lang.org}"
        file="${ORB_WORK_DIR}/components/${url##*/}"
        rq_fetch_component "${file}" "${url}" "${hash}"
        unpack="${ORB_WORK_DIR}/unpack"
        rm -rf "${unpack}"
        mkdir "${unpack}"
        if ! tar -xf "${file}" -o -C "${unpack}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_die "Could not unpack ${file##*/}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
        fi
        log="${ORB_WORK_DIR}/install-${package}.log"
        # Each archive holds one directory with its own installer.
        installers=("${unpack}"/*/install.sh)
        if [[ "${#installers[@]}" -ne 1 || ! -f "${installers[0]}" || -L "${installers[0]}" ]]; then
            orb_die "${file##*/} does not hold one component installer (<directory>/install.sh)."
        fi
        if ! bash "${installers[0]}" --prefix="${staging}/rust" --disable-ldconfig > "${log}" 2>&1; then
            orb_warn "The installer's output:"
            sed 's/^/  /' "${log}" >&2
            orb_die "Could not install ${package} from ${file##*/}."
        fi
        rm -f "${file}"
        installed+=("${package}")
    done
    rm -rf "${unpack}"
    if ! rq_rust_tree "${staging}/rust" || [[ ! -x "${staging}/rust/bin/cargo" ]]; then
        orb_die "The Rust ${ORB_VERSION} components did not install cargo and rustc."
    fi
    orb_smoke_test "${staging}/rust/bin/cargo"
    if ! rustc_version=$("${staging}/rust/bin/rustc" --version 2>&1); then
        orb_die "The installed rustc cannot run on this machine: ${rustc_version}"
    fi
    orb_info "rustc reports:"
    orb_info "  ${rustc_version}"
    # The earlier installation moves into the staging directory, which the
    # EXIT trap removes, and comes back if the new one can't take its place.
    if [[ -d "${ORB_INSTALL_PATH}" ]] && ! mv "${ORB_INSTALL_PATH}" "${staging}/previous"; then
        orb_die "Could not replace ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    if ! mv "${staging}/rust" "${ORB_INSTALL_PATH}"; then
        if [[ -d "${staging}/previous" ]]; then
            mv "${staging}/previous" "${ORB_INSTALL_PATH}" || true
        fi
        orb_die "Could not install Rust to ${ORB_INSTALL_PATH}. Choose an install_path this job's user can write to without root."
    fi
    rq_install_record prebuilt "$(printf '"components":[%s],"targets":[%s]' \
        "$(printf '"%s",' "${installed[@]}" | sed 's/,$//')" \
        "$(printf '"%s",' "${host}" ${targets[@]+"${targets[@]}"} | sed 's/,$//')")"
    if [[ -f rust-toolchain.toml || -f rust-toolchain ]]; then
        orb_warn "This directory has a $( [[ -f rust-toolchain.toml ]] && echo rust-toolchain.toml || echo rust-toolchain )," \
            "which only rustup reads: the Rust ${ORB_VERSION} installed here ignores it. Use install_rustup to follow it."
    fi
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
    ["1.99.1/amd64"]="dda2f85169343a39e0fedb29d147f3d16ee77743872ac4aebbe33587849cc213c6e82604a45970ccc6a7400abce0c1a2897e783ef34f6a87bc695cae7d427c46"
    ["1.99.1/arm64"]="dda2f85169343a39e0fedb29d147f3d16ee77743872ac4aebbe33587849cc213c6e82604a45970ccc6a7400abce0c1a2897e783ef34f6a87bc695cae7d427c46"
    ["1.99.0/amd64"]="96670cfac63dc6a3bfd782c420ed9612ee12db36ddda281f4fdfa64855c606b2189906d8e9d65ba7e3727860e28e141ba1194574352af336d325b2154ab346d4"
    ["1.99.0/arm64"]="96670cfac63dc6a3bfd782c420ed9612ee12db36ddda281f4fdfa64855c606b2189906d8e9d65ba7e3727860e28e141ba1194574352af336d325b2154ab346d4"
    ["1.98.1/amd64"]="11265f8ca860744448759cb117e62ca6267ea6e8f3c034f0ded9e02e3febaf31334a2120ea31b327ca21e6cf88149bd3ed4ad92ca46085042845a3824891d764"
    ["1.98.1/arm64"]="11265f8ca860744448759cb117e62ca6267ea6e8f3c034f0ded9e02e3febaf31334a2120ea31b327ca21e6cf88149bd3ed4ad92ca46085042845a3824891d764"
    ["1.98.0/amd64"]="b42ee1ac23f866f9eaf930ab47e27a8d897a5e6e2d9afeb8a430ecfa0aa59d809d81431b2e152bd9fdb32dc7f87be7ebd497b058de8b6b44a1f1a490dd4421e6"
    ["1.98.0/arm64"]="b42ee1ac23f866f9eaf930ab47e27a8d897a5e6e2d9afeb8a430ecfa0aa59d809d81431b2e152bd9fdb32dc7f87be7ebd497b058de8b6b44a1f1a490dd4421e6"
    ["1.97.1/amd64"]="be639903d990cfdb9f8e592fd860c5cfdff3b57a98cb630909d25a2191bf997b9d857fec82b71536e226029c6f7c420c5b29b9ddec70946efffb45c0bcd8293e"
    ["1.97.1/arm64"]="be639903d990cfdb9f8e592fd860c5cfdff3b57a98cb630909d25a2191bf997b9d857fec82b71536e226029c6f7c420c5b29b9ddec70946efffb45c0bcd8293e"
    ["1.97.0/amd64"]="a7409623ad04f9fd42aef918f72e64c33f3a05dfdbd217fc8965f738ce09d4697828764ee30aaee39cf7d750b28283ad416b7aeb43dbd488e627c7c7319c8a7e"
    ["1.97.0/arm64"]="a7409623ad04f9fd42aef918f72e64c33f3a05dfdbd217fc8965f738ce09d4697828764ee30aaee39cf7d750b28283ad416b7aeb43dbd488e627c7c7319c8a7e"
    ["1.96.1/amd64"]="2d0a868126c8bda52ad393181783be2924f4627b81646b4a34fe0002445e508ec4945582a524a6590dc5e3d24a3f27e25e9c81e223d390baae88bd80db4b6f21"
    ["1.96.1/arm64"]="2d0a868126c8bda52ad393181783be2924f4627b81646b4a34fe0002445e508ec4945582a524a6590dc5e3d24a3f27e25e9c81e223d390baae88bd80db4b6f21"
    ["1.96.0/amd64"]="0e3ff1aee6937bda81d1ed2abddd53983397f44e037a9032dae8ec8a3a88290094de1ea866859556a5cb02ee434fe300af3a9e2f88ff20d75941cc1b1ca3c437"
    ["1.96.0/arm64"]="0e3ff1aee6937bda81d1ed2abddd53983397f44e037a9032dae8ec8a3a88290094de1ea866859556a5cb02ee434fe300af3a9e2f88ff20d75941cc1b1ca3c437"
    ["1.95.0/amd64"]="45423e5db8194e28682adc4005ed841af2dcd18b94d4b26a34116587bf24719167e45e00a09263e4e925a46fb02de18a554d9d47c1d342ecaf1fe034c111b0ca"
    ["1.95.0/arm64"]="45423e5db8194e28682adc4005ed841af2dcd18b94d4b26a34116587bf24719167e45e00a09263e4e925a46fb02de18a554d9d47c1d342ecaf1fe034c111b0ca"
    ["1.94.1/amd64"]="e5a1c51cfce8a78e6523700cd2afa50d99ac047c41065c61a75e753d4be1e861f6497930a5a109ec1992058e55dc64537980aba1002b9e4d1ae769aad6d6a1cf"
    ["1.94.1/arm64"]="e5a1c51cfce8a78e6523700cd2afa50d99ac047c41065c61a75e753d4be1e861f6497930a5a109ec1992058e55dc64537980aba1002b9e4d1ae769aad6d6a1cf"
    ["1.94.0/amd64"]="84b41ae47508c51b77c89dfca1d46d20d12b18d6e7eb71f1666ecc680e1d16fcfdb0cb840491a67566caf5b07f1ce2aaf4d14ce75055f86732665e93e0222648"
    ["1.94.0/arm64"]="84b41ae47508c51b77c89dfca1d46d20d12b18d6e7eb71f1666ecc680e1d16fcfdb0cb840491a67566caf5b07f1ce2aaf4d14ce75055f86732665e93e0222648"
    ["1.93.1/amd64"]="ab6fb006fe7fe65d0ca83698765b8c3f7b8dbb8f83ffbd617b3b12a09085d769e42e9c26721c94ae229eb15f3b3e61a79e959c30d9e582235f5904101e95c08f"
    ["1.93.1/arm64"]="ab6fb006fe7fe65d0ca83698765b8c3f7b8dbb8f83ffbd617b3b12a09085d769e42e9c26721c94ae229eb15f3b3e61a79e959c30d9e582235f5904101e95c08f"
    ["1.93.0/amd64"]="4281bf5f407f168212eba711b25c8e452fb62912db27f17e448ee07973e82c92a340cf25b8728ce81d710112ed360049fc996126ff0cfaf32958621cfabb0e2a"
    ["1.93.0/arm64"]="4281bf5f407f168212eba711b25c8e452fb62912db27f17e448ee07973e82c92a340cf25b8728ce81d710112ed360049fc996126ff0cfaf32958621cfabb0e2a"
    ["1.92.0/amd64"]="0a8fc59360a5e6f3236d9a35ce2c8e0ba184e8be9b5a918f9bc7aae3e5cc1f8133eaa01fd044fdc6ba645805a98aa645e343fbb7b15a850ea0e83ff20d42ebaa"
    ["1.92.0/arm64"]="0a8fc59360a5e6f3236d9a35ce2c8e0ba184e8be9b5a918f9bc7aae3e5cc1f8133eaa01fd044fdc6ba645805a98aa645e343fbb7b15a850ea0e83ff20d42ebaa"
    ["1.91.1/amd64"]="4fd88f3beaa86addbf1d78f6719e7d303610d918359fb0302b654a0769f84eb9600861961666545cd6c71361c3872ae20823bfdb6f779c4bedf98c9e683a0556"
    ["1.91.1/arm64"]="4fd88f3beaa86addbf1d78f6719e7d303610d918359fb0302b654a0769f84eb9600861961666545cd6c71361c3872ae20823bfdb6f779c4bedf98c9e683a0556"
    ["1.91.0/amd64"]="d14f0134f03551f067602c8af8b12d5c2a105b0160797a948dd7420046700004ff5a9fc562f0220832a0662622dcaabc7f8dd600513b21e4c48c26e5aeeb8011"
    ["1.91.0/arm64"]="d14f0134f03551f067602c8af8b12d5c2a105b0160797a948dd7420046700004ff5a9fc562f0220832a0662622dcaabc7f8dd600513b21e4c48c26e5aeeb8011"
    ["1.90.0/amd64"]="f8a861d7d30aa134b19f1f5b6cd178ccd2c48554bb01b98590bd12d5f12ead0cd8b3eff3a85709fce68ab60fe124cb675c99ed8389aaa36d43c5bdbaa360ce5a"
    ["1.90.0/arm64"]="f8a861d7d30aa134b19f1f5b6cd178ccd2c48554bb01b98590bd12d5f12ead0cd8b3eff3a85709fce68ab60fe124cb675c99ed8389aaa36d43c5bdbaa360ce5a"
    ["1.89.0/amd64"]="793e0c42d9adc4b4ecb7ba1832a8d19d31456ae7a256c8bee3b0a816c460d9ea2aa57d0faa6ab56968f5f7a92130855f8ea7a23bbfcecd6728f6f2eef2892294"
    ["1.89.0/arm64"]="793e0c42d9adc4b4ecb7ba1832a8d19d31456ae7a256c8bee3b0a816c460d9ea2aa57d0faa6ab56968f5f7a92130855f8ea7a23bbfcecd6728f6f2eef2892294"
    ["1.88.0/amd64"]="736675dad598791642bf2dc9e9167b5a62985cd9169b7f6965106d09c726c8908a80add59ab600418cc018b5b5edac5e3bd05a310fd367a819e4e1109084d5cc"
    ["1.88.0/arm64"]="736675dad598791642bf2dc9e9167b5a62985cd9169b7f6965106d09c726c8908a80add59ab600418cc018b5b5edac5e3bd05a310fd367a819e4e1109084d5cc"
    ["1.87.0/amd64"]="55a87355ed2440f62755b8c4e5452d22ec85121c885b1d58a7009b989a361e1e9ac56206f83f232e1dd0b66bccbd3db5853cdb9f1e24a5b9b71185764f42a386"
    ["1.87.0/arm64"]="55a87355ed2440f62755b8c4e5452d22ec85121c885b1d58a7009b989a361e1e9ac56206f83f232e1dd0b66bccbd3db5853cdb9f1e24a5b9b71185764f42a386"
    ["1.86.0/amd64"]="9135445482255f9a12191052f8a78359df552418974f99e845de7a0cf604bb3a10f7623dd1fb8f0c84a3476c682066b8b380824a6414fa1a27931a45e9d826e4"
    ["1.86.0/arm64"]="9135445482255f9a12191052f8a78359df552418974f99e845de7a0cf604bb3a10f7623dd1fb8f0c84a3476c682066b8b380824a6414fa1a27931a45e9d826e4"
    ["1.85.1/amd64"]="12c95e36e96df688f2d4a43dbde42fb05e3f9f8980d5e25d1d4c82b6e6942557c1c904afea1603991557c972b1b566c1eef3336143adc47d44f8eb9b109688e3"
    ["1.85.1/arm64"]="12c95e36e96df688f2d4a43dbde42fb05e3f9f8980d5e25d1d4c82b6e6942557c1c904afea1603991557c972b1b566c1eef3336143adc47d44f8eb9b109688e3"
    ["1.85.0/amd64"]="16205fe052c437f59d30d119b79df4c29a6cca257bf0a0514bcb0eda8b8f5e3d0204de75ed70406f7326fbb58c1213aa0b04b8fa576cd72dbe5d0e7ec23823c9"
    ["1.85.0/arm64"]="16205fe052c437f59d30d119b79df4c29a6cca257bf0a0514bcb0eda8b8f5e3d0204de75ed70406f7326fbb58c1213aa0b04b8fa576cd72dbe5d0e7ec23823c9"
    ["1.84.1/amd64"]="6563ccd3edcc01c50a52193f634a81a968203666be884641c8150e0cbcff1642101e7e0ffe384d6f573bbb95d2a4f2cdb3462f1881fc2559c6da2dbc44f17f6f"
    ["1.84.1/arm64"]="6563ccd3edcc01c50a52193f634a81a968203666be884641c8150e0cbcff1642101e7e0ffe384d6f573bbb95d2a4f2cdb3462f1881fc2559c6da2dbc44f17f6f"
    ["1.84.0/amd64"]="4b403dd7ad3999504c676d3954b92e4e28ea2bdb3a75ca2570654e5884ece980f21241c248d41525815cad0db2afcf75500c6af1b5d573296ad8e7a7eb7d575e"
    ["1.84.0/arm64"]="4b403dd7ad3999504c676d3954b92e4e28ea2bdb3a75ca2570654e5884ece980f21241c248d41525815cad0db2afcf75500c6af1b5d573296ad8e7a7eb7d575e"
    ["1.83.0/amd64"]="a4108296665612c9f67a080087284bbf8c4aaf2af05c7941dd3c06563cf593c82fc1761a26dfd81f62b76746c534a2e57282c2bce18015a82a8f244f66c7b9a2"
    ["1.83.0/arm64"]="a4108296665612c9f67a080087284bbf8c4aaf2af05c7941dd3c06563cf593c82fc1761a26dfd81f62b76746c534a2e57282c2bce18015a82a8f244f66c7b9a2"
    ["1.82.0/amd64"]="cd9f5b7247fb4b14deea4f1628c183b4fd552330591e24f2746542f4dce4e3efabad23f257af2e38b313b12e0397a08a00376c9fc2d01d87f12f342b4d0ef26a"
    ["1.82.0/arm64"]="cd9f5b7247fb4b14deea4f1628c183b4fd552330591e24f2746542f4dce4e3efabad23f257af2e38b313b12e0397a08a00376c9fc2d01d87f12f342b4d0ef26a"
    ["1.81.0/amd64"]="ec4ab7b08513cdec6cf517b40221c4089b220cbe8e32097339790b0bc4e1ea1dfe4b462fe6429ae839001ea5d1157036c9abf544f17b3aa242079ccd4f15acb1"
    ["1.81.0/arm64"]="ec4ab7b08513cdec6cf517b40221c4089b220cbe8e32097339790b0bc4e1ea1dfe4b462fe6429ae839001ea5d1157036c9abf544f17b3aa242079ccd4f15acb1"
    ["1.80.1/amd64"]="67b50e3fee4251cd4f4f15a957dce49b07f09e97974886c6f32f6ba4e9181968a233baa9771eaa8e31fe413d5b0d6600dd4d6c765cc405f8de98eb89ba7cdf65"
    ["1.80.1/arm64"]="67b50e3fee4251cd4f4f15a957dce49b07f09e97974886c6f32f6ba4e9181968a233baa9771eaa8e31fe413d5b0d6600dd4d6c765cc405f8de98eb89ba7cdf65"
    ["1.80.0/amd64"]="26fadf8adab3aab142d520253d6720f5e1581f6dfa89e6602700f654d84f2ce352ad02721862b3549a849bdb593a509a0c5b2c8a65984ab98dd46fc8b521b256"
    ["1.80.0/arm64"]="26fadf8adab3aab142d520253d6720f5e1581f6dfa89e6602700f654d84f2ce352ad02721862b3549a849bdb593a509a0c5b2c8a65984ab98dd46fc8b521b256"
    ["1.79.0/amd64"]="4443eab84e3e554ee2e37b9535504b795d9c3a7adb2ba9b2b87fa3317c1ce4d8f1d76e840940090f4978e47acfe91a346080b1c34c7b6178e87728ec20fafccc"
    ["1.79.0/arm64"]="4443eab84e3e554ee2e37b9535504b795d9c3a7adb2ba9b2b87fa3317c1ce4d8f1d76e840940090f4978e47acfe91a346080b1c34c7b6178e87728ec20fafccc"
    ["1.78.0/amd64"]="8e3492fa79ab3baf3d6d3a846df052f1a78c2fa9c01bf9d661bd66f899c7bef2d8cf2a93ca8feacf45ff36f11e208ea5d7061f67d4dc270314a4db074f8355b0"
    ["1.78.0/arm64"]="8e3492fa79ab3baf3d6d3a846df052f1a78c2fa9c01bf9d661bd66f899c7bef2d8cf2a93ca8feacf45ff36f11e208ea5d7061f67d4dc270314a4db074f8355b0"
    ["1.77.2/amd64"]="c3abe2c41bb3bcc04dce08bde042e0710036dc076452779604906dc9689e1c4c957561529d366c8cc850840c0aa4637e15ee2a9b0e9e1a5dd28ad214aab767b9"
    ["1.77.2/arm64"]="c3abe2c41bb3bcc04dce08bde042e0710036dc076452779604906dc9689e1c4c957561529d366c8cc850840c0aa4637e15ee2a9b0e9e1a5dd28ad214aab767b9"
    ["1.77.1/amd64"]="a9395192dfd053d8e5a7e8bd42bfc713492505b9c96961195d1b41fbf7e811154547f94d15f5b06a7bce1290c6b9c932dc3a2b99853d7ab93bf45aa6673a4beb"
    ["1.77.1/arm64"]="a9395192dfd053d8e5a7e8bd42bfc713492505b9c96961195d1b41fbf7e811154547f94d15f5b06a7bce1290c6b9c932dc3a2b99853d7ab93bf45aa6673a4beb"
    ["1.77.0/amd64"]="c3f749516adb640c93d6c8c6b5dfcdd4b1f5b0973dca807444ca9544db0d03ef2e43b04114c38aa2283e933f9ba69ae8952ad3070e1575e98f2aa0df98a17b54"
    ["1.77.0/arm64"]="c3f749516adb640c93d6c8c6b5dfcdd4b1f5b0973dca807444ca9544db0d03ef2e43b04114c38aa2283e933f9ba69ae8952ad3070e1575e98f2aa0df98a17b54"
    ["1.76.0/amd64"]="aff2a00ec466c1e30afc8bd62c7283ec4552ef56f76963623f8ef9fa9ea6c1cf59e7097d0b157068126c10e4084a7ea8e11369b1062cc0e5b5493beee0ae225f"
    ["1.76.0/arm64"]="aff2a00ec466c1e30afc8bd62c7283ec4552ef56f76963623f8ef9fa9ea6c1cf59e7097d0b157068126c10e4084a7ea8e11369b1062cc0e5b5493beee0ae225f"
    ["1.75.0/amd64"]="105c750daa34e6c203fa69fc40f55e43e79a18572fb909d4c03e50799f0499b1690c2c16cfbbce13cf4f47f17aecb621110576d8077c1056c108f7e825a4f7f1"
    ["1.75.0/arm64"]="105c750daa34e6c203fa69fc40f55e43e79a18572fb909d4c03e50799f0499b1690c2c16cfbbce13cf4f47f17aecb621110576d8077c1056c108f7e825a4f7f1"
    ["1.74.1/amd64"]="348c6a173731340445e3cfc589ebd18edca96312f8d700fb8df7ca4ff004f7fb21aedb5dfd05c4ff6ddecd7b075c3e0818981e362aa344bf31e44637af0fe396"
    ["1.74.1/arm64"]="348c6a173731340445e3cfc589ebd18edca96312f8d700fb8df7ca4ff004f7fb21aedb5dfd05c4ff6ddecd7b075c3e0818981e362aa344bf31e44637af0fe396"
    ["1.74.0/amd64"]="3923f0479f8505f23d651653c874a447fb24f1500637ce651becc401ccbd66b95489edbe4caca29722644296defaf68b0334c16bcea2f3da8487b1467dad3eba"
    ["1.74.0/arm64"]="3923f0479f8505f23d651653c874a447fb24f1500637ce651becc401ccbd66b95489edbe4caca29722644296defaf68b0334c16bcea2f3da8487b1467dad3eba"
    ["1.73.0/amd64"]="43b152f4799bb488a7e3149c12f9e5e4df43c1ef62618c177265830618dfd8b1b73ba56d8e7e1497d98d6985b6df65460cb7e4105608897e27903d0ebaad18f8"
    ["1.73.0/arm64"]="43b152f4799bb488a7e3149c12f9e5e4df43c1ef62618c177265830618dfd8b1b73ba56d8e7e1497d98d6985b6df65460cb7e4105608897e27903d0ebaad18f8"
    ["1.72.1/amd64"]="cc6b81b8ad47c0c8de10ae03b9211d1f92c34583d70da2db1ab33cfc9569439a6930b4465fbf3c829f489a11361cf8c22ceb569fa369b0079311c8c0280d26e1"
    ["1.72.1/arm64"]="cc6b81b8ad47c0c8de10ae03b9211d1f92c34583d70da2db1ab33cfc9569439a6930b4465fbf3c829f489a11361cf8c22ceb569fa369b0079311c8c0280d26e1"
    ["1.72.0/amd64"]="1f26ea4a83aee6335edb21f390148ea23fdbd31219d2f8b3baa23ad10dad766cb9a8c966efdf545140b9137e54bf38ad75622c8ed477ca7b7204395ab7026643"
    ["1.72.0/arm64"]="1f26ea4a83aee6335edb21f390148ea23fdbd31219d2f8b3baa23ad10dad766cb9a8c966efdf545140b9137e54bf38ad75622c8ed477ca7b7204395ab7026643"
    ["1.71.1/amd64"]="838f2795c677a81df827e1289ff01db9188b3a8c29137dd8988adffda90c648aad786ef4d7c98a5670787dc623bba029e838a5be40b4fcb6957944a7c5bc3766"
    ["1.71.1/arm64"]="838f2795c677a81df827e1289ff01db9188b3a8c29137dd8988adffda90c648aad786ef4d7c98a5670787dc623bba029e838a5be40b4fcb6957944a7c5bc3766"
    ["1.71.0/amd64"]="4236dd5d9f63281c2308a33a3447defb3dc9e8aa82b9d594452f2a42deb6b5bbc813f9815de7fd6808fe2da426ec1f25b75018c0371a6b39fdd76cd3c225259e"
    ["1.71.0/arm64"]="4236dd5d9f63281c2308a33a3447defb3dc9e8aa82b9d594452f2a42deb6b5bbc813f9815de7fd6808fe2da426ec1f25b75018c0371a6b39fdd76cd3c225259e"
    ["1.70.0/amd64"]="e04160112c1816efedcfd2a9e1cdfc8835c1888742be353bacff89640231bc887d251866e7caa628821a8ba2a70762082222a5feee84df9e2e0cb59e113d9733"
    ["1.70.0/arm64"]="e04160112c1816efedcfd2a9e1cdfc8835c1888742be353bacff89640231bc887d251866e7caa628821a8ba2a70762082222a5feee84df9e2e0cb59e113d9733"
    ["1.69.0/amd64"]="b8a9f667585c6b3e45d93a625b7580ea805e31fccc6edb2a61b838bddee924cd611cb056fba917a81ea47093cb141bb33c966413e1afbfa8e00b2e999113ac4a"
    ["1.69.0/arm64"]="b8a9f667585c6b3e45d93a625b7580ea805e31fccc6edb2a61b838bddee924cd611cb056fba917a81ea47093cb141bb33c966413e1afbfa8e00b2e999113ac4a"
    ["1.68.2/amd64"]="ba3251c39fa2c52db45716ac8a902e032e06c07ec379cfb11f65ff53d03d197b6e86e2168d4e2f6fa9581b99eae77c1f47d12540449c568180007b4c70d537c3"
    ["1.68.2/arm64"]="ba3251c39fa2c52db45716ac8a902e032e06c07ec379cfb11f65ff53d03d197b6e86e2168d4e2f6fa9581b99eae77c1f47d12540449c568180007b4c70d537c3"
    ["1.68.1/amd64"]="a7941f9cc0f2d2bfe53fe269ba2bcad6c5f2128f93c07014f707b20c38b655d8a96c2c19e5d2121c40f81200b3f8c54518e253a4b1f1beaf62410473b3657055"
    ["1.68.1/arm64"]="a7941f9cc0f2d2bfe53fe269ba2bcad6c5f2128f93c07014f707b20c38b655d8a96c2c19e5d2121c40f81200b3f8c54518e253a4b1f1beaf62410473b3657055"
    ["1.68.0/amd64"]="cecfebd8516dc377c6bc3388759d976583f62693f6e0d0ddbdda288b02af223192a1ec3cf19b15b08855c6ab38df72d4d33f746161b866241fcf37d513c881f8"
    ["1.68.0/arm64"]="cecfebd8516dc377c6bc3388759d976583f62693f6e0d0ddbdda288b02af223192a1ec3cf19b15b08855c6ab38df72d4d33f746161b866241fcf37d513c881f8"
    ["1.67.1/amd64"]="1fdf8fe4d5f8019c04d1cd55d239adbac7ff94aafb581ad853db0f0bdb7a07edcd8becaebcd6999c302dde23f52fde766a3da2e69ec8624f5846e6f3c0585eb1"
    ["1.67.1/arm64"]="1fdf8fe4d5f8019c04d1cd55d239adbac7ff94aafb581ad853db0f0bdb7a07edcd8becaebcd6999c302dde23f52fde766a3da2e69ec8624f5846e6f3c0585eb1"
    ["1.67.0/amd64"]="056a31b4eb56e3341c542f79c0e2fbdbc529e22ab0d996bd6e9f7b2690d9ea36fa44854dd0353da7262176cedf5ad28474f71741937c226ec0a40dd479a2bf37"
    ["1.67.0/arm64"]="056a31b4eb56e3341c542f79c0e2fbdbc529e22ab0d996bd6e9f7b2690d9ea36fa44854dd0353da7262176cedf5ad28474f71741937c226ec0a40dd479a2bf37"
    ["1.66.1/amd64"]="68f0483b4f0498139186e4e9f6d40ec8f5febd3f39504537b97726f4d9b0e9d10f4e8b7cd51d592716500b3a166fd9a5ed15b2278bbf6b7521f18b606c2f8fbd"
    ["1.66.1/arm64"]="68f0483b4f0498139186e4e9f6d40ec8f5febd3f39504537b97726f4d9b0e9d10f4e8b7cd51d592716500b3a166fd9a5ed15b2278bbf6b7521f18b606c2f8fbd"
    ["1.66.0/amd64"]="0b54897d200579e9285e405fad4f04e630556202a11582226af01c6a7ec82ca962de0ce25dff1dd6ca9121cbcffcd741cd0455cad6f8e8cb4749c8f3d4b30a0c"
    ["1.66.0/arm64"]="0b54897d200579e9285e405fad4f04e630556202a11582226af01c6a7ec82ca962de0ce25dff1dd6ca9121cbcffcd741cd0455cad6f8e8cb4749c8f3d4b30a0c"
    ["1.65.0/amd64"]="dc5c77f113dfd0368417af540d5e8e5b2614d87243b612756687f1c91b89d42026d49a963eee6da001d7272e926b089934cc0c92290e5a59136c33f1a2cc5bec"
    ["1.65.0/arm64"]="dc5c77f113dfd0368417af540d5e8e5b2614d87243b612756687f1c91b89d42026d49a963eee6da001d7272e926b089934cc0c92290e5a59136c33f1a2cc5bec"
    ["1.64.0/amd64"]="d0334700ca7d549a09f86c412fd16cc6734a92572e304009b9d103f5a741df7bd11ad4a96e8dd076d5f48c9edf8022ef20d59f4001fe82f6fe1b6b3b138eb733"
    ["1.64.0/arm64"]="d0334700ca7d549a09f86c412fd16cc6734a92572e304009b9d103f5a741df7bd11ad4a96e8dd076d5f48c9edf8022ef20d59f4001fe82f6fe1b6b3b138eb733"
    ["1.63.0/amd64"]="8e540e532a03705a7884d780e8f4666a1f886be0880b5806c029800b92dd1e66d8008db73b0d60b88aa6eebf5a646caf97e69c51efddf1937451dbd7116a59f6"
    ["1.63.0/arm64"]="8e540e532a03705a7884d780e8f4666a1f886be0880b5806c029800b92dd1e66d8008db73b0d60b88aa6eebf5a646caf97e69c51efddf1937451dbd7116a59f6"
    ["1.62.1/amd64"]="266d8a9d80320a875cd168d763aa53c0e39b18477608a293e4a0f5737dbee71ddf2b104ec4d03bf23760c0c90f2203dad70e194c6c75701a731c0e47ed24b00b"
    ["1.62.1/arm64"]="266d8a9d80320a875cd168d763aa53c0e39b18477608a293e4a0f5737dbee71ddf2b104ec4d03bf23760c0c90f2203dad70e194c6c75701a731c0e47ed24b00b"
    ["1.62.0/amd64"]="2cfe51371939bbf929736a1267cdc84000413080658cb67b1cacf04012fba6b996e08c42374d143c9eb513a7a0f30afefc8a962304ed4cb1ccfdcf43a105814b"
    ["1.62.0/arm64"]="2cfe51371939bbf929736a1267cdc84000413080658cb67b1cacf04012fba6b996e08c42374d143c9eb513a7a0f30afefc8a962304ed4cb1ccfdcf43a105814b"
    ["1.61.0/amd64"]="8e7fee9e8ffe21d34cea36a53045bbac8ed5e63e31fb0f411a2bbc93f5cc3af5b7cec7990a1e44f210b101eb949baa3a640ce31285a24c8dedaec9c36084f5c6"
    ["1.61.0/arm64"]="8e7fee9e8ffe21d34cea36a53045bbac8ed5e63e31fb0f411a2bbc93f5cc3af5b7cec7990a1e44f210b101eb949baa3a640ce31285a24c8dedaec9c36084f5c6"
    ["1.60.0/amd64"]="875a24d72b42257f191e08c5b89ee5869e8e2999e76d762cd67431d182465210c766a26d4952e30fc86424800df018791bf6b7f7e5ad6fc73e8c1b0841ce0991"
    ["1.60.0/arm64"]="875a24d72b42257f191e08c5b89ee5869e8e2999e76d762cd67431d182465210c766a26d4952e30fc86424800df018791bf6b7f7e5ad6fc73e8c1b0841ce0991"
    ["1.59.0/amd64"]="b6540e0ed5191e4747275fd538ebe6f3d67438646bf314203f2b67c294dded0019f4bbe17637a8a3e75922253d00a6b184bb4504012c6bd6f82352fba3cb61b6"
    ["1.59.0/arm64"]="b6540e0ed5191e4747275fd538ebe6f3d67438646bf314203f2b67c294dded0019f4bbe17637a8a3e75922253d00a6b184bb4504012c6bd6f82352fba3cb61b6"
    ["1.58.1/amd64"]="90eb2f30e2c9fba7759f90ce30bf812158bf5881a068dce4304bdce3920deeadc79bcafd7ad28358a4a877d6fdf425cad66e505a8b3dc4af07d32883d481dd65"
    ["1.58.1/arm64"]="90eb2f30e2c9fba7759f90ce30bf812158bf5881a068dce4304bdce3920deeadc79bcafd7ad28358a4a877d6fdf425cad66e505a8b3dc4af07d32883d481dd65"
    ["1.58.0/amd64"]="490b4332548570761fbbb93a2f376fe4de761b47a4a4db967e0101fdaed8c764e46d3231dda03b4c2450b54a663c64cddd153bec8ced3bd07d1c3ecdf861bf78"
    ["1.58.0/arm64"]="490b4332548570761fbbb93a2f376fe4de761b47a4a4db967e0101fdaed8c764e46d3231dda03b4c2450b54a663c64cddd153bec8ced3bd07d1c3ecdf861bf78"
    ["1.57.0/amd64"]="56da4f29205a9736b503c49b3a7ba1f8d8c587a958dc72bb61f3b73fa277e11793a7a0b9bd810058970930fea5274adb9958d250c47f76008d0f79f25de7f551"
    ["1.57.0/arm64"]="56da4f29205a9736b503c49b3a7ba1f8d8c587a958dc72bb61f3b73fa277e11793a7a0b9bd810058970930fea5274adb9958d250c47f76008d0f79f25de7f551"
    ["1.56.1/amd64"]="9fe7a8fe36b2a0f09a18a15b2e9b3eba1363cde75935a77ad76a8bb165ff4cc7b9f6738c598923a01d1c92bb4114abee0bdc7c195333fa3ae688de4c7278f6a7"
    ["1.56.1/arm64"]="9fe7a8fe36b2a0f09a18a15b2e9b3eba1363cde75935a77ad76a8bb165ff4cc7b9f6738c598923a01d1c92bb4114abee0bdc7c195333fa3ae688de4c7278f6a7"
    ["1.56.0/amd64"]="6807c81d26906286fdd2324b24a8bc24e57ba3781066e45f3031ff731ce176a58afdf900801daff08d483aaf6eb661b0b8ea1990618cf799bb8ddc3edb15fb10"
    ["1.56.0/arm64"]="6807c81d26906286fdd2324b24a8bc24e57ba3781066e45f3031ff731ce176a58afdf900801daff08d483aaf6eb661b0b8ea1990618cf799bb8ddc3edb15fb10"
)
# <<< checksum table <<<

orb_install_main
