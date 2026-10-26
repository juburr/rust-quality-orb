#!/usr/bin/env bash
#
# Tests src/install/rust/install.sh, which installs a Rust release from its
# channel manifest and component archives rather than one download, so the
# shared install contract (tests/install_test.sh) doesn't cover it. Like the
# contract, it serves stand-in downloads by URL through a curl stub: a
# manifest per test version, listing stand-in component archives with their
# SHA-256, each holding a stand-in of the installer the real ones carry.
#
# Run from a checkout:
#   bash tests/install_rust_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL_SH="${ROOT}/src/install/rust/install.sh"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
SERVE="${WORK}/serve"
mkdir -p "${STUBS}" "${SERVE}"
FAILURES=0
CHECKS=0

begin() { printf -- '--- %s\n' "$1"; }
check() {
    local name=$1
    shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then
        printf '  ok: %s\n' "${name}"
    else
        printf '  FAIL: %s\n' "${name}"
        printf '%s\n' "${OUTPUT}" | sed 's/^/    | /'
        FAILURES=$((FAILURES + 1))
    fi
}

LISTED=9.0.0     # in the table, and served as listed
UNLISTED=9.0.1   # not in the table
TAMPERED=9.0.2   # in the table, but the served manifest differs
BADCOMP=9.0.3    # in the table, but its clippy archive doesn't match the manifest
OTHER=9.0.4      # in the table, but the manifest is another release's
NOCLIPPY=9.0.5   # in the table, but the manifest has no clippy
BADRUSTC=9.0.6   # in the table, but its rustc can't run
NOINSTALLER=9.0.7 # in the table, but its cargo archive has no installer
DIST="https://static.rust-lang.org/dist/2099-01-01"

# Stubs: curl serves files from SERVE by URL, logging each URL; uname
# reports FAKE_ARCH; circleci expands $NAME and ${NAME} read from stdin.
cat > "${STUBS}/curl" << 'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) printf '%s\n' " -f, --fail" " -o, --output <file>" " --retry-connrefused"; exit 0 ;;
        -o) out=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
echo "${url}" >> "${DOWNLOAD_LOG}"
file="${SERVE_DIR}/$(printf '%s' "${url}" | sha256sum | cut -c1-32)"
if [[ ! -f "${file}" ]]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
fi
cp "${file}" "${out}"
EOF
cat > "${STUBS}/uname" << 'EOF'
#!/usr/bin/env bash
case "$1" in
    -s) echo Linux ;;
    -m) echo "${FAKE_ARCH:-x86_64}" ;;
    *) exit 1 ;;
