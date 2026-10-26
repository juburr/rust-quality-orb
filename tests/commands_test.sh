#!/usr/bin/env bash
#
# Tests the command scripts offline: fmt, lint and docs with the real cargo,
# rustfmt, clippy and rustdoc, against copies of the fixture workspaces in
# tests/fixtures; the others against stand-ins for cargo-nextest,
# cargo-llvm-cov, cargo-hack, cargo-shear, cargo-semver-checks, rustup and the
# CircleCI CLI, which record how they were run and answer with the scenario
# each test picks: findings, none, a failure. cargo itself is real, except
# that a stand-in can answer cargo test --doc.
#
# What the real tools print is checked by test-deploy.yml, which runs every
# command against the fixtures.
#
# Needs cargo with rustfmt and clippy, and jq. Run from a checkout:
#   bash tests/commands_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="${ROOT}/src/scripts"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}" "${CALLS}" "${WORK}/records"
if ! REAL_CARGO=$(command -v cargo); then
    echo "ERROR: These tests need cargo, with rustfmt and clippy." >&2
    exit 1
fi
export REAL_CARGO CALLS

FAILURES=0
OUTPUT=""
RC=0
CASE=""

begin() {
    echo "--- $1"
}
check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok: ${name}"
    else
        echo "  FAIL: ${name}"
        tail -n 25 <<< "${OUTPUT}" | while IFS= read -r line; do printf '    | %s\n' "${line}"; done
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
# called_with TOOL WORD...: some call of TOOL had every WORD among its arguments.
called_with() {
    local tool=$1 file word ok
    shift
    for file in "${CALLS}/${tool}".*; do
        [[ -f "${file}" ]] || continue
        ok=true
        for word in "$@"; do
            grep -qxF -- "${word}" "${file}" || ok=false
        done
        if [[ "${ok}" == true ]]; then
            return 0
        fi
    done
    OUTPUT+=$'\n'"calls of ${tool}:"$'\n'"$(for f in "${CALLS}/${tool}".*; do [[ -f "${f}" ]] && tr '\n' ' ' < "${f}" && echo; done)"
    return 1
}
# not_called_with TOOL WORD...: no call of TOOL had every WORD.
not_called_with() {
    local saved=${OUTPUT}
    if called_with "$@"; then
        return 1
    fi
    OUTPUT=${saved}
}
call_count() { [[ "$(find "${CALLS}" -name "$1.*" | wc -l)" -eq "$2" ]]; }
file_has() { grep -qF -- "$2" "$1"; }
not_file_has() { ! grep -qF -- "$2" "$1"; }
json_is() { [[ "$(jq -r "$2" "$1" 2> /dev/null)" == "$3" ]] || { OUTPUT+=$'\n'"$1: $2 is $(jq -c "$2" "$1" 2>&1)"; return 1; }; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }
xml_ok() { python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$1" 2> /dev/null || ! command -v python3 > /dev/null; }

# Stand-ins. Each records its arguments, one per line, to CALLS/<tool>.<n>.
record() {
    cat << 'EOF'
n=$(find "${CALLS}" -name "${0##*/}.*" | wc -l)
printf '%s\n' "$@" > "${CALLS}/${0##*/}.$((n + 1))"
EOF
}

cat > "${STUBS}/circleci" << 'EOF'
#!/usr/bin/env bash
# Like `circleci env subst`: expands $NAME and ${NAME} on stdin.
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s\n' "${output}${input}"
EOF

# cargo: the real one, except cargo test --doc with STUB_DOCTEST pass, fail
# or error (doctests that don't build).
{
    echo '#!/usr/bin/env bash'
    cat << 'EOF'
if [[ "$1" == test && "$2" == --doc && -n "${STUB_DOCTEST:-}" ]]; then
    n=$(find "${CALLS}" -name "cargo-doc.*" | wc -l)
    printf '%s\n' "$@" > "${CALLS}/cargo-doc.$((n + 1))"
    echo "   Doc-tests app"
    echo ""
    echo "running 2 tests"
    case "${STUB_DOCTEST}" in
        pass)
            echo "test app/src/lib.rs - greet (line 5) ... ok"
            echo "test app/src/lib.rs - shout (line 12) ... ignored"
            echo ""
            echo "test result: ok. 1 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.10s"
            exit 0 ;;
        fail)
            echo "test app/src/lib.rs - greet (line 5) ... FAILED"
            echo "test app/src/lib.rs - shout (line 12) ... ok"
            echo ""
            echo "failures:"
            echo ""
            echo "test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.10s"
            echo "error: doctest failed, to rerun pass \`--doc\`"
            exit 101 ;;
        error)
            echo "error[E0425]: cannot find value \`nope\` in this scope"
            echo "error: could not document \`app\`"
            exit 101 ;;
    esac
fi
exec "${REAL_CARGO}" "$@"
EOF
} > "${STUBS}/cargo"

# cargo-nextest: STUB_NEXTEST is pass, fail (one test fails, exit 100),
# flaky (one passes on a retry), flakyfail (the same, failing the run, as
# flaky-result = "fail" does: exit 100), build (exit 101), none (no tests,
# exit 4), mismatch (exit 100 with every test passing in the JUnit
# report), or nojunit (exit 0, writing no report). STUB_JUNIT_PATH stands
# for a repository config that names the report's path itself. It
# writes the JUnit report where the tool config file the script passes asks.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$1" == nextest && "$2" == --version ]]; then echo "cargo-nextest 0.9.149 (stand-in)"; exit 0; fi
profile=default config=""
prev=""
for arg in "$@"; do
    case "${prev}" in
        --profile) profile=${arg} ;;
        --tool-config-file) config=${arg#*:} ;;
    esac
    prev=${arg}
done
path=${STUB_JUNIT_PATH:-$(sed -n 's/^path = "\(.*\)"$/\1/p' "${config}")}
target=$("${REAL_CARGO}" metadata --format-version 1 --no-deps | jq -r .target_directory)
junit="${target}/nextest/${profile}/${path}"
mkdir -p "${junit%/*}"
mode=${STUB_NEXTEST:-pass}
case "${mode}" in
    build) echo "error[E0308]: mismatched types"; echo "error: could not compile \`app\` (test \"greeting\")"; exit 101 ;;
    none) echo "error: no tests to run"; exit 4 ;;
    nojunit) echo "     Summary [   0.010s] 3 tests run"; exit 0 ;;
esac
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<testsuites name="nextest-run" tests="3" failures="0" errors="0">'
    echo '    <testsuite name="app" tests="3" disabled="0" errors="0" failures="0">'
    echo '        <testcase name="tests::greets" classname="app" timestamp="2026-01-01T00:00:00Z" time="0.001">'
    echo '        </testcase>'
    echo '        <testcase name="it&apos;s &lt;quoted&gt;" classname="app::greeting" timestamp="2026-01-01T00:00:00Z" time="0.001"/>'
    case "${mode}" in
        fail)
            echo '        <testcase name="doubles_wrongly" classname="app::doubling" timestamp="2026-01-01T00:00:00Z" time="0.001">'
            echo '            <failure type="test failure">assertion failed</failure>'
            echo '        </testcase>' ;;
        flaky | flakyfail)
            echo '        <testcase name="sometimes" classname="app" timestamp="2026-01-01T00:00:00Z" time="0.001">'
            echo '            <flakyFailure type="test failure">first try failed</flakyFailure>'
            echo '        </testcase>' ;;
        *)
            echo '        <testcase name="tests::shouts" classname="app" timestamp="2026-01-01T00:00:00Z" time="0.001">'
            echo '        </testcase>' ;;
    esac
    echo '    </testsuite>'
    echo '</testsuites>'
} > "${junit}"
echo "     Summary [   0.010s] 3 tests run"
case "${mode}" in
    fail | mismatch | flakyfail) exit 100 ;;
esac
exit 0
EOF
} > "${STUBS}/cargo-nextest"

