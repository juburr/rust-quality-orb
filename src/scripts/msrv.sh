#!/bin/bash
#
# Checks each package with the Rust version its Cargo.toml declares as
# rust-version (or with rust_version), for the msrv command: cargo check
# with that version's toolchain, one run per version, on the packages that
# declare it. The toolchain comes from rustup, or else is installed the way
# install_rust installs it, verified, into a directory of this step's own,
# so the job's toolchain stays the one on the PATH. Either way cargo runs
# with RUSTC and RUSTDOC naming that toolchain's own, since cargo would
# otherwise run the first rustc on the PATH. A package that doesn't build on
# its version is a finding; a toolchain that can't be installed, or a check
# that fails for another reason (a dependency that can't be fetched, a
# Cargo.lock that version's cargo can't read), fails the step whatever
# report_only says.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_QUALITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
JUNIT=$(rq_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(rq_bool report_only "${PARAM_REPORT_ONLY}")
RUN_RECORD=$(rq_bool run_record "${PARAM_RUN_RECORD}")
ALL_TARGETS=$(rq_bool all_targets "${PARAM_ALL_TARGETS}")
LOCKED=$(rq_bool locked "${PARAM_LOCKED}")
CACHING=$(rq_bool caching "${PARAM_CACHING}")
RUST_VERSION=$(rq_subst "${PARAM_RUST_VERSION}")
if [[ -n "${RUST_VERSION}" ]] && ! rq_match "${RUST_VERSION}" '^1\.[0-9]+(\.[0-9]+)?$'; then
    echo "ERROR: rust_version must be a Rust version such as 1.70 or 1.70.0, not '${RUST_VERSION}'." >&2
    exit 1
fi
case "${PARAM_TOOLCHAIN_SOURCE}" in
    auto | rustup | rust) ;;
    *)
        echo "ERROR: toolchain_source must be auto, rustup or rust, not '${PARAM_TOOLCHAIN_SOURCE}'." >&2
        exit 1
        ;;
