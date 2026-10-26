# shellcheck shell=bash disable=SC2034 # a fragment: the install contract it is spliced into reads these
# rustup-init, from static.rust-lang.org. install_path is rustup's
# CARGO_HOME: rustup-init installs itself there as bin/rustup, which then
# installs the toolchain. The stand-in rustup-init does the same, and as
# rustup logs every call to RUSTUP_STUB_LOG, so the checks below see which
# toolchain, components and targets were asked for. On top of the shared
# contract (and the download_base_url checks of release.sh, for
# https://static.rust-lang.org): the toolchain parameter, rust-toolchain.toml,
# none, and the CARGO_HOME, RUSTUP_HOME and RUSTUP_DIST_SERVER exports.
FIXTURE_ORIGIN="https://static.rust-lang.org"

# fixture_binary ARCH: a stand-in rustup-init that installs itself as rustup.
fixture_binary() {
    cat << 'EOF'
#!/usr/bin/env bash
if [[ "${0##*/}" == rustup-init ]]; then
    case "$1" in
        --version) echo "rustup-init 9.9.9 (stand-in)"; exit 0 ;;
        -y)
            printf 'rustup-init %s CARGO_HOME=%s RUSTUP_HOME=%s RUSTUP_DIST_SERVER=%s\n' "$*" "${CARGO_HOME}" "${RUSTUP_HOME}" \
                "${RUSTUP_DIST_SERVER:-}" >> "${RUSTUP_STUB_LOG}"
            mkdir -p "${CARGO_HOME}/bin" "${RUSTUP_HOME}"
            cp "$0" "${CARGO_HOME}/bin/rustup"
            exit 0
            ;;
    esac
    echo "rustup-init stand-in: unexpected arguments: $*" >&2
    exit 1
fi
printf 'rustup %s\n' "$*" >> "${RUSTUP_STUB_LOG}"
if [[ "$*" == "show active-toolchain" ]]; then
    echo "stable-x86_64-unknown-linux-gnu (default)"
fi
exit "${RUSTUP_STUB_EXIT:-0}"
EOF
}

fixture_installed_file() {
    printf '%s/bin/rustup\n' "$2"
}

fixture_installed_content() {
    printf '%s/bin/rustup\n' "$1"
}

fixture_path_dir() {
    printf '%s/bin/bin\n' "$1"
}

# Every run logs to the case's own file, and starts without the CARGO_HOME,
# RUSTUP_HOME and RUSTUP_DIST_SERVER of the machine running the tests.
fixture_env() {
    printf '%s\n' "RUSTUP_STUB_LOG=$1/rustup.log" CARGO_HOME= RUSTUP_HOME= RUSTUP_DIST_SERVER=
}