# cargo-llvm-cov: STUB_COV is ok, fail (the tests fail), nollvm (no
# llvm-tools), or badreport (report --json fails). STUB_COV_LINES is
# "<count> <covered>" (default "200 150").
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
[[ "$1" == llvm-cov ]] || exit 2
shift
mode=${STUB_COV:-ok}
read -r count covered <<< "${STUB_COV_LINES:-200 150}"
case "$1" in
    --version) echo "cargo-llvm-cov 0.9.1"; exit 0 ;;
    clean) exit 0 ;;
    report)
        shift
        kind=json out="" dir=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --json) kind=json ;;
                --lcov) kind=lcov ;;
                --cobertura) kind=cobertura ;;
                --html) kind=html ;;
                --output-path) out=$2; shift ;;
                --output-dir) dir=$2; shift ;;
            esac
            shift
        done
        case "${kind}" in
            json)
                if [[ "${mode}" == badreport ]]; then echo "error: no profile data" >&2; exit 1; fi
                printf '{"data":[{"totals":{"lines":{"count":%s,"covered":%s}}}],"type":"llvm.coverage.json.export"}\n' "${count}" "${covered}" > "${out}" ;;
            lcov) printf 'TN:\nend_of_record\n' > "${out}" ;;
            cobertura) printf '<?xml version="1.0"?>\n<coverage/>\n' > "${out}" ;;
            html) mkdir -p "${dir}/html" && echo '<html></html>' > "${dir}/html/index.html" ;;
        esac
        exit 0 ;;
esac
case "${mode}" in
    fail) echo "test result: FAILED. 1 passed; 1 failed"; echo "error: test failed, to rerun pass \`--test greeting\`"; exit 101 ;;
    nollvm) echo "error: failed to find llvm-tools-preview, please install llvm-tools-preview, or set LLVM_COV and LLVM_PROFDATA" >&2; exit 1 ;;
esac
echo "test result: ok. 3 passed; 0 failed"
exit 0
EOF
} > "${STUBS}/cargo-llvm-cov"

# cargo-hack: STUB_HACK is pass (three combinations), fail (the second
# doesn't compile), notarget (the second can't find the target's standard
# library), network (the second can't download a crate), crash (fails before
# running any), or quiet (fails without the summary). It groups its output
# for GitHub Actions unless --log-group none is passed.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
[[ "$1" == hack ]] || exit 2
if [[ "$2" == --version ]]; then echo "cargo-hack 0.6.45"; exit 0; fi
group=false
if [[ -n "${GITHUB_ACTIONS:-}" && " $* " != *" --log-group none "* ]]; then group=true; fi
mode=${STUB_HACK:-pass}
if [[ "${mode}" == crash ]]; then echo "error: invalid value for '--depth'" >&2; exit 1; fi
i=0
for combination in "--no-default-features" "--no-default-features --features extra" "--no-default-features --features fast"; do
    i=$((i + 1))
    [[ "${i}" -gt 1 ]] && echo >&2
    line="running \`cargo $2 ${combination}\` on dirty (${i}/3)"
    if [[ "${group}" == true ]]; then echo "::group::${line}"; else echo "info: ${line}" >&2; fi
    echo "    Checking dirty v0.1.0" >&2
    if [[ "${mode}" != pass && "${i}" -eq 2 ]]; then
        case "${mode}" in
            notarget)
                echo "error[E0463]: can't find crate for \`core\`" >&2
                echo "  = note: the \`wasm32-unknown-unknown\` target may not be installed" >&2
                echo "error: could not compile \`dirty\` (lib) due to 1 previous error" >&2 ;;
            network) echo "error: failed to download from \`https://static.crates.io/crates/libc/0.2.170/download\`" >&2 ;;
            *)
                echo "error[E0425]: cannot find function \`speed\` in this scope" >&2
                echo "error: could not compile \`dirty\` (lib) due to 1 previous error" >&2 ;;
        esac
        echo "error: process didn't exit successfully: \`cargo $2 ${combination}\` (exit status: 101)" >&2
    fi
    [[ "${group}" == true ]] && echo "::endgroup::"
done
if [[ "${mode}" == fail || "${mode}" == notarget || "${mode}" == network ]]; then
    echo >&2
    printf 'error: failed to run 1 commands\n\nfailed commands:\n    dirty:\n        `cargo %s --no-default-features --features extra`\n' "$2" >&2
fi
[[ "${mode}" == pass ]] || exit 1
EOF
} > "${STUBS}/cargo-hack"

# cargo-shear: STUB_SHEAR is clean, unused (an unused dependency at
# STUB_OFFSET in Cargo.toml), warn (an empty file only), crash (exit 2) or
# mismatch (exit 0 with an unused dependency). --deny-warnings makes
# warnings fail it, as the real one does.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
[[ "$1" == shear ]] || exit 2
if [[ "$2" == --version ]]; then echo "cargo-shear 1.14.0"; exit 0; fi
deny=false
[[ " $* " == *" --deny-warnings "* ]] && deny=true
mode=${STUB_SHEAR:-clean}
if [[ "${mode}" == crash ]]; then echo "error: cargo metadata exited with an error: failed to parse manifest"; exit 2; fi
unused='{"code":"shear/unused_dependency","severity":"error","message":"unused dependency `unused-helper`","file":"Cargo.toml","location":{"offset":'"${STUB_OFFSET:-0}"',"length":13},"help":"remove this dependency","fixable":true}'
empty='{"code":"shear/empty_files","severity":"warning","message":"1 empty file in `dirty`","fixable":false}'
case "${mode}" in
    clean) findings="" errors=0 warnings=0 ;;
    unused | mismatch) findings=${unused} errors=1 warnings=0 ;;
    warn) findings=${empty} errors=0 warnings=1 ;;
esac
printf '{\n  "summary": {"errors": %s, "warnings": %s, "fixed": 0},\n  "findings": [%s]\n}\n' "${errors}" "${warnings}" "${findings}"
if [[ "${mode}" == mismatch ]]; then exit 0; fi
if [[ "${errors}" -gt 0 || ( "${deny}" == true && "${warnings}" -gt 0 ) ]]; then exit 1; fi
EOF
} > "${STUBS}/cargo-shear"

# cargo-semver-checks: STUB_SEMVER is pass, fail (a failed lint, exit 100),
# warn (a lint at warn level, exit 0), old-fail (a failed lint, exit 1, as
# before 0.49.0), old-error (exit 1 with an error), error (exit 101) or none
# (nothing checked, exit 0).
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
[[ "$1" == semver-checks ]] || exit 2
if [[ "$2" == --version ]]; then echo "cargo-semver-checks 0.51.0"; exit 0; fi
mode=${STUB_SEMVER:-pass}
case "${mode}" in
    error) echo "error: rustc version is not high enough: >=1.90.0 needed, got 1.85.0" >&2; exit 101 ;;
    old-error) echo "error: package \`shapes\` not found in the registry" >&2; exit 1 ;;
    none) exit 0 ;;
