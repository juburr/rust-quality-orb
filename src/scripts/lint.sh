#!/bin/bash
#
# Runs clippy (cargo clippy), for the lint command, and reports every lint it
# and rustc find: the default ones, those the crates' attributes and
# Cargo.toml's [lints] turn on, and those lint_args adds. Lints run capped at
# warning level (--cap-lints warn), so a lint the code denies doesn't stop
# the build at the first crate and hide the rest: each lint at any level is
# a finding. A build that still fails has code that doesn't compile, which
# fails the step whatever report_only says. cargo's JSON messages tell the
# two apart (see RQ_DIAGNOSTICS_JQ).

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
SARIF=$(rq_bool sarif "${PARAM_SARIF}")
ALL_TARGETS=$(rq_bool all_targets "${PARAM_ALL_TARGETS}")
LOCKED=$(rq_bool locked "${PARAM_LOCKED}")
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rq_clear_reports .raw.jsonl .json .sarif
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_feature_args "${PARAM_FEATURES}" "${PARAM_ALL_FEATURES}" "${PARAM_NO_DEFAULT_FEATURES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --message-format
rq_words lint_args "$(rq_subst "${PARAM_LINT_ARGS}")"
LINT_ARGS=(${RQ_WORDS[@]+"${RQ_WORDS[@]}"})
for word in ${LINT_ARGS[@]+"${LINT_ARGS[@]}"}; do
    if [[ "${word}" == --cap-lints || "${word}" == --cap-lints=* ]]; then
        echo "ERROR: lint_args can't set --cap-lints: this command runs every lint capped at warning level, so that a denied lint" >&2
        echo "  doesn't hide the rest, and counts each as a finding." >&2
        exit 1
    fi
done
if ! RQ_TOOL_VERSION=$("${RQ_CARGO}" clippy --version 2> "${RQ_WORK}/version.err"); then
    echo "ERROR: cargo clippy is not available: install the clippy component, with install_rust or install_rustup" >&2
    echo "  (components: clippy), or rustup component add clippy. Its output:" >&2
    rq_tail "${RQ_WORK}/version.err"
    exit 1
fi
# shellcheck disable=SC2034 # read by rq_run_record
RQ_TOOL=${RQ_CARGO}

RQ_ARGS=(clippy "${RQ_PACKAGE_ARGS[@]}" ${RQ_FEATURE_ARGS[@]+"${RQ_FEATURE_ARGS[@]}"})
if [[ "${ALL_TARGETS}" == true ]]; then
    RQ_ARGS+=(--all-targets)
fi
if [[ "${LOCKED}" == true ]]; then
    RQ_ARGS+=(--locked)
fi
RQ_ARGS+=(--message-format=json ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"} -- ${LINT_ARGS[@]+"${LINT_ARGS[@]}"} --cap-lints warn)
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs
for config in clippy.toml .clippy.toml; do
    if [[ -f "${RQ_WORKSPACE_ROOT}/${config}" ]]; then
        RQ_INPUTS+=("config:${RQ_WORKSPACE_ROOT}/${config}")
    fi
done

echo "Running ${RQ_TOOL_VERSION} on ${RQ_PACKAGES[*]:-the workspace}..."
RC=0
CARGO_TERM_COLOR=never "${RQ_CARGO}" "${RQ_ARGS[@]}" > "${RQ_BASE}.raw.jsonl" 2> "${RQ_WORK}/err" || RC=$?
RQ_REPORTS=("${RQ_BASE}.raw.jsonl")
REPORT="${RQ_BASE}.json"
if ! jq -s --argjson docs false "${RQ_DIAGNOSTICS_JQ}" "${RQ_BASE}.raw.jsonl" > "${REPORT}" 2> "${RQ_WORK}/jq.err"; then
    echo '{"complete": false, "findings": [], "errors": [], "documented": [], "stopped": []}' > "${REPORT}"
fi
RQ_REPORTS+=("${REPORT}")
COMPLETE=$(jq -r '.complete' "${REPORT}")
if [[ "${RC}" -ne 0 && "${COMPLETE}" == true ]]; then
    COMPLETE=false
fi
COUNT=$(jq '.findings | length' "${REPORT}")

if [[ "${SARIF}" == true && "${COMPLETE}" == true ]]; then
    rq_sarif "${REPORT}" clippy "$(awk '{ print $2; exit }' <<< "${RQ_TOOL_VERSION}")" https://github.com/rust-lang/rust-clippy > "${RQ_BASE}.sarif"
    RQ_REPORTS+=("${RQ_BASE}.sarif")
fi
if [[ "${JUNIT}" == true ]]; then
    rq_findings_junit "${REPORT}" clippy "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml"
    RQ_REPORTS+=("${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

if [[ "${COMPLETE}" != true ]]; then
    OUTCOME=error
elif [[ "${COUNT}" -gt 0 && "${REPORT_ONLY}" == true ]]; then
    OUTCOME=findings-reported
elif [[ "${COUNT}" -gt 0 ]]; then
    OUTCOME=findings
else
    OUTCOME=passed
fi
if [[ "${RUN_RECORD}" == true ]]; then
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -c '{findings: (.findings | length), errors: (.errors | length),
        by_lint: ([.findings[] | .code] | group_by(.) | map({(.[0]): length}) | add // {})}' "${REPORT}")
    rq_run_record "${RQ_BASE}.run-record.json" lint "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ "${COMPLETE}" != true ]]; then
    echo "ERROR: The code did not compile, so clippy could not check all of it, and the step fails whatever report_only says." >&2
    if [[ "$(jq '.errors | length' "${REPORT}")" -gt 0 ]]; then
        rq_print_errors "${REPORT}"
    else
        rq_tail "${RQ_WORK}/err"
    fi
    exit 1
fi
if [[ "${COUNT}" -gt 0 ]]; then
    rq_print_findings "${REPORT}"
    rq_gate true "${REPORT_ONLY}" "clippy found $(rq_plural "${COUNT}" lint lints) in ${RQ_PACKAGES[*]:-the workspace}."
fi
rq_gate false "${REPORT_ONLY}" "clippy found no lints in ${RQ_PACKAGES[*]:-the workspace}."