fixture_tool_checks() {
    local mirror="https://mirror.example/artifactory/rust"
    begin "rustup: the toolchain"
    new_case
    run_install
    check "runs rustup-init without touching the shell profile, and with no toolchain of its own" \
        grep -q -- "^rustup-init -y --no-modify-path --profile minimal --default-toolchain none " "${CASE}/rustup.log"
    check "with install_path as CARGO_HOME and RUSTUP_HOME under HOME" \
        grep -qF "CARGO_HOME=${CASE}/bin RUSTUP_HOME=${CASE}/home/.rustup" "${CASE}/rustup.log"
    check "installs stable by default" grep -qx "rustup toolchain install stable --profile minimal" "${CASE}/rustup.log"
    check "and makes it the default" grep -qx "rustup default stable" "${CASE}/rustup.log"
    check "exports CARGO_HOME, since install_path is not ~/.cargo" grep -qF "export CARGO_HOME=$(printf '%q' "${CASE}/bin")" "${CASE}/bash_env"
    check "and not RUSTUP_HOME, which is ~/.rustup" not_in_bash_env RUSTUP_HOME
    new_case
    run_install PARAM_TOOLCHAIN=nightly-2026-10-01 "PARAM_COMPONENTS=clippy, llvm-tools" "PARAM_TARGETS=x86_64-unknown-linux-musl wasm32-unknown-unknown"
    check "installs the toolchain parameter, with the components and targets" \
        grep -qx "rustup toolchain install nightly-2026-10-01 --profile minimal --component clippy,llvm-tools --target x86_64-unknown-linux-musl,wasm32-unknown-unknown" "${CASE}/rustup.log"
    check "and makes it the default" grep -qx "rustup default nightly-2026-10-01" "${CASE}/rustup.log"
    new_case
    printf '[toolchain]\nchannel = "1.95.0"\n' > "${CASE}/work/rust-toolchain.toml"
    run_install PARAM_COMPONENTS=clippy
    check "with no toolchain parameter, installs the one rust-toolchain.toml names" grep -qx "rustup toolchain install --profile minimal --component clippy" "${CASE}/rustup.log"
    check "saying so" said "Installing the toolchain ${CASE}/work/rust-toolchain.toml names."
    check "and leaves the default alone" test -z "$(grep '^rustup default' "${CASE}/rustup.log")"
    rm -f "${CASE}/work/rust-toolchain.toml"
    new_case
    run_install PARAM_TOOLCHAIN=none
    check "none installs rustup alone" installed
    check "and no toolchain" test -z "$(grep '^rustup toolchain' "${CASE}/rustup.log")"
    new_case
    run_install "PARAM_TOOLCHAIN=stable;rm"
    check "refuses a toolchain that isn't a name" failed
    check "saying so" said "toolchain must be a toolchain name"
    check "before downloading anything" no_downloads
    new_case
    run_install "PARAM_COMPONENTS=clippy \$(id)"
    check "refuses a component that isn't a name" said "components must list names"
    check "before downloading anything" no_downloads
    new_case
    run_install RUSTUP_STUB_EXIT=1
    check "a toolchain rustup can't install fails the step" failed
    check "saying so" said "rustup could not install the stable toolchain."

    begin "rustup: CARGO_HOME and RUSTUP_HOME"
    new_case
    run_install -u PARAM_INSTALL_PATH "CARGO_HOME=${CASE}/cargo" "RUSTUP_HOME=${CASE}/rustup"
    check "without install_path, CARGO_HOME is the install_path" installed_in "${CASE}/cargo"
    check "and RUSTUP_HOME is used" grep -qF "RUSTUP_HOME=${CASE}/rustup" "${CASE}/rustup.log"
    check "and exported" grep -qF "export RUSTUP_HOME=$(printf '%q' "${CASE}/rustup")" "${CASE}/bash_env"
    new_case
    run_install -u PARAM_INSTALL_PATH
    check "without either, install_path is ~/.cargo" installed_in "${CASE}/home/.cargo"
    check "and nothing is exported but the PATH" test -z "$(grep -v '^export PATH=' "${CASE}/bash_env")"

    begin "rustup: the mirror serves toolchains too"
    new_case
    cp "$(served_file "${LISTED}" "${DEFAULT_ARCH}")" "${SERVE}/$(printf '%s' "${mirror}/rustup/archive/${LISTED}/x86_64-unknown-linux-gnu/rustup-init" | sha256sum | cut -c1-32)"
    run_install "PARAM_DOWNLOAD_BASE_URL=${mirror}"
    check "installs from the mirror" installed
    check "and sets RUSTUP_DIST_SERVER to it for rustup" grep -qF "RUSTUP_DIST_SERVER=${mirror}" "${CASE}/rustup.log"
    check "and for later steps" grep -qF "export RUSTUP_DIST_SERVER=$(printf '%q' "${mirror}")" "${CASE}/bash_env"
    new_case
    run_install "PARAM_DOWNLOAD_BASE_URL=${mirror}" RUSTUP_DIST_SERVER=https://other.example
    check "a RUSTUP_DIST_SERVER already set is kept" grep -qF "RUSTUP_DIST_SERVER=https://other.example" "${CASE}/rustup.log"
    check "and not exported again" not_in_bash_env RUSTUP_DIST_SERVER
}

# not_in_bash_env NAME: BASH_ENV exports nothing named NAME.
not_in_bash_env() {
    ! grep -q "^export $1=" "${CASE}/bash_env"
}