esac
printf '%12s %s\n' Building "shapes v0.1.1 (current)" >&2
printf '%12s %s\n' Checking "shapes v0.1.0 -> v0.1.1 (patch change)" >&2
case "${mode}" in
    pass)
        printf '%12s %s\n' Checked "[   0.010s] 196 checks: 196 pass, 26 skip" >&2
        printf '%12s %s\n' Summary "no semver update required" >&2 ;;
    fail | old-fail)
        printf '%12s %s\n' Checked "[   0.010s] 196 checks: 195 pass, 1 fail, 0 warn, 26 skip" >&2
        printf '\n--- failure function_missing: pub fn removed or renamed ---\n\n'
        printf 'Description:\nA publicly-visible function cannot be imported by its prior path.\n%12s %s\n%12s %s\n\n' "ref:" "https://doc.rust-lang.org/cargo/reference/semver.html#item-remove" "impl:" "https://github.com/obi1kenobi/cargo-semver-checks/tree/v0.51.0/src/lints/function_missing.ron"
        printf 'Failed in:\n  function shapes::square_perimeter, previously in file src/lib.rs:10\n\n'
        echo >&2
        printf '%12s %s\n' Summary "semver requires new major version: 1 major and 0 minor checks failed" >&2 ;;
    warn)
        printf '%12s %s\n' Checked "[   0.010s] 196 checks: 195 pass, 0 fail, 1 warn, 26 skip" >&2
        printf '\n--- warning function_must_use_added: function #[must_use] added ---\n\n'
        printf 'Description:\nA function is now #[must_use].\n%12s %s\n\nFailed in:\n  function shapes::square_area in src/lib.rs:4\n\n' "impl:" "https://github.com/obi1kenobi/cargo-semver-checks/tree/v0.51.0/src/lints/function_must_use_added.ron"
        echo >&2
        printf '%12s %s\n' Summary "no semver update required" >&2
        printf '%12s %s\n' Warning "produced 0 major and 1 minor level warnings" >&2 ;;
esac
printf '%12s %s\n' Finished "[   1.000s] shapes" >&2
case "${mode}" in
    fail) exit 100 ;;
    old-fail) exit 1 ;;
esac
exit 0
EOF
} > "${STUBS}/cargo-semver-checks"

# rustup: toolchain install (fails for STUB_RUSTUP_NOINSTALL), which
# --toolchain VERSION TOOL, run VERSION cargo check (fails to compile for
# STUB_RUSTUP_FAIL, with a dependency that needs a newer Rust for
# STUB_RUSTUP_DEP, and can't download for STUB_RUSTUP_NET; it records the
# RUSTC it runs with), and show active-toolchain.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
case "$1 $2" in
    "show active-toolchain") echo "stable-x86_64-unknown-linux-gnu (default)"; exit 0 ;;
    "toolchain install")
        if [[ "$3" == "${STUB_RUSTUP_NOINSTALL:-}" ]]; then echo "error: toolchain '$3' is not installable" >&2; exit 1; fi
        echo "info: installing $3"; exit 0 ;;
    "which --toolchain") echo "/rustup/toolchains/$3/bin/$4"; exit 0 ;;
esac
if [[ "$1" == run ]]; then
    printf 'RUSTC=%s\n' "${RUSTC-unset}" >> "${CALLS}/rustup.$((n + 1))"
    if [[ "$2" == "${STUB_RUSTUP_DEP:-}" ]]; then
        echo "error: package \`once_cell v1.21.0\` cannot be built because it requires rustc 1.74 or newer, while the currently active rustc version is $2"
        exit 101
    fi
    if [[ "$2" == "${STUB_RUSTUP_NET:-}" ]]; then
        echo "error: failed to download from \`https://static.crates.io/crates/once_cell/1.21.0/download\`"
        exit 101
    fi
    if [[ "$2" == "${STUB_RUSTUP_FAIL:-}" ]]; then
        echo "error[E0658]: use of unstable library feature \`lazy_cell\`"
        echo "error: could not compile \`dirty\` (lib) due to 1 previous error"
        exit 101
    fi
    echo "    Finished \`dev\` profile [unoptimized + debuginfo] target(s) in 0.10s"
    exit 0
fi
exit 1
EOF
} > "${STUBS}/rustup"
chmod +x "${STUBS}"/*

# A stand-in for install/rust/install.sh, for msrv's toolchain_source rust:
# its table lists 1.70.0, 1.70.1 and 1.75.0 for both architectures, and it
# installs a cargo that records its calls (as cargo-msrv) and fails for
# STUB_MSRV_FAIL.
cat > "${WORK}/install-rust.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
# sha512sums["1.70.0/amd64"]="..."
# sha512sums["1.70.1/amd64"]="..."
# sha512sums["1.75.0/amd64"]="..."
# sha512sums["1.70.0/arm64"]="..."
# sha512sums["1.70.1/arm64"]="..."
# sha512sums["1.75.0/arm64"]="..."
n=$(find "${CALLS}" -name "install-rust.*" | wc -l)
printf '%s\n' "PARAM_VERSION=${PARAM_VERSION}" "PARAM_INSTALL_PATH=${PARAM_INSTALL_PATH}" "PARAM_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS}" \
    "PARAM_COMPONENTS=${PARAM_COMPONENTS}" "BASH_ENV=${BASH_ENV}" > "${CALLS}/install-rust.$((n + 1))"
if [[ "${PARAM_VERSION}" == "${STUB_RUST_NOINSTALL:-}" ]]; then echo "ERROR: checksum mismatch" >&2; exit 1; fi
mkdir -p "${PARAM_INSTALL_PATH}/bin"
cat > "${PARAM_INSTALL_PATH}/bin/cargo" << 'CARGO'
#!/usr/bin/env bash
n=$(find "${CALLS}" -name "cargo-msrv.*" | wc -l)
printf '%s\n' "$0" "$@" "RUSTC=${RUSTC}" "RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN-unset}" > "${CALLS}/cargo-msrv.$((n + 1))"
if [[ "$0" == *"/${STUB_MSRV_FAIL:-none}/"* ]]; then echo "error[E0658]: use of unstable library feature"; echo "error: could not compile \`app\`"; exit 101; fi
echo "    Finished"
CARGO
chmod +x "${PARAM_INSTALL_PATH}/bin/cargo"
echo "export SHOULD_NOT_LEAK=1" >> "${BASH_ENV}"
EOF

# new_case: a fresh copy of the fixtures in CASE/fx, and a BASH_ENV of its
# own.
new_case() {
    CASE=$(mktemp -d "${WORK}/case.XXXXXX")
    cp -R "${ROOT}/tests/fixtures" "${CASE}/fx"
    rm -rf "${CASE}/fx"/*/target "${CASE}/fx"/*/*/target
    : > "${CASE}/bash_env"
}

