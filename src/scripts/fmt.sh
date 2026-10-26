#!/bin/bash
#
# Checks formatting with rustfmt (cargo fmt --check), for the fmt command,
# and reports the files it would change. cargo fmt exits 1 both for files it
# would change and for files it can't parse, so the output tells them apart:
# --message-format short lists the files it would change on stdout, and a
# file it can't parse is an error on stderr, which fails the step whatever
# report_only says. rustfmt reads rustfmt.toml and each package's edition.

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
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rq_clear_reports .json .diff
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --check --message-format --emit -l --files-with-diff
if ! RQ_TOOL_VERSION=$("${RQ_CARGO}" fmt --version 2> "${RQ_WORK}/version.err"); then
    echo "ERROR: cargo fmt is not available: install the rustfmt component, with install_rust or install_rustup" >&2
    echo "  (components: rustfmt), or rustup component add rustfmt. Its output:" >&2
    rq_tail "${RQ_WORK}/version.err"
    exit 1
fi
# shellcheck disable=SC2034 # read by rq_run_record
RQ_TOOL=${RQ_CARGO}

# Without packages, --all checks every member and the path dependencies they
# share; packages narrows it to those.
SELECT=(--all)
if [[ "${RQ_PACKAGE_ARGS[0]}" != --workspace ]]; then
    SELECT=("${RQ_PACKAGE_ARGS[@]}")
fi
RQ_ARGS=(fmt "${SELECT[@]}" --check --message-format short)
if [[ ${#RQ_EXTRA_ARGS[@]} -gt 0 ]]; then
    RQ_ARGS+=(-- "${RQ_EXTRA_ARGS[@]}")
fi
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs
for config in rustfmt.toml .rustfmt.toml; do
    if [[ -f "${RQ_WORKSPACE_ROOT}/${config}" ]]; then
        RQ_INPUTS+=("config:${RQ_WORKSPACE_ROOT}/${config}")
    fi
done

echo "Checking the formatting of ${RQ_PACKAGES[*]:-the workspace} with ${RQ_TOOL_VERSION}..."
RC=0
CARGO_TERM_COLOR=never "${RQ_CARGO}" "${RQ_ARGS[@]}" > "${RQ_WORK}/files" 2> "${RQ_WORK}/err" || RC=$?
# Paths come absolute; the report has them relative to the workspace root.
# A file whose only problem is its line endings comes as "Incorrect newline
# style in <path>".
awk -v root="${RQ_WORKSPACE_ROOT%/}/" 'NF { sub(/^Incorrect newline style in /, ""); if (index($0, root) == 1) print substr($0, length(root) + 1); else print }' \
    "${RQ_WORK}/files" | sort -u > "${RQ_WORK}/relative"
mapfile -t FILES < "${RQ_WORK}/relative"
ERROR=false
if [[ "${RC}" -ne 0 ]] && { [[ "${#FILES[@]}" -eq 0 ]] || grep -qiE '^(error|Error writing files)' "${RQ_WORK}/err"; }; then
    ERROR=true
fi

REPORT="${RQ_BASE}.json"
jq -Rn '[inputs | select(length > 0)] | {unformatted: .}' "${RQ_WORK}/relative" > "${REPORT}"
RQ_REPORTS=("${REPORT}")
if [[ "${#FILES[@]}" -gt 0 ]]; then
    # The changes rustfmt would make, as a diff.
    CARGO_TERM_COLOR=never "${RQ_CARGO}" fmt "${SELECT[@]}" --check -- --color never ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"} \
        > "${RQ_BASE}.diff" 2> /dev/null || true
    RQ_REPORTS+=("${RQ_BASE}.diff")
fi
if [[ "${JUNIT}" == true ]]; then
    rq_junit "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" rustfmt \
        "$(jq -c '[.unformatted[] | {classname: "rustfmt", name: ., status: "failed", message: "not formatted as rustfmt would format it"}]' "${REPORT}")"
    RQ_REPORTS+=("${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

if [[ "${ERROR}" == true ]]; then
    OUTCOME=error
elif [[ "${#FILES[@]}" -gt 0 && "${REPORT_ONLY}" == true ]]; then
    OUTCOME=findings-reported
elif [[ "${#FILES[@]}" -gt 0 ]]; then
    OUTCOME=findings
else
    OUTCOME=passed
fi
if [[ "${RUN_RECORD}" == true ]]; then
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -c '{unformatted_files: (.unformatted | length)}' "${REPORT}")
    rq_run_record "${RQ_BASE}.run-record.json" fmt "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ "${ERROR}" == true ]]; then
    echo "ERROR: rustfmt could not check every file, so the step fails whatever report_only says. Its output:" >&2
    rq_tail "${RQ_WORK}/err"
    exit 1
fi
if [[ "${#FILES[@]}" -gt 0 ]]; then
    printf '  %s\n' "${FILES[@]}"
    echo "The changes rustfmt would make are in ${RQ_BASE}.diff. Run cargo fmt to make them."
    rq_gate true "${REPORT_ONLY}" "rustfmt would change $(rq_plural "${#FILES[@]}" file files)."
fi
rq_gate false "${REPORT_ONLY}" "every file is formatted as rustfmt would format it."