esac
EOF
cat > "${STUBS}/circleci" << 'EOF'
#!/usr/bin/env bash
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s' "${output}${input}"
EOF
printf '#!/bin/sh\nexit 0\n' > "${STUBS}/sleep"
chmod +x "${STUBS}"/*

# path_without NAME: a directory to use as the PATH, holding the stubs and
# every other command except NAME.
path_without() {
    local result="${WORK}/path-without-$1" dir file name
    local -a path_dirs
    mkdir "${result}"
    IFS=: read -r -a path_dirs <<< "${STUBS}:${PATH}"
    for dir in "${path_dirs[@]}"; do
        for file in "${dir}"/*; do
            name=${file##*/}
            if [[ "${dir}" == /* && "${name}" != "$1" && -x "${file}" && ! -d "${file}" && ! -e "${result}/${name}" ]]; then
                ln -s "${file}" "${result}/${name}"
            fi
        done
    done
    printf '%s\n' "${result}"
}
NO_XZ=$(path_without xz)

served() { printf '%s/%s\n' "${SERVE}" "$(printf '%s' "$1" | sha256sum | cut -c1-32)"; }

# The stand-in installer every component archive carries: like the real one,
# it installs the files under <archive>/<component>/ into --prefix and
# records the installation under lib/rustlib.
cat > "${WORK}/installer.sh" << 'EOF'
#!/usr/bin/env bash
prefix=""
for arg in "$@"; do
    case "${arg}" in
        --prefix=*) prefix=${arg#--prefix=} ;;
        --disable-ldconfig) ;;
        *) echo "installer: unknown option ${arg}" >&2; exit 1 ;;
    esac
done
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${prefix}/lib/rustlib"
for component in $(cat "${here}/components"); do
    cp -R "${here}/${component}/." "${prefix}/"
    echo "${component}" >> "${prefix}/lib/rustlib/components"
done
echo 3 > "${prefix}/lib/rustlib/rust-installer-version"
EOF

# make_archive FILE_BASE COMPONENT: builds FILE_BASE.tar.xz and .tar.gz from
# the tree in WORK/tree, as component COMPONENT.
make_archive() {
    local base=$1 component=$2 dir="${WORK}/archive"
    rm -rf "${dir}"
    mkdir -p "${dir}/${base}/${component}"
    cp -R "${WORK}/tree/." "${dir}/${base}/${component}/"
    cp "${WORK}/installer.sh" "${dir}/${base}/install.sh"
    echo "${component}" > "${dir}/${base}/components"
    tar -cJf "${WORK}/${base}.tar.xz" -C "${dir}" "${base}"
    tar -czf "${WORK}/${base}.tar.gz" -C "${dir}" "${base}"
}

# release VERSION: builds the stand-in components of VERSION for both
# architectures, serves them, and writes WORK/manifest-VERSION.toml listing
# them, served at the manifest's URL.
release() {
    local version=$1 manifest="${WORK}/manifest-$1.toml" triple package file base kind url
    printf 'manifest-version = "2"\ndate = "2099-01-01"\n\n[pkg.rust]\nversion = "%s (stand-in 2099-01-01)"\n\n' "${version}" > "${manifest}"
    for triple in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu wasm32-unknown-unknown; do
        for package in rustc cargo rust-std clippy-preview rustfmt-preview llvm-tools-preview; do
            if [[ "${triple}" == wasm32-* && "${package}" != rust-std ]]; then
                continue
            fi
            if [[ "${version}" == "${NOCLIPPY}" && "${package}" == clippy-preview ]]; then
                continue
            fi
            rm -rf "${WORK}/tree"
            mkdir -p "${WORK}/tree/bin" "${WORK}/tree/lib/rustlib/${triple}/lib" "${WORK}/tree/lib/rustlib/${triple}/bin"
            case "${package}" in
                rustc)
                    if [[ "${version}" == "${BADRUSTC}" ]]; then
                        printf '#!/bin/sh\nexit 3\n' > "${WORK}/tree/bin/rustc"
                    else
                        printf '#!/bin/sh\necho "rustc %s (stand-in %s)"\n' "${version}" "${triple}" > "${WORK}/tree/bin/rustc"
                    fi
                    ;;
                cargo) printf '#!/bin/sh\necho "cargo %s (stand-in %s)"\n' "${version}" "${triple}" > "${WORK}/tree/bin/cargo" ;;
                rust-std) printf 'std for %s\n' "${triple}" > "${WORK}/tree/lib/rustlib/${triple}/lib/libstd.rlib" ;;
                clippy-preview) printf '#!/bin/sh\necho clippy\n' > "${WORK}/tree/bin/cargo-clippy" ;;
                rustfmt-preview) printf '#!/bin/sh\necho rustfmt\n' > "${WORK}/tree/bin/rustfmt" ;;
                llvm-tools-preview) printf '#!/bin/sh\necho llvm-cov\n' > "${WORK}/tree/lib/rustlib/${triple}/bin/llvm-cov" ;;
            esac
            chmod -R +x "${WORK}/tree/bin" "${WORK}/tree/lib/rustlib/${triple}/bin"
            base="${package%-preview}-${version}-${triple}"
            make_archive "${base}" "${package}"
            if [[ "${version}" == "${NOINSTALLER}" && "${package}" == cargo ]]; then
                for kind in xz gz; do
                    rm -rf "${WORK}/archive" && mkdir -p "${WORK}/archive/${base}"
                    echo "no installer" > "${WORK}/archive/${base}/README"
                    tar -c"$([[ ${kind} == xz ]] && echo J || echo z)"f "${WORK}/${base}.tar.${kind}" -C "${WORK}/archive" "${base}"
                done
            fi
            printf '[pkg.%s.target.%s]\navailable = true\n' "${package}" "${triple}" >> "${manifest}"
            for kind in gz xz; do
                file="${WORK}/${base}.tar.${kind}"
                url="${DIST}/${base}.tar.${kind}"
                printf '%surl = "%s"\n%shash = "%s"\n' "$([[ ${kind} == xz ]] && echo xz_)" "${url}" \
                    "$([[ ${kind} == xz ]] && echo xz_)" "$(sha256sum "${file}" | awk '{ print $1 }')" >> "${manifest}"
                cp "${file}" "$(served "${url}")"
                # BADCOMP's clippy archive is not the one its manifest lists.
                if [[ "${version}" == "${BADCOMP}" && "${package}" == clippy-preview ]]; then
                    printf 'tampered\n' >> "$(served "${url}")"
                fi
            done
            printf '\n' >> "${manifest}"
        done
    done
    rm -rf "${WORK}/tree"
    mkdir -p "${WORK}/tree/lib/rustlib/src/rust/library"
    printf 'the standard library source\n' > "${WORK}/tree/lib/rustlib/src/rust/library/README"
    make_archive "rust-src-${version}" rust-src
    printf '[pkg.rust-src.target."*"]\navailable = true\n' >> "${manifest}"
    for kind in gz xz; do
        url="${DIST}/rust-src-${version}.tar.${kind}"
        printf '%surl = "%s"\n%shash = "%s"\n' "$([[ ${kind} == xz ]] && echo xz_)" "${url}" \
            "$([[ ${kind} == xz ]] && echo xz_)" "$(sha256sum "${WORK}/rust-src-${version}.tar.${kind}" | awk '{ print $1 }')" >> "${manifest}"
        cp "${WORK}/rust-src-${version}.tar.${kind}" "$(served "${url}")"
    done
    printf '\n[renames.clippy]\nto = "clippy-preview"\n\n[renames.rustfmt]\nto = "rustfmt-preview"\n\n[renames.llvm-tools]\nto = "llvm-tools-preview"\n' >> "${manifest}"
    if [[ "${version}" == "${OTHER}" ]]; then
        sed -i "s/^version = \"${version} /version = \"8.8.8 /" "${manifest}"
    fi
    cp "${manifest}" "$(served "https://static.rust-lang.org/dist/channel-rust-${version}.toml")"
}

for version in "${LISTED}" "${UNLISTED}" "${TAMPERED}" "${BADCOMP}" "${OTHER}" "${NOCLIPPY}" "${BADRUSTC}" "${NOINSTALLER}"; do
    release "${version}"
done
printf 'tampered\n' >> "$(served "https://static.rust-lang.org/dist/channel-rust-${TAMPERED}.toml")"

# A copy of install.sh whose table lists the test versions.
SCRIPT="${WORK}/install.sh"
: > "${WORK}/entries"
for version in "${LISTED}" "${TAMPERED}" "${BADCOMP}" "${OTHER}" "${NOCLIPPY}" "${BADRUSTC}" "${NOINSTALLER}"; do
    hash=$(sha512sum "${WORK}/manifest-${version}.toml" | awk '{ print $1 }')
    printf '    ["%s/amd64"]="%s"\n    ["%s/arm64"]="%s"\n' "${version}" "${hash}" "${version}" "${hash}" >> "${WORK}/entries"
done
sed "/^declare -A sha512sums=($/r ${WORK}/entries" "${INSTALL_SH}" > "${SCRIPT}"

CASE=""
new_case() {
    CASE=$(mktemp -d "${WORK}/case.XXXXXX")
    mkdir -p "${CASE}/home" "${CASE}/work" "${CASE}/tmp"
    : > "${CASE}/downloads.log"
    : > "${CASE}/bash_env"
}

# run_install [-u NAME]... [VAR=value ...]: runs the test copy of install.sh
# in CASE with the test defaults, overridden by the given settings.
run_install() {
    local -a unset=() settings
    local name index
    while [[ "${1:-}" == "-u" ]]; do
        unset+=(-u "$2")
        shift 2
    done
    settings=("HOME=${CASE}/home" "BASH_ENV=${CASE}/bash_env" "TMPDIR=${CASE}/tmp" "PATH=${STUBS}:${PATH}"
        "DOWNLOAD_LOG=${CASE}/downloads.log" "SERVE_DIR=${SERVE}" FAKE_ARCH=x86_64
        "PARAM_VERSION=${LISTED}" PARAM_VERIFY_CHECKSUMS=strict "PARAM_INSTALL_PATH=${CASE}/rust" PARAM_CACHING=false
        "PARAM_COMPONENTS=clippy,rustfmt" PARAM_TARGETS= PARAM_DOWNLOAD_BASE_URL=)
    if [[ $# -gt 0 ]]; then
        settings+=("$@")
    fi
    # A removed name's default setting goes too.
    for name in ${unset[@]+"${unset[@]}"}; do
        [[ "${name}" == -u ]] && continue
        for index in "${!settings[@]}"; do
            if [[ "${settings[${index}]}" == "${name}="* ]]; then
                unset "settings[${index}]"
            fi
        done
    done
    OUTPUT=$(cd "${CASE}/work" && env ${unset[@]+"${unset[@]}"} "${settings[@]}" bash "${SCRIPT}" 2>&1)
    RC=$?
}

succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
downloaded() { grep -qxF -- "$1" "${CASE}/downloads.log"; }
no_downloads() { [[ ! -s "${CASE}/downloads.log" ]]; }
download_count() { [[ "$(wc -l < "${CASE}/downloads.log")" -eq "$1" ]]; }
# installed [DIR] [TRIPLE]: the release's cargo and rustc for TRIPLE are in DIR.
installed() {
    local dir=${1:-${CASE}/rust} triple=${2:-x86_64-unknown-linux-gnu}
    [[ -x "${dir}/bin/cargo" && -x "${dir}/bin/rustc" ]] && grep -qF "(stand-in ${triple})" "${dir}/bin/cargo" \
        && [[ -f "${dir}/lib/rustlib/${triple}/lib/libstd.rlib" && -f "${dir}/lib/rustlib/rust-installer-version" ]]
}
not_installed() { [[ ! -e "${CASE}/rust" ]]; }
record() { cat "${CASE}/rust/bin/.cargo.install.json" 2> /dev/null; }
no_stray_temp() {
    local stray
    stray=$(find "${CASE}" -path "${CASE}/tmp" -prune -o -name '.*.??????' -print)
    OUTPUT+=$'\n'"stray temporary files: ${stray}"
    [[ -z "${stray}" ]]
}
cache_dir() { printf '%s/home/.cache/rust-quality-orb-rust/%s/amd64\n' "${CASE}" "${LISTED}"; }

echo "=== Rust install"

begin "a release, verified"
new_case
run_install
check "succeeds" succeeded
check "installs cargo, rustc and the standard library" installed
check "and clippy and rustfmt" test -x "${CASE}/rust/bin/cargo-clippy" -a -x "${CASE}/rust/bin/rustfmt"
check "but not what components doesn't name" test ! -e "${CASE}/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"
check "verifies the manifest against the table" said "Checksum verification passed."
check "and each component against the manifest" said "cargo-${LISTED}-x86_64-unknown-linux-gnu.tar.xz: matches the manifest's SHA-256."
check "downloads the manifest" downloaded "https://static.rust-lang.org/dist/channel-rust-${LISTED}.toml"
check "and the .tar.xz of each component, once" download_count 6
check "runs the new cargo" said "cargo ${LISTED} (stand-in x86_64-unknown-linux-gnu)"
check "and rustc" said "rustc ${LISTED} (stand-in x86_64-unknown-linux-gnu)"
check "puts its bin directory on the PATH" grep -qF "export PATH=$(printf '%q' "${CASE}/rust/bin"):" "${CASE}/bash_env"
OUTPUT=$(record)
check "records the install beside cargo" said '"method":"prebuilt"'
check "with the components" said '"components":["rustc","cargo","rust-std","clippy-preview","rustfmt-preview"]'
check "and targets" said '"targets":["x86_64-unknown-linux-gnu"]'
check "and the manifest's SHA-512" said "\"asset_sha512\":\"$(sha512sum "${WORK}/manifest-${LISTED}.toml" | awk '{ print $1 }')\""
check "leaves no temporary files" no_stray_temp
check "or downloads in the working directory" test -z "$(ls -A "${CASE}/work")"
check "or in TMPDIR" test -z "$(ls -A "${CASE}/tmp")"

begin "components and targets"
new_case
run_install "PARAM_COMPONENTS=llvm-tools rust-src" "PARAM_TARGETS=wasm32-unknown-unknown"
check "installs llvm-tools" test -x "${CASE}/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"
check "and rust-src, the same for every target" test -f "${CASE}/rust/lib/rustlib/src/rust/library/README"
check "and the standard library for another target" test -f "${CASE}/rust/lib/rustlib/wasm32-unknown-unknown/lib/libstd.rlib"
check "without clippy, which components no longer names" test ! -e "${CASE}/rust/bin/cargo-clippy"
check "recording the target" grep -qF '"targets":["x86_64-unknown-linux-gnu","wasm32-unknown-unknown"]' "${CASE}/rust/bin/.cargo.install.json"
new_case
# shellcheck disable=SC2016 # expanded by install.sh
run_install 'PARAM_COMPONENTS=${ORB_TEST_COMPONENT}' ORB_TEST_COMPONENT=llvm-tools
check "expands environment variables in components" test -x "${CASE}/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"
new_case
run_install PARAM_COMPONENTS=clippy,miri
check "refuses a component it doesn't install" failed
check "naming the ones it does" said "components can name clippy, rustfmt, llvm-tools, rust-src, not 'miri'."
check "before downloading anything" no_downloads
new_case
run_install "PARAM_TARGETS=wasm32;rm"
check "refuses a target that isn't a name" said "targets must list names"
check "before downloading anything" no_downloads
new_case
run_install PARAM_TARGETS=riscv64gc-unknown-linux-gnu
check "fails for a target the release doesn't have" said "Rust ${LISTED} has no rust-std for riscv64gc-unknown-linux-gnu."
check "and installs nothing" not_installed
new_case
run_install "PARAM_VERSION=${NOCLIPPY}"
check "fails for a component the release doesn't have" said "Rust ${NOCLIPPY} has no clippy-preview for x86_64-unknown-linux-gnu."
check "and installs nothing" not_installed

begin "architectures and archive formats"
new_case
run_install FAKE_ARCH=aarch64
check "aarch64 gets the aarch64 release" installed "${CASE}/rust" aarch64-unknown-linux-gnu
new_case
run_install "PATH=${NO_XZ}"
check "without xz, installs from the .tar.gz archives" installed
check "downloading those" downloaded "${DIST}/cargo-${LISTED}-x86_64-unknown-linux-gnu.tar.gz"
check "and no .tar.xz" test -z "$(grep '\.tar\.xz$' "${CASE}/downloads.log")"

begin "verification"
new_case
run_install "PARAM_VERSION=${UNLISTED}"
check "strict refuses a release the table doesn't list" failed
check "before downloading anything" no_downloads
new_case
run_install "PARAM_VERSION=${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions
check "known_versions installs it from the unverified manifest" installed
check "with a warning" said "WARN:"
check "still checking each component against the manifest" said "cargo-${UNLISTED}-x86_64-unknown-linux-gnu.tar.xz: matches the manifest's SHA-256."
new_case
run_install "PARAM_VERSION=${TAMPERED}"
check "refuses a manifest that doesn't match the table" failed
check "saying so" said "Checksum verification failed."
check "and installs nothing" not_installed
check "or downloads any component" download_count 1
new_case
run_install "PARAM_VERSION=${BADCOMP}"
check "refuses a component that doesn't match the manifest" failed
check "naming it" said "clippy-${BADCOMP}-x86_64-unknown-linux-gnu.tar.xz does not match the SHA-256 the Rust ${BADCOMP} manifest lists for it"
check "and installs nothing" not_installed
check "leaving no temporary files" no_stray_temp
new_case
run_install "PARAM_VERSION=${OTHER}"
check "refuses the manifest of another release" said "is the manifest of Rust '8.8.8', not ${OTHER}."
check "and installs nothing" not_installed
new_case
run_install "PARAM_VERSION=${NOINSTALLER}"
check "refuses a component archive without an installer" said "does not hold one component installer"

begin "install_path"
new_case
run_install
printf 'left over\n' > "${CASE}/rust/stale.txt"
run_install "PARAM_VERSION=${BADRUSTC}"
check "a new release whose rustc can't run fails" failed
check "saying so" said "The installed rustc cannot run on this machine"
check "and leaves the earlier installation whole" test -f "${CASE}/rust/stale.txt"
run_install "PARAM_VERSION=${BADCOMP}"
check "so does a rejected component" test -f "${CASE}/rust/stale.txt"
run_install
check "an earlier installation is replaced" succeeded
check "as a whole, leaving none of its files" test ! -e "${CASE}/rust/stale.txt"
check "leaving no temporary files" no_stray_temp
new_case
mkdir -p "${CASE}/rust/bin" "${CASE}/rust/empty"
run_install
check "an install_path holding only empty directories is installed into" installed
new_case
mkdir -p "${CASE}/rust/docs"
printf 'precious\n' > "${CASE}/rust/docs/notes.txt"
run_install
check "refuses an install_path that holds files, but not Rust" said "holds something other than a Rust installation"
check "leaves it alone" grep -qx precious "${CASE}/rust/docs/notes.txt"
check "before downloading anything" no_downloads
new_case
printf 'a file\n' > "${CASE}/rust"
run_install
check "refuses an install_path that is a file" said "is not a directory"
new_case
mkdir -p "${CASE}/real"
ln -s "${CASE}/real" "${CASE}/rust"
run_install
check "refuses an install_path that is a symbolic link" said "is a symbolic link"
new_case
run_install -u PARAM_INSTALL_PATH
check "defaults to \$HOME/.rust-quality-orb/rust" installed "${CASE}/home/.rust-quality-orb/rust"

begin "caching"
new_case
run_install PARAM_CACHING=true
check "succeeds" installed
check "caches the verified manifest" cmp -s "$(cache_dir)/channel-rust-${LISTED}.toml" "${WORK}/manifest-${LISTED}.toml"
check "and each component archive" test -f "$(cache_dir)/clippy-${LISTED}-x86_64-unknown-linux-gnu.tar.xz"
: > "${CASE}/downloads.log"
rm -rf "${CASE}/rust"
run_install PARAM_CACHING=true
check "a second install uses the cache" installed
check "downloading nothing" no_downloads
check "saying so" said "(from the cache)"
printf 'corrupted\n' >> "$(cache_dir)/clippy-${LISTED}-x86_64-unknown-linux-gnu.tar.xz"
rm -rf "${CASE}/rust"
run_install PARAM_CACHING=true
check "a cached component that doesn't match the manifest is downloaded again" installed
check "saying so" said "The cached clippy-${LISTED}-x86_64-unknown-linux-gnu.tar.xz does not match the manifest's SHA-256."
check "and replaced in the cache" cmp -s "$(cache_dir)/clippy-${LISTED}-x86_64-unknown-linux-gnu.tar.xz" "$(served "${DIST}/clippy-${LISTED}-x86_64-unknown-linux-gnu.tar.xz")"
check "leaving no temporary files" no_stray_temp
new_case
run_install "PARAM_VERSION=${UNLISTED}" PARAM_VERIFY_CHECKSUMS=known_versions PARAM_CACHING=true
check "caches nothing from an unverified manifest" test ! -e "${CASE}/home/.cache"

begin "download_base_url"
mirror="https://mirror.example/artifactory/rust"
for file in "dist/channel-rust-${LISTED}.toml" "dist/2099-01-01/rustc-${LISTED}-x86_64-unknown-linux-gnu.tar.xz" \
    "dist/2099-01-01/cargo-${LISTED}-x86_64-unknown-linux-gnu.tar.xz" "dist/2099-01-01/rust-std-${LISTED}-x86_64-unknown-linux-gnu.tar.xz" \
    "dist/2099-01-01/clippy-${LISTED}-x86_64-unknown-linux-gnu.tar.xz" "dist/2099-01-01/rustfmt-${LISTED}-x86_64-unknown-linux-gnu.tar.xz"; do
    cp "$(served "https://static.rust-lang.org/${file}")" "$(served "${mirror}/${file}")"
done
new_case
run_install "PARAM_DOWNLOAD_BASE_URL=${mirror}/"
check "installs from the mirror" installed
check "downloading the manifest from it" downloaded "${mirror}/dist/channel-rust-${LISTED}.toml"
check "and every component" test -z "$(grep -v "^${mirror}/" "${CASE}/downloads.log")"
check "says which mirror it uses" said "download mirror:  ${mirror} (in place of https://static.rust-lang.org)"
new_case
run_install "PARAM_DOWNLOAD_BASE_URL=https://user:s3cret@mirror.example"
check "refuses credentials in it" said "download_base_url must not hold credentials"
check "without printing them" not_said "s3cret"
check "before downloading anything" no_downloads

begin "rust-toolchain.toml"
new_case
printf '[toolchain]\nchannel = "1.95.0"\n' > "${CASE}/work/rust-toolchain.toml"
run_install
check "warns that the pinned release ignores it" said "which only rustup reads: the Rust ${LISTED} installed here ignores it"

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} of ${CHECKS} checks failed."
    exit 1
fi
echo "All ${CHECKS} Rust install checks passed."