# run COMMAND DIR [NAME=VALUE...]: runs the command's script in DIR (relative
# to the fixture copy) with the command's parameter defaults, overridden by
# NAME=VALUE, as tests/run_command.sh does, with CALLS emptied first. Keeps
# any run record it writes.
DEFAULTS_CACHE="${WORK}/defaults"
mkdir -p "${DEFAULTS_CACHE}"
run() {
    local command=$1 dir=$2 settings=() name
    shift 2
    # A lowercase name is a parameter; anything else is set as it is. Bash
    # 4.0 calls an empty "$@" unbound under set -u, even as ${@+"$@"}.
    while [[ $# -gt 0 ]]; do
        if [[ "${1%%=*}" =~ ^[a-z][a-z0-9_]*$ ]]; then
            settings+=("PARAM_$(tr '[:lower:]' '[:upper:]' <<< "${1%%=*}")=${1#*=}")
        else
            settings+=("$1")
        fi
        shift
    done
    if [[ ! -f "${DEFAULTS_CACHE}/${command}" ]]; then
        awk '
            function flush() { if (name != "") printf "PARAM_%s=%s\n", toupper(name), value }
            /^parameters:/ { p = 1; next }
            /^[^ ]/ { if (p) flush(); p = 0; name = "" }
            p && /^  [a-z_0-9]+:$/ { flush(); name = $1; sub(/:$/, "", name); value = "" }
            p && /^    default:/ { value = $0; sub(/^    default: */, "", value); if (value ~ /^".*"$/) value = substr(value, 2, length(value) - 2) }
            END { if (p) flush() }' "${ROOT}/src/commands/${command}.yml" | grep -v '^PARAM_WORKING_DIR=' > "${DEFAULTS_CACHE}/${command}"
    fi
    local defaults=()
    mapfile -t defaults < "${DEFAULTS_CACHE}/${command}"
    find "${CALLS}" -type f -delete
    defaults+=("PARAM_OUTPUT_DIR=${CASE}/out")
    OUTPUT=$(cd "${CASE}/fx/${dir}" && env -u CIRCLE_NODE_TOTAL -u CIRCLE_NODE_INDEX -u GITHUB_ACTIONS -u CIRCLE_BUILD_URL \
        PATH="${STUBS}:${PATH}" BASH_ENV="${CASE}/bash_env" CARGO_NET_OFFLINE=true CARGO_TERM_COLOR=never \
        SCRIPT_RUST_QUALITY_LIB="$(cat "${SCRIPTS}/lib/rust_quality.sh")" \
        "${defaults[@]}" ${settings[@]+"${settings[@]}"} bash "${SCRIPTS}/${command}.sh" 2>&1)
    RC=$?
    for name in "${CASE}/out"/*.run-record.json; do
        [[ -f "${name}" ]] && cp "${name}" "${WORK}/records/${command}-$(basename "${CASE}")-${name##*/}"
    done
}
# report NAME: the file NAME in the case's output directory.
report() { printf '%s/out/%s\n' "${CASE}" "$1"; }

# LIB_TEST CODE: runs CODE after loading the shared helpers.
LIB_TEST() {
    OUTPUT=$(PATH="${STUBS}:${PATH}" bash -c 'set -euo pipefail; eval "$(cat "$1")"; eval "$2"' _ "${SCRIPTS}/lib/rust_quality.sh" "$1" 2>&1)
    RC=$?
}

begin "the shared helpers"
LIB_TEST 'rq_bool sarif yes'
check "rq_bool refuses anything but true and false" said "ERROR: sarif must be true or false, not 'yes'."
LIB_TEST "rq_words extra_args '--a \"b c\" '\\''d'\\'''; printf '<%s>' \"\${RQ_WORDS[@]}\""
check "rq_words splits like the shell, without expanding" said "<--a><b c><d>"
# shellcheck disable=SC2016 # passed to the helpers as text
LIB_TEST 'rq_words extra_args "--a \$(id)"'
check "rq_words refuses \$(...)" said "has a \$(...) or backtick outside quotes"
LIB_TEST 'rq_extra_args "--profile=ci --x" --profile'
check "rq_extra_args refuses an option the command sets, with =" said "ERROR: extra_args can't set --profile"
# shellcheck disable=SC2016 # expanded by the helper
LIB_TEST 'rq_extra_args "--profiles x" --profile; printf "<%s>" "${RQ_EXTRA_ARGS[@]}"'
check "but not one that only starts like it" said "<--profiles><x>"
LIB_TEST 'rq_match "é" "^[a-z]$" && echo matched || echo "no match"'
check "rq_match matches ranges in the C locale" said "no match"
LIB_TEST "rq_output relative name"
check "rq_output refuses a relative output_dir" said "ERROR: output_dir must be an absolute path"
LIB_TEST "rq_output ${WORK}/o ../x"
check "and a report_name that isn't a plain file name" failed
LIB_TEST "rq_junit ${WORK}/j/odd.xml 'a\"b' '[{\"classname\":\"c\",\"name\":\"<&>\\\"'\\''\",\"status\":\"failed\",\"message\":\"m\",\"detail\":\"x]]>y\"}]'"
check "rq_junit escapes what XML needs escaped" xml_ok "${WORK}/j/odd.xml"
LIB_TEST "rq_junit ${WORK}/j/empty.xml suite '[]'"
check "and writes a passing case when there are none" file_has "${WORK}/j/empty.xml" 'tests="1" failures="0" skipped="0"'
LIB_TEST 'rq_args_json --x "https://user:token@example.com/db?key=1#f" "-n"'
check "rq_args_json keeps options and drops credentials from URLs" said '["--x","https://example.com/db","-n"]'
# RQ_DIAGNOSTICS_JQ, on cargo's JSON messages.
diag() {
    local level=$1 code=$2 file=$3
    jq -cn --arg level "${level}" --arg code "${code}" --arg file "${file}" '{reason: "compiler-message", message: {level: $level,
        code: (if $code == "" then null else {code: $code} end), message: "m \($code)", rendered: "r \($code)",
        spans: [{is_primary: true, file_name: $file, line_start: 3, column_start: 5, line_end: 3, column_end: 9}]}}'
}
{
    diag warning clippy::needless_return src/lib.rs
    diag warning clippy::needless_return src/lib.rs
    diag warning dead_code src/a.rs
    diag error rustdoc::broken_intra_doc_links src/lib.rs
    echo '{"reason": "build-finished", "success": false}'
} > "${WORK}/denied.jsonl"
LIB_TEST "jq -c -s --argjson docs false \"\${RQ_DIAGNOSTICS_JQ}\" ${WORK}/denied.jsonl"
check "RQ_DIAGNOSTICS_JQ counts a lint once, however many targets report it" said '"code":"clippy::needless_return","message"'
check "and a build that only denied lints stopped as complete" said '"complete":true'
LIB_TEST "jq -c -s --argjson docs false \"\${RQ_DIAGNOSTICS_JQ}\" ${WORK}/denied.jsonl | jq -c '[(.findings | length), (.errors | length)]'"
check "three findings in all, and no errors" [ "${OUTPUT}" == "[3,0]" ]
{
    diag error E0308 src/lib.rs
    diag warning unused_variables src/lib.rs
    diag error "" src/lib.rs
    echo '{"reason": "build-finished", "success": false}'
} > "${WORK}/broken.jsonl"
LIB_TEST "jq -c -s --argjson docs false \"\${RQ_DIAGNOSTICS_JQ}\" ${WORK}/broken.jsonl | jq -c '[.complete, (.findings | length), (.errors | map(.code))]'"
check "and one that doesn't compile as incomplete, with E codes and uncoded errors as errors" said '[false,1,[null,"E0308"]]'
LIB_TEST "jq -c -s --argjson docs false \"\${RQ_DIAGNOSTICS_JQ}\" /dev/null"
check "and no messages at all as incomplete" said '"complete":false'
{
    diag warning dead_code src/lib.rs
    diag warning missing_docs src/lib.rs
    diag error rustdoc::broken_intra_doc_links src/a.rs
    diag error clippy::all src/b.rs
    diag "error: internal compiler error" "" src/c.rs
    echo '{"reason": "compiler-artifact", "package_id": "b 0.1.0", "filenames": ["/t/doc/b/index.html"]}'
    echo '{"reason": "build-finished", "success": false}'
} > "${WORK}/docs.jsonl"
LIB_TEST "jq -c -s --argjson docs true \"\${RQ_DIAGNOSTICS_JQ}\" ${WORK}/docs.jsonl | jq -c '[(.findings | map(.code)), (.errors | map(.code)), .documented]'"
check "for docs, it counts only the lints rustdoc reports" said '[["missing_docs","rustdoc::broken_intra_doc_links"],[null,"clippy::all"],["b 0.1.0"]]'
check "and an internal compiler error, or a denied lint it doesn't count, as an error" said '[null,"clippy::all"]'