esac
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
# The per-version logs an earlier run listed, since this run's versions can
# differ.
if [[ -f "${RQ_BASE}.json" ]]; then
    while IFS= read -r log; do
        if [[ "${log}" == "${RQ_BASE}-"*.log && "${log}" != */../* ]]; then
            rm -f -- "${log}"
        fi
    done < <(jq -r '.versions[]?.log // empty' "${RQ_BASE}.json" 2> /dev/null || true)
fi
rq_clear_reports .json
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_feature_args "${PARAM_FEATURES}" "${PARAM_ALL_FEATURES}" "${PARAM_NO_DEFAULT_FEATURES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --message-format

SOURCE=${PARAM_TOOLCHAIN_SOURCE}
if [[ "${SOURCE}" == auto ]]; then
    SOURCE=rust
    if command -v rustup > /dev/null 2>&1; then
        SOURCE=rustup
    fi
fi
if [[ "${SOURCE}" == rustup ]] && ! RUSTUP=$(command -v rustup); then
    echo "ERROR: toolchain_source is rustup, but rustup is not on the PATH. Install it with install_rustup, or use" >&2
    echo "  toolchain_source rust." >&2
    exit 1
fi
if [[ "${SOURCE}" == rust && -z "${SCRIPT_RUST_INSTALL:-}" ]]; then
    echo "ERROR: The Rust install script was not loaded: SCRIPT_RUST_INSTALL is empty." >&2
    exit 1
fi

# The Rust version of each selected package: rust_version, or its own
# rust-version, which cargo metadata reports as 1.70 or 1.70.0.
declare -A BY_VERSION=()
SKIPPED=()
while IFS=$'\t' read -r name version; do
    if [[ -n "${RUST_VERSION}" ]]; then
        version=${RUST_VERSION}
    fi
    if [[ -z "${version}" || "${version}" == null ]]; then
        SKIPPED+=("${name}")
        continue
    fi
    BY_VERSION[${version}]+="${BY_VERSION[${version}]:+ }${name}"
done < <(jq -r --arg packages " ${RQ_PACKAGES[*]} " '.packages[] | select(.name as $name | $packages | contains(" " + $name + " "))
    | [.name, (.rust_version // "")] | @tsv' "${RQ_METADATA}")
if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
    echo "No rust-version in the Cargo.toml of ${SKIPPED[*]}, so $(rq_plural "${#SKIPPED[@]}" "it is" "they are") not checked."
fi
if [[ "${#BY_VERSION[@]}" -eq 0 ]]; then
    echo "ERROR: No selected package declares a rust-version, and rust_version is empty, so there is nothing to check." >&2
    echo "  Declare rust-version in Cargo.toml's [package] (or [workspace.package]), or set rust_version." >&2
    exit 1
fi
mapfile -t VERSIONS < <(printf '%s\n' "${!BY_VERSION[@]}" | sort -V)

# rust_release VERSION: the release install_rust's table lists for VERSION:
# itself when it names a patch release, else the newest patch release of it.
rust_release() {
    local arch
    case "$(uname -m)" in
        x86_64 | amd64) arch=amd64 ;;
        *) arch=arm64 ;;
    esac
    if [[ "$1" =~ ^1\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$1"
        return 0
    fi
    grep -oE "\[\"${1//./\\.}\.[0-9]+/${arch}\"\]" <<< "${SCRIPT_RUST_INSTALL}" \
        | sed -E 's/^\["([0-9.]+)\/.*/\1/' | sort -V | tail -n 1 || true
}

if [[ "${SOURCE}" == rust ]]; then
    printf '%s' "${SCRIPT_RUST_INSTALL}" > "${RQ_WORK}/install-rust.sh"
fi
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs
RESULTS="[]"
ERROR=""
FAILED=0
for version in "${VERSIONS[@]}"; do
    read -r -a packages <<< "${BY_VERSION[${version}]}"
    log="${RQ_BASE}-${version}.log"
    : > "${log}"
    RQ_REPORTS+=("${log}")
    echo "Checking ${packages[*]} with Rust ${version} (from ${SOURCE})..."
    if [[ "${SOURCE}" == rustup ]]; then
        toolchain=${version}
        if ! "${RUSTUP}" toolchain install "${version}" --profile minimal --no-self-update >> "${log}" 2>&1; then
            ERROR="rustup could not install the ${version} toolchain"
            break
        fi
        if ! rustc=$("${RUSTUP}" which --toolchain "${version}" rustc 2>> "${log}") \
            || ! rustdoc=$("${RUSTUP}" which --toolchain "${version}" rustdoc 2>> "${log}"); then
            ERROR="rustup could not find the rustc of the ${version} toolchain"
            break
        fi
        cargo=(env "RUSTC=${rustc}" "RUSTDOC=${rustdoc}" "${RUSTUP}" run "${version}" cargo)
    else
        toolchain=$(rust_release "${version}")
        if [[ -z "${toolchain}" ]]; then
            if [[ "${PARAM_VERIFY_CHECKSUMS}" == strict ]]; then
                ERROR="this orb's checksum table lists no Rust ${version} release (it lists 1.56.0 and later); use toolchain_source rustup for older ones"
                break
            fi
            toolchain="${version}.0"
        fi
        dir="${RQ_WORK}/toolchains/${toolchain}"
        # Installed as install_rust does it, but with nothing exported to
        # later steps, and run outside the workspace, whose
        # rust-toolchain.toml it would warn about.
        if ! (cd "${RQ_WORK}" && env BASH_ENV="${RQ_WORK}/install.env" PARAM_VERSION="${toolchain}" PARAM_INSTALL_PATH="${dir}" \
            PARAM_COMPONENTS= PARAM_TARGETS= PARAM_VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}" PARAM_CACHING="${CACHING}" \
            PARAM_DOWNLOAD_BASE_URL="${PARAM_DOWNLOAD_BASE_URL}" bash "${RQ_WORK}/install-rust.sh") >> "${log}" 2>&1; then
            ERROR="Rust ${toolchain} could not be installed"
            break
        fi
        cargo=(env -u RUSTUP_TOOLCHAIN "PATH=${dir}/bin:${PATH}" "RUSTC=${dir}/bin/rustc" "RUSTDOC=${dir}/bin/rustdoc" "${dir}/bin/cargo")
    fi
    args=(check)
    for package in "${packages[@]}"; do
        args+=(-p "${package}")
    done
    args+=(${RQ_FEATURE_ARGS[@]+"${RQ_FEATURE_ARGS[@]}"})
    if [[ "${ALL_TARGETS}" == true ]]; then
        args+=(--all-targets)
    fi
    if [[ "${LOCKED}" == true ]]; then
        args+=(--locked)
    fi
    args+=(${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"})
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_ARGS=("${args[@]}")
    status=passed
    start=$(wc -l < "${log}")
    if ! CARGO_TERM_COLOR=never "${cargo[@]}" "${args[@]}" >> "${log}" 2>&1; then
        tail -n 30 "${log}" | sed 's/^/  /'
        # The code doesn't build on this version when rustc failed on it, a
        # build script failed, or a dependency needs a newer Rust; anything
        # else (a missing target, a download, an unreadable Cargo.lock) is
        # the check failing.
        output=$(tail -n "+$((start + 1))" "${log}")
        if grep -qE 'error: could not compile `|failed to run custom build command for|cannot be built because it requires rustc|is not supported by the following package' <<< "${output}" \
            && ! grep -q 'target may not be installed' <<< "${output}"; then
            status=failed
            FAILED=$((FAILED + 1))
        else
            ERROR="cargo check could not run with Rust ${version}"
            if grep -q 'lock file version' <<< "${output}"; then
                ERROR+=". Its cargo can't read Cargo.lock's format: Cargo.lock version 4 needs Rust 1.78. Write version 3 for older ones (cargo picks it when rust-version is older than 1.78, for a new Cargo.lock)"
            fi
            break
        fi
    fi
    RESULTS=$(jq -c --arg version "${version}" --arg toolchain "${toolchain}" --arg source "${SOURCE}" --arg status "${status}" \
        --arg log "${log}" --args '. + [{version: $version, toolchain: $toolchain, source: $source, packages: $ARGS.positional,
        status: $status, log: $log}]' "${packages[@]}" <<< "${RESULTS}")
    echo "  Rust ${version}: ${status}."
done

REPORT="${RQ_BASE}.json"
jq -n --argjson results "${RESULTS}" --arg error "${ERROR}" --args '{versions: $results, not_checked: $ARGS.positional,
    error: (if $error == "" then null else $error end)}' ${SKIPPED[@]+"${SKIPPED[@]}"} > "${REPORT}"
RQ_REPORTS+=("${REPORT}")
if [[ "${JUNIT}" == true ]]; then
    rq_junit "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" msrv "$(jq -c '[.versions[] | {classname: "msrv",
        name: "Rust \(.version): \(.packages | join(", "))", status: (if .status == "failed" then "failed" else "passed" end),
        message: (if .status == "failed" then "cargo check failed with Rust \(.toolchain); its output is in \(.log)" else null end)}]' "${REPORT}")"
    RQ_REPORTS+=("${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

if [[ -n "${ERROR}" ]]; then
    OUTCOME=error
elif [[ "${FAILED}" -gt 0 && "${REPORT_ONLY}" == true ]]; then
    OUTCOME=findings-reported
elif [[ "${FAILED}" -gt 0 ]]; then
    OUTCOME=findings
else
    OUTCOME=passed
fi
if [[ "${RUN_RECORD}" == true ]]; then
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_TOOL=${RQ_CARGO}
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -c '{versions: (.versions | length), failed: ([.versions[] | select(.status == "failed")] | length),
        packages_not_checked: (.not_checked | length)}' "${REPORT}")
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_RESULTS=$(jq -c '.versions' "${REPORT}")
    rq_run_record "${RQ_BASE}.run-record.json" msrv "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ -n "${ERROR}" ]]; then
    echo "ERROR: ${ERROR}, so the step fails whatever report_only says. Its output:" >&2
    rq_tail "${log}"
    exit 1
fi
if [[ "${FAILED}" -gt 0 ]]; then
    rq_gate true "${REPORT_ONLY}" "not every package builds with the Rust version it declares: $(jq -r '[.versions[] | select(.status == "failed") | "\(.packages | join(", ")) fails on \(.version)"] | join("; ")' "${REPORT}")."
fi
rq_gate false "${REPORT_ONLY}" "every package builds with the Rust version it declares ($(jq -r '[.versions[] | "\(.packages | join(", ")) on \(.version)"] | join("; ")' "${REPORT}"))."
