#!/bin/bash
#
# Builds the documentation (cargo doc --no-deps), for the docs command, and
# reports every warning rustdoc and rustc give: broken intra-doc links, bare
# URLs, invalid code blocks and HTML, and missing_docs where a crate asks
# for it. A lint the code denies stops rustdoc at that crate and still counts
# as findings; anything else that stops the build (code that doesn't
# compile) fails the step whatever report_only says. The command adds no
# rustdoc flags of its own, so RUSTDOCFLAGS and build.rustdocflags apply as
# set.

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
PRIVATE=$(rq_bool document_private_items "${PARAM_DOCUMENT_PRIVATE_ITEMS}")
LOCKED=$(rq_bool locked "${PARAM_LOCKED}")
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rq_clear_reports .raw.jsonl .json
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_feature_args "${PARAM_FEATURES}" "${PARAM_ALL_FEATURES}" "${PARAM_NO_DEFAULT_FEATURES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --message-format --open
# shellcheck disable=SC2034 # read by rq_run_record
RQ_TOOL=${RQ_CARGO}
RQ_TOOL_VERSION=$("${RQ_CARGO}" --version 2> /dev/null) || RQ_TOOL_VERSION=""

RQ_ARGS=(doc --no-deps "${RQ_PACKAGE_ARGS[@]}" ${RQ_FEATURE_ARGS[@]+"${RQ_FEATURE_ARGS[@]}"})
if [[ "${PRIVATE}" == true ]]; then
    RQ_ARGS+=(--document-private-items)
fi
if [[ "${LOCKED}" == true ]]; then
    RQ_ARGS+=(--locked)
fi
RQ_ARGS+=(--message-format=json ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"})
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs

echo "Building the documentation of ${RQ_PACKAGES[*]:-the workspace} with ${RQ_TOOL_VERSION}..."
RC=0
CARGO_TERM_COLOR=never "${RQ_CARGO}" "${RQ_ARGS[@]}" > "${RQ_BASE}.raw.jsonl" 2> "${RQ_WORK}/err" || RC=$?
RQ_REPORTS=("${RQ_BASE}.raw.jsonl")
REPORT="${RQ_BASE}.json"
if ! jq -s "${RQ_DIAGNOSTICS_JQ}" "${RQ_BASE}.raw.jsonl" > "${REPORT}" 2> "${RQ_WORK}/jq.err"; then
    echo '{"complete": false, "findings": [], "errors": []}' > "${REPORT}"
fi
RQ_REPORTS+=("${REPORT}")
COMPLETE=$(jq -r '.complete' "${REPORT}")
# A failed run is complete only when denied lints stopped it.
if [[ "${RC}" -ne 0 && "$(jq '[.findings[] | select(.level == "error")] | length' "${REPORT}")" -eq 0 ]]; then
    COMPLETE=false
fi
COUNT=$(jq '.findings | length' "${REPORT}")
if [[ "${JUNIT}" == true ]]; then
    rq_findings_junit "${REPORT}" rustdoc "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml"
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
    rq_run_record "${RQ_BASE}.run-record.json" docs "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ "${COMPLETE}" != true ]]; then
    echo "ERROR: The documentation could not be built, so the step fails whatever report_only says." >&2
    if [[ "$(jq '.errors | length' "${REPORT}")" -gt 0 ]]; then
        rq_print_errors "${REPORT}"
    else
        rq_tail "${RQ_WORK}/err"
    fi
    exit 1
fi
if [[ "${COUNT}" -gt 0 ]]; then
    rq_print_findings "${REPORT}"
    if [[ "${RC}" -ne 0 ]]; then
        echo "A denied lint stopped rustdoc, so crates after it in the build may have more."
    fi
    rq_gate true "${REPORT_ONLY}" "rustdoc found $(rq_plural "${COUNT}" problem problems) in the documentation of ${RQ_PACKAGES[*]:-the workspace}."
fi
rq_gate false "${REPORT_ONLY}" "the documentation of ${RQ_PACKAGES[*]:-the workspace} builds without warnings."