begin "fmt"
new_case
run fmt clean
check "passes on the clean workspace" succeeded
check "and says so" said "Passed: every file is formatted as rustfmt would format it."
check "with an empty report" json_is "$(report fmt.json)" '.unformatted | length' 0
run fmt dirty run_record=true
check "fails on the dirty one" failed
check "naming the file, relative to the workspace root" said "  src/format.rs"
check "in the report" json_is "$(report fmt.json)" '.unformatted[0]' src/format.rs
check "with the diff" file_has "$(report fmt.diff)" "src/format.rs"
check "without colors" not_said $'\e['
check "and JUnit" file_has "$(report junit/fmt.xml)" 'failures="1"'
check "and a run record" json_is "$(report fmt.run-record.json)" '[.outcome, .counts.unformatted_files, .tool.name] | join(" ")' "findings 1 cargo"
run fmt dirty report_only=true
check "passes with report_only" succeeded
check "warning instead" said "WARN: rustfmt would change 1 file."
cp "${CASE}/fx/dirty/src/format.rs" "${WORK}/format.rs"
(cd "${CASE}/fx/dirty" && "${REAL_CARGO}" fmt --all)
run fmt dirty
check "passes once the file is formatted" succeeded
check "leaving no diff from the run before" absent "$(report fmt.diff)"
check "nor its run record" absent "$(report fmt.run-record.json)"
cp "${WORK}/format.rs" "${CASE}/fx/dirty/src/format.rs"
run fmt dirty packages=unused-helper
check "checks only the packages named" succeeded
run fmt dirty packages=nope
check "refuses a package that isn't a member" said "ERROR: packages names 'nope', which is not a member of the workspace"
run fmt clean "extra_args=--check"
check "refuses --check in extra_args" said "ERROR: extra_args can't set --check"
printf 'newline_style = "Unix"\n' > "${CASE}/fx/clean/rustfmt.toml"
sed -i 's/$/\r/' "${CASE}/fx/clean/helper/src/lib.rs"
run fmt clean
check "reports a file with the wrong line endings by its path" json_is "$(report fmt.json)" '.unformatted | join(",")' helper/src/lib.rs
rm "${CASE}/fx/clean/rustfmt.toml"
sed -i 's/\r$//' "${CASE}/fx/clean/helper/src/lib.rs"
printf 'pub fn broken( {\n' > "${CASE}/fx/clean/helper/src/lib.rs"
run fmt clean report_only=true run_record=true
check "fails on a file rustfmt can't parse, even with report_only" failed
check "saying why" said "ERROR: rustfmt could not check every file"
check "recorded as an error" json_is "$(report fmt.run-record.json)" .outcome error

begin "lint"
new_case
run lint clean
check "passes on the clean workspace" succeeded
check "and says so" said "Passed: clippy found no lints in app helper."
run lint dirty run_record=true
check "fails on the dirty one" failed
check "naming the lint and where" said "src/lib.rs:13:5: warning[clippy::needless_return]"
check "in SARIF" json_is "$(report clippy.sarif)" '[.runs[0].results[] | select(.ruleId == "clippy::needless_return") | .locations[0].physicalLocation.artifactLocation.uri] | first' src/lib.rs
check "with links to clippy's documentation" json_is "$(report clippy.sarif)" '.runs[0].tool.driver.rules[] | select(.id == "clippy::needless_return") | .helpUri' \
    "https://rust-lang.github.io/rust-clippy/master/index.html#needless_return"
check "and JUnit" xml_ok "$(report junit/clippy.xml)"
check "and a run record counting by lint" json_is "$(report clippy.run-record.json)" '.counts.by_lint["clippy::needless_return"]' 1
run lint dirty "lint_args=-D warnings"
check "counts a denied lint as a finding, not a failure to compile" said "ERROR: clippy found"
check "after checking every crate" not_said "did not compile"
run lint dirty "lint_args=--cap-lints=deny"
check "refuses --cap-lints in lint_args" said "ERROR: lint_args can't set --cap-lints"
run lint dirty report_only=true
check "passes with report_only" succeeded
printf 'pub fn broken() -> u32 { "text" }\n' > "${CASE}/fx/clean/helper/src/lib.rs"
run lint clean report_only=true run_record=true
check "fails on code that doesn't compile, even with report_only" failed
check "saying why" said "ERROR: The code did not compile"
check "with the compiler's error" said "mismatched types"
check "recorded as an error" json_is "$(report clippy.run-record.json)" .outcome error
check "without SARIF, which would claim a complete check" absent "$(report clippy.sarif)"

begin "docs"
new_case
run docs clean
check "passes on the clean workspace" succeeded
run docs dirty run_record=true
check "fails on the dirty one" failed
check "naming the broken link" said "warning[rustdoc::broken_intra_doc_links]"
check "recorded as findings" json_is "$(report docs.run-record.json)" '.counts.by_lint["rustdoc::broken_intra_doc_links"]' 1
run docs dirty RUSTDOCFLAGS="-D warnings"
check "counts a lint RUSTDOCFLAGS denies as a finding" said "ERROR: rustdoc found"
check "noting that it stopped rustdoc" said "A denied lint stopped rustdoc"
run docs dirty "extra_args=--open"
check "refuses --open" said "ERROR: extra_args can't set --open"
printf 'fn never_called() {}\n' >> "${CASE}/fx/clean/helper/src/lib.rs"
run docs clean
check "leaves the type-check's compiler warnings to lint" succeeded
printf 'fn main() { panic!("the build script fails"); }\n' > "${CASE}/fx/clean/helper/build.rs"
run docs clean report_only=true
check "fails when a build script fails, even with report_only" said "ERROR: The documentation could not be built"
check "naming what wasn't documented" said "Not documented, and not stopped by a documentation lint:"
rm "${CASE}/fx/clean/helper/build.rs"
printf 'pub fn broken() -> u32 { "text" }\n' > "${CASE}/fx/clean/helper/src/lib.rs"
run docs clean report_only=true
check "fails on code that doesn't compile, even with report_only" failed
check "saying why" said "ERROR: The documentation could not be built"

begin "test"
new_case
run test clean STUB_DOCTEST=pass run_record=true
check "passes when every test passes" succeeded
check "running nextest with the orb's JUnit config" called_with cargo-nextest nextest run --workspace --profile default --no-fail-fast "--no-tests=fail"
check "and the doctests, which nextest doesn't run" said "Running the doctests..."
check "counting both" said "Passed: 3 tests and 1 doctest passed."
check "copying nextest's JUnit" file_has "$(report junit/nextest/nextest.xml)" "tests::greets"
check "and writing the doctests'" file_has "$(report junit/nextest/doctests.xml)" "app/src/lib.rs - greet (line 5)"
check "reading escaped test names" json_is "$(report nextest.run-record.json)" '[.results[] | .name] | index("it'"'"'s <quoted>") != null' true
run test clean STUB_NEXTEST=fail STUB_DOCTEST=pass run_record=true
check "fails when a test fails" failed
check "naming it" said "app::doubling doubles_wrongly"
check "recorded as findings" json_is "$(report nextest.run-record.json)" '[.outcome, .counts.failed] | join(" ")' "findings 1"
run test clean STUB_DOCTEST=fail
check "fails when a doctest fails" failed
check "naming it" said "app/src/lib.rs - greet (line 5)"
run test clean STUB_DOCTEST=error
check "fails when the doctests don't build" said "ERROR: The tests could not run: the doctests did not build."
run test clean STUB_NEXTEST=flaky STUB_DOCTEST=pass
check "passes with a flaky test" succeeded
check "warning about it" said "WARN: 1 test was flaky"
run test clean STUB_NEXTEST=flakyfail STUB_DOCTEST=pass
check "counts flaky tests as failing when nextest fails the run on them" said "app sometimes"
check "as a failure, not a mismatch" not_said "names none"
run test clean STUB_NEXTEST=build STUB_DOCTEST=pass run_record=true
check "fails when the tests don't build" said "ERROR: The tests could not run: the tests did not build."
check "recorded as an error" json_is "$(report nextest.run-record.json)" .outcome error
check "without running the doctests" call_count cargo-doc 0
run test clean STUB_NEXTEST=none
check "fails when no test runs and no_tests is fail" said "no test ran, and no_tests is fail"
run test clean STUB_NEXTEST=mismatch STUB_DOCTEST=pass
check "fails when nextest's exit code and JUnit disagree" said "names none"
run test clean STUB_NEXTEST=fail STUB_DOCTEST=pass STUB_JUNIT_PATH=reports/junit.xml
check "reads the report where the repository's config put it" said "nextest wrote its JUnit report where the repository's config says"
check "naming the failing test from it" said "app::doubling doubles_wrongly"
run test clean STUB_NEXTEST=nojunit STUB_DOCTEST=pass
check "fails when nextest wrote no report it can read" said "ERROR: The tests could not run: cargo-nextest wrote no JUnit report"
run test clean STUB_DOCTEST=pass doctests=false
check "skips the doctests when doctests is false" call_count cargo-doc 0
run test clean STUB_DOCTEST=pass partition=true CIRCLE_NODE_TOTAL=3 CIRCLE_NODE_INDEX=1
check "runs its share with partition" called_with cargo-nextest --partition hash:2/3
check "where an empty share only warns" called_with cargo-nextest "--no-tests=warn"
check "and the doctests only on the first node" call_count cargo-doc 0
run test clean STUB_DOCTEST=pass partition=true CIRCLE_NODE_TOTAL=3 CIRCLE_NODE_INDEX=0
check "where it runs them" call_count cargo-doc 1
run test clean STUB_DOCTEST=pass "filter=test(greets)" retries=2 profile=ci
check "passes filter, retries and profile" called_with cargo-nextest -E "test(greets)" --retries 2 --profile ci
run test clean "profile=../x"
check "refuses a profile that isn't a name" said "ERROR: profile must be a nextest profile name"
run test clean "extra_args=--retries 3"
check "refuses what the parameters set in extra_args" said "ERROR: extra_args can't set --retries"
run test clean no_tests=maybe
check "refuses an unknown no_tests" said "ERROR: no_tests must be fail, warn or pass"

begin "coverage"
new_case
run coverage clean coverage_min=70 formats=lcov,cobertura,html run_record=true
check "passes above coverage_min" succeeded
check "saying how much is covered" said "75.00% of lines are covered (150 lines of 200), at least coverage_min (70%)."
check "cleaning old profiles first" called_with cargo-llvm-cov llvm-cov clean --workspace
check "running the tests once, without a report" called_with cargo-llvm-cov llvm-cov --no-report --workspace
check "writing LCOV" exists "$(report coverage.lcov)"
check "Cobertura" exists "$(report coverage.cobertura.xml)"
check "and HTML" exists "$(report coverage-html/html/index.html)"
check "recording the counts" json_is "$(report coverage.run-record.json)" '[.counts.lines, .counts.lines_covered, .counts.percent == 75] | map(tostring) | join(" ")' "200 150 true"
run coverage clean coverage_min=80
check "fails below coverage_min" failed
check "saying by how much" said "below coverage_min (80%)"
run coverage clean coverage_min=80 report_only=true
check "passes with report_only" succeeded
run coverage clean coverage_min=100 STUB_COV_LINES="2000 1999"
check "compares exactly: 1999 of 2000 lines is below 100" said "99.95% of lines are covered (1999 lines of 2000), below coverage_min (100%)."
run coverage clean nextest=true
check "runs the tests with nextest when nextest is true" called_with cargo-llvm-cov llvm-cov nextest --no-report
run coverage clean STUB_COV_LINES="0 0" "ignore_filename_regex=src/" report_only=true
check "fails when it measured no lines, even with report_only" said "ERROR: cargo-llvm-cov measured no lines (ignore_filename_regex may match every file)"
run coverage clean "extra_args=--release --target x86_64-unknown-linux-gnu --no-cfg-coverage"
check "gives report the options that say where the run's objects are" called_with cargo-llvm-cov llvm-cov report --json --release --target x86_64-unknown-linux-gnu
check "but not the others" not_called_with cargo-llvm-cov report --no-cfg-coverage
check "and the packages the run selected" called_with cargo-llvm-cov llvm-cov report --json --workspace
run coverage clean packages=helper
check "-p each, when packages names them" called_with cargo-llvm-cov llvm-cov report --json -p helper
run coverage clean nextest=true "extra_args=--profile ci --cargo-profile=release"
check "with nextest, the build profile is --cargo-profile's" called_with cargo-llvm-cov llvm-cov report --json --profile=release
check "not nextest's own --profile" not_called_with cargo-llvm-cov report ci
run coverage clean "extra_args=--profile release"
check "and without, --profile's" called_with cargo-llvm-cov llvm-cov report --json --profile release
run coverage clean STUB_COV=fail report_only=true
check "fails when the tests fail, even with report_only" said "ERROR: the tests failed or did not build"
run coverage clean STUB_COV=nollvm
check "explains a missing llvm-tools component" said "can't find the toolchain's llvm-tools component"
run coverage clean STUB_COV=badreport
check "fails when the report can't be written" said "ERROR: cargo-llvm-cov could not write the coverage report"
run coverage clean coverage_min=101
check "refuses a coverage_min above 100" said "ERROR: coverage_min must be a percentage from 0 to 100"
run coverage clean formats=json
check "refuses an unknown format" said "ERROR: formats can name lcov, cobertura and html, not 'json'."
run coverage clean "extra_args=--fail-under-lines 90"
check "refuses gates of its own in extra_args" said "ERROR: extra_args can't set --fail-under-lines"

begin "msrv"
new_case
run msrv clean toolchain_source=rustup run_record=true
check "passes when every package builds on its rust-version" succeeded
check "installing that toolchain with rustup" called_with rustup toolchain install 1.70 --profile minimal --no-self-update
check "and checking every package that declares it, in one run" called_with rustup run 1.70 cargo check -p app -p helper
check "with that toolchain's rustc, whatever rustc comes first on the PATH" called_with rustup run 1.70 "RUSTC=/rustup/toolchains/1.70/bin/rustc"
check "recording the version" json_is "$(report msrv.run-record.json)" '.results[0] | [.version, .source, .status] | join(" ")' "1.70 rustup passed"
run msrv dirty toolchain_source=rustup STUB_RUSTUP_FAIL=1.70 run_record=true
check "fails when a package doesn't build on its rust-version" failed
check "saying which" said "fails on 1.70."
check "with the compiler's output" said "use of unstable library feature"
check "recorded as findings" json_is "$(report msrv.run-record.json)" .outcome findings
run msrv dirty toolchain_source=rustup STUB_RUSTUP_FAIL=1.70 report_only=true
check "passes with report_only" succeeded
run msrv clean toolchain_source=rustup STUB_RUSTUP_DEP=1.70
check "counts a dependency that needs a newer Rust as a finding" said "fails on 1.70."
run msrv clean toolchain_source=rustup STUB_RUSTUP_NET=1.70 report_only=true
check "fails when cargo can't fetch the dependencies, even with report_only" said "ERROR: cargo check could not run with Rust 1.70"
run msrv clean toolchain_source=rustup rust_version=1.75
run msrv clean toolchain_source=rustup
check "removes the logs an earlier run left for other versions" absent "$(report msrv-1.75.log)"
check "and keeps this run's" exists "$(report msrv-1.70.log)"
run msrv clean toolchain_source=rustup STUB_RUSTUP_NOINSTALL=1.70 report_only=true
check "fails when the toolchain can't be installed, even with report_only" said "ERROR: rustup could not install the 1.70 toolchain"
run msrv clean toolchain_source=rustup rust_version=1.75 packages=helper
check "checks with rust_version instead, when set" called_with rustup run 1.75 cargo check -p helper
sed -i '/^rust-version/d' "${CASE}/fx/clean/app/Cargo.toml"
run msrv clean toolchain_source=rustup
check "skips a package without rust-version" said "No rust-version in the Cargo.toml of app"
check "checking the rest" called_with rustup run 1.70 cargo check -p helper
run msrv clean toolchain_source=rustup packages=app
check "fails when nothing declares one" said "ERROR: No selected package declares a rust-version"
run msrv clean toolchain_source=rustup rust_version=1.70.x
check "refuses a rust_version that isn't a version" said "ERROR: rust_version must be a Rust version"
new_case
run msrv clean toolchain_source=rust SCRIPT_RUST_INSTALL="$(cat "${WORK}/install-rust.sh")" run_record=true
check "installs the newest patch release in the table with toolchain_source rust" succeeded
check "verified as install_rust does" file_has "${CALLS}/install-rust.1" "PARAM_VERIFY_CHECKSUMS=strict"
check "release 1.70.1" file_has "${CALLS}/install-rust.1" "PARAM_VERSION=1.70.1"
check "with no components" file_has "${CALLS}/install-rust.1" "PARAM_COMPONENTS="
check "into a directory of its own" said "(from rust)"
check "and checks with its cargo, not rustup's" called_with cargo-msrv check -p app -p helper RUSTUP_TOOLCHAIN=unset
check "with its rustc" grep -q "^RUSTC=.*/toolchains/1.70.1/bin/rustc$" "${CALLS}/cargo-msrv.1"
check "exporting nothing to later steps" not_file_has "${CASE}/bash_env" SHOULD_NOT_LEAK
run msrv clean toolchain_source=rust SCRIPT_RUST_INSTALL="$(cat "${WORK}/install-rust.sh")" rust_version=1.70.0
check "installs exactly the patch release rust_version names" file_has "${CALLS}/install-rust.1" "PARAM_VERSION=1.70.0"
run msrv clean toolchain_source=rust SCRIPT_RUST_INSTALL="$(cat "${WORK}/install-rust.sh")" rust_version=1.71
check "fails for a version the table doesn't list" said "ERROR: this orb's checksum table lists no Rust 1.71 release"
run msrv clean toolchain_source=rust SCRIPT_RUST_INSTALL="$(cat "${WORK}/install-rust.sh")" rust_version=1.71 verify_checksums=known_versions
check "unless verify_checksums allows it, as its .0 release" file_has "${CALLS}/install-rust.1" "PARAM_VERSION=1.71.0"
run msrv clean toolchain_source=rust SCRIPT_RUST_INSTALL="$(cat "${WORK}/install-rust.sh")" STUB_RUST_NOINSTALL=1.70.1 report_only=true
check "fails when the toolchain can't be installed, even with report_only" said "ERROR: Rust 1.70.1 could not be installed"
run msrv clean toolchain_source=rust SCRIPT_RUST_INSTALL="$(cat "${WORK}/install-rust.sh")" STUB_MSRV_FAIL=1.70.1
check "and reports a package that doesn't build on it" said "app, helper fails on 1.70"
run msrv clean toolchain_source=rust SCRIPT_RUST_INSTALL=
check "needs the install script for toolchain_source rust" said "ERROR: The Rust install script was not loaded"
run msrv clean toolchain_source=other
check "refuses an unknown toolchain_source" said "ERROR: toolchain_source must be auto, rustup or rust"
# msrv_cache_key.sh: the cache key names the Rust versions the step installs.
key() {
    OUTPUT=$(cd "${CASE}/fx/$1" && env PATH="${STUBS}:${PATH}" ORB_CACHE_KEY_FILE="${CASE}/key" PARAM_PACKAGES="$2" PARAM_RUST_VERSION="$3" \
        bash "${SCRIPTS}/msrv_cache_key.sh" 2>&1 && cat "${CASE}/key")
    RC=$?
}
key clean "" ""
check "msrv's cache key names the members' rust-versions" [ "$(sed -n 3p "${CASE}/key")" == 1.70 ]
key clean "" 1.75
check "or rust_version" [ "$(sed -n 3p "${CASE}/key")" == 1.75 ]
sed -i 's/^rust-version = .*/rust-version = "1.72"/' "${CASE}/fx/clean/helper/Cargo.toml"
key clean "helper" ""
check "of the selected packages only" [ "$(sed -n 3p "${CASE}/key")" == 1.72 ]
key clean "" ""
check "each version once" [ "$(sed -n 3p "${CASE}/key")" == "1.70 1.72" ]

begin "features"
new_case
run features dirty run_record=true
check "passes when every combination builds" succeeded
check "running cargo-hack with --keep-going and ungrouped output" called_with cargo-hack hack check --workspace --each-feature --keep-going --log-group none
check "counting the combinations" said "builds (3 in all)."
check "recording each" json_is "$(report features.run-record.json)" '[.results[] | .package] | unique | join(" ")' dirty
run features dirty STUB_HACK=fail run_record=true
check "fails when a combination doesn't build" failed
check "naming it" said "dirty: cargo check --no-default-features --features extra"
check "in the report" json_is "$(report features.json)" '[.combinations[] | select(.status == "failed") | .command] | join(",")' "cargo check --no-default-features --features extra"
check "and JUnit" file_has "$(report junit/features.xml)" 'failures="1"'
check "recorded as findings" json_is "$(report features.run-record.json)" '[.outcome, .counts.combinations, .counts.failed] | join(" ")' "findings 3 1"
run features dirty STUB_HACK=fail report_only=true
check "passes with report_only" succeeded
run features dirty STUB_HACK=fail GITHUB_ACTIONS=true
check "reads plain progress lines on GitHub Actions too" said "dirty: cargo check --no-default-features --features extra"
run features dirty STUB_HACK=notarget report_only=true
check "fails when a target's standard library is missing, even with report_only" said "ERROR: cargo-hack could not check cargo check --no-default-features --features extra"
check "saying why" said "can't find crate for"
run features dirty STUB_HACK=network report_only=true
check "and when a crate can't be downloaded" said "failed to download from"
run features dirty targets=wasm32-unknown-unknown
check "lists its logs in the report" json_is "$(report features.json)" '.logs | length' 2
run features dirty
check "removes the logs an earlier run left for other targets" absent "$(report features-wasm32-unknown-unknown.log)"
run features dirty STUB_HACK=crash report_only=true
check "fails when cargo-hack fails before running, even with report_only" said "ERROR: cargo-hack failed before it could run every combination"
run features dirty STUB_HACK=quiet report_only=true
check "and when it fails without its summary" said "ERROR: cargo-hack failed before it could run every combination"
run features dirty targets=wasm32-unknown-unknown
check "runs once for the machine's own target and once per target" call_count cargo-hack 3
check "passing the target" called_with cargo-hack --target wasm32-unknown-unknown
run features dirty mode=feature_powerset depth=2 skip_features=fast,extra no_dev_deps=true
check "passes mode, depth, skip_features and no_dev_deps" called_with cargo-hack --feature-powerset --depth 2 --skip fast,extra --no-dev-deps
run features dirty depth=2
check "and depth only with feature_powerset" not_called_with cargo-hack --depth
run features dirty subcommand=test no_dev_deps=true
check "refuses no_dev_deps for a subcommand that needs them" said "ERROR: no_dev_deps works only with subcommand check or build"
run features dirty "extra_args=--log-group github-actions"
check "refuses --log-group in extra_args" said "ERROR: extra_args can't set --log-group"
run features dirty mode=each
check "refuses an unknown mode" said "ERROR: mode must be each_feature or feature_powerset"

begin "unused_deps"
new_case
OFFSET=$(grep -bo '^unused-helper = ' "${CASE}/fx/dirty/Cargo.toml" | cut -d: -f1)
LINE=$(grep -n '^unused-helper = ' "${CASE}/fx/dirty/Cargo.toml" | cut -d: -f1)
run unused_deps dirty run_record=true
check "passes when cargo-shear finds nothing" succeeded
check "checking the whole workspace, which it does without -p" not_called_with cargo-shear -p
check "with JSON output" called_with cargo-shear shear --format json --color never
run unused_deps dirty STUB_SHEAR=unused STUB_OFFSET="${OFFSET}" run_record=true
check "fails on an unused dependency" failed
check "naming it, with its line and column" said "Cargo.toml:${LINE}:1: error[shear/unused_dependency]: unused dependency \`unused-helper\`"
check "in the report" json_is "$(report unused-deps.json)" '.findings[0] | [.line, .column, .counted] | join(" ")' "${LINE} 1 true"
check "and JUnit" file_has "$(report junit/unused-deps.xml)" 'failures="1"'
check "recorded as findings" json_is "$(report unused-deps.run-record.json)" '[.outcome, .counts.findings] | join(" ")' "findings 1"
run unused_deps dirty STUB_SHEAR=unused STUB_OFFSET="${OFFSET}" report_only=true
check "passes with report_only" succeeded
run unused_deps dirty STUB_SHEAR=warn
check "passes with only warnings" succeeded
check "showing them" said "cargo-shear also warns about this, which counts only with deny_warnings:"
run unused_deps dirty STUB_SHEAR=warn deny_warnings=true
check "and fails on them with deny_warnings" failed
check "passing --deny-warnings" called_with cargo-shear --deny-warnings
run unused_deps dirty STUB_SHEAR=crash report_only=true run_record=true
check "fails when cargo-shear can't check, even with report_only" said "ERROR: cargo-shear could not check the workspace (exit code 2)"
check "showing its error" said "failed to parse manifest"
check "recorded as an error" json_is "$(report unused-deps.run-record.json)" .outcome error
run unused_deps dirty STUB_SHEAR=mismatch
check "fails when its exit code and report disagree" said "doesn't match its report"
run unused_deps dirty packages=unused-helper locked=true
check "selects packages with -p, and passes locked" called_with cargo-shear -p unused-helper --locked
run unused_deps dirty "extra_args=--fix"
check "refuses --fix" said "ERROR: extra_args can't set --fix"
run unused_deps dirty "extra_args=--exclude unused-helper ../clean"
check "refuses a directory, but not an option's value" said "ERROR: extra_args can't name a directory ('../clean')"

begin "semver_checks"
new_case
run semver_checks semver/current run_record=true
check "passes when semver allows every change" succeeded
check "checking the workspace against the registry by default" called_with cargo-semver-checks semver-checks check-release --workspace --color never
check "saying what it compared" said "shapes: v0.1.0 -> v0.1.1 (patch change): no semver update required"
check "recording the package" json_is "$(report semver-checks.run-record.json)" '.results[0] | [.name, .baseline_version, .current_version] | join(" ")' "shapes 0.1.0 0.1.1"
run semver_checks semver/current STUB_SEMVER=fail run_record=true
check "fails on a failed lint" failed
check "naming it and what it found" said "shapes: failure[function_missing]: pub fn removed or renamed"
check "with the items" said "function shapes::square_perimeter, previously in file src/lib.rs:10"
check "in the report" json_is "$(report semver-checks.json)" '.lints[0] | [.package, .level, .lint, (.items | length)] | join(" ")' "shapes failure function_missing 1"
check "and JUnit" file_has "$(report junit/semver-checks.xml)" 'name="function_missing"'
check "recorded as findings" json_is "$(report semver-checks.run-record.json)" '[.outcome, .counts.failed_lints] | join(" ")' "findings 1"
run semver_checks semver/current STUB_SEMVER=fail report_only=true
check "passes with report_only" succeeded
run semver_checks semver/current STUB_SEMVER=old-fail
check "reads a failed lint from releases before 0.49.0 too" said "ERROR: 1 semver lint fails"
run semver_checks semver/current STUB_SEMVER=old-error report_only=true
check "and tells their errors apart, failing even with report_only" said "ERROR: cargo-semver-checks could not complete the check (exit code 1)"
run semver_checks semver/current STUB_SEMVER=error report_only=true
check "fails when it can't complete" said "ERROR: cargo-semver-checks could not complete the check (exit code 101)"
check "explaining rustdoc JSON versions" said "reads the rustdoc JSON of a range of Rust releases"
run semver_checks semver/current STUB_SEMVER=none
check "fails when it checks nothing" said "ERROR: cargo-semver-checks checked no package"
run semver_checks semver/current STUB_SEMVER=warn
check "passes with a lint at warn level" succeeded
check "showing it" said "shapes: warning[function_must_use_added]"
run semver_checks semver/current "baseline_root=${CASE}/fx/semver/baseline" release_type=major packages=shapes run_record=true
check "passes baseline_root, release_type and packages" called_with cargo-semver-checks -p shapes --baseline-root "${CASE}/fx/semver/baseline" --release-type major
check "recording the baseline's manifest" json_is "$(report semver-checks.run-record.json)" '.inputs[] | select(.role == "baseline") | .path' "${CASE}/fx/semver/baseline/Cargo.toml"
run semver_checks semver/current baseline_rev=origin/main
check "passes baseline_rev" called_with cargo-semver-checks --baseline-rev origin/main
run semver_checks semver/current baseline_rev=origin/main baseline_version=0.1.0
check "refuses two baselines" said "ERROR: Set at most one of baseline_rev, baseline_version and baseline_root"
run semver_checks semver/current baseline_version=latest
check "refuses a baseline_version that isn't a version" said "ERROR: baseline_version must be a version"
run semver_checks semver/current "baseline_root=${CASE}/nope"
check "refuses a baseline_root that isn't a directory" said "ERROR: baseline_root must be a directory"
run semver_checks semver/current baseline_rev=--upload-pack=x
check "refuses a baseline that looks like an option" said "can't start with '-'"
run semver_checks semver/current release_type=huge
check "refuses an unknown release_type" said "ERROR: release_type must be major, minor or patch"
run semver_checks semver/current "extra_args=-qq"
check "refuses -q in extra_args" said "ERROR: extra_args can't set -qq"

begin "every run record matches schemas/run-record.v1.json"
SCHEMA="${ROOT}/schemas/run-record.v1.json"
# shellcheck disable=SC2016 # jq program, not shell
SCHEMA_CHECK='
    [($schema.required[] as $key | select(has($key) | not) | "no \($key)"),
     (select(.schema != $schema.properties.schema.const) | "schema is \(.schema)"),
     (select(.command as $c | $schema.properties.command.enum | index($c) | not) | "command \(.command)"),
     (select(.outcome as $o | $schema.properties.outcome.enum | index($o) | not) | "outcome \(.outcome)"),
     (.inputs[] | select(.role as $r | $schema.properties.inputs.items.properties.role.enum | index($r) | not) | "input role \(.role)"),
     (.inputs[] | select(.sha256 != null and (.sha256 | test("^[0-9a-f]{64}$") | not)) | "input sha256 \(.sha256)"),
     (.reports[] | select(.sha256 | test("^[0-9a-f]{64}$") | not) | "report sha256 \(.sha256)"),
     (select(.tool != null and (.tool | has("sha512") and has("install") | not)) | "tool without sha512 or install"),
     (select(.toolchain != null and (.toolchain | has("cargo") and has("rustc") and has("env") | not)) | "toolchain without cargo, rustc or env")]
    | join("; ")'
problems=""
commands_seen=""
for record in "${WORK}/records"/*.json; do
    [[ -f "${record}" ]] || continue
    problem=$(jq -r --slurpfile schema "${SCHEMA}" "\$schema[0] as \$schema | ${SCHEMA_CHECK}" "${record}" 2>&1)
    if [[ -n "${problem}" ]]; then
        problems+="${record##*/}: ${problem}"$'\n'
    fi
    commands_seen+=" $(jq -r .command "${record}")"
done
OUTPUT=${problems}
check "every record has the fields and values the schema allows" [ -z "${problems}" ]
for command in fmt lint docs test coverage msrv features unused_deps semver_checks; do
    check "${command} wrote one" [ -n "$(tr ' ' '\n' <<< "${commands_seen}" | grep -x "${command}")" ]
done
if command -v python3 > /dev/null 2>&1 && python3 -c 'import jsonschema' 2> /dev/null; then
    OUTPUT=$(python3 -I -c '
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
jsonschema.Draft202012Validator.check_schema(schema)
validator = jsonschema.Draft202012Validator(schema)
bad = 0
for path in sys.argv[2:]:
    for error in validator.iter_errors(json.load(open(path))):
        print("%s: %s at %s" % (path.rsplit("/", 1)[-1], error.message, "/".join(map(str, error.absolute_path))))
        bad += 1
sys.exit(1 if bad else 0)' "${SCHEMA}" "${WORK}/records"/*.json 2>&1)
    check "and validates against it with jsonschema" [ $? -eq 0 ]
else
    echo "  skip: Python's jsonschema is not installed, so only the checks above ran"
fi

echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed"
    exit 1
fi
echo "ok: every check passed"
