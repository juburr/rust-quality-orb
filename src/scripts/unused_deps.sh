#!/bin/bash
#
# Finds unused and misplaced dependencies, and source files no module
# includes, with cargo-shear, for the unused_deps command. cargo-shear
# reports errors (an unused dependency, one in the wrong section) and
# warnings (an empty file, an unused optional dependency); errors are
# findings, and warnings too with deny_warnings. Its JSON report tells a
# complete run apart from a failed one: a run that couldn't finish (exit code
# 2) writes an error line instead, which fails the step whatever report_only
# says. Exit code 1 means findings, so it must agree with the report.

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
DENY_WARNINGS=$(rq_bool deny_warnings "${PARAM_DENY_WARNINGS}")
LOCKED=$(rq_bool locked "${PARAM_LOCKED}")
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rq_clear_reports .log .json
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --format --fix --deny-warnings
# cargo shear takes the directory to check as its one positional argument,
# which would check another workspace than the one the report's paths and
# the run record name.
expect_value=false
for word in ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"}; do
    if [[ "${expect_value}" == true ]]; then
        expect_value=false
    elif [[ "${word}" == -p || "${word}" == --package || "${word}" == --exclude || "${word}" == --color ]]; then
        expect_value=true
    elif [[ "${word}" != -* ]]; then
        echo "ERROR: extra_args can't name a directory ('${word}'): cargo shear checks the workspace in working_dir." >&2
        exit 1
    fi
done
rq_tool cargo-shear
SHEAR=${RQ_TOOL}
RQ_TOOL_VERSION=$(CARGO=${RQ_CARGO} "${SHEAR}" shear --version 2> /dev/null | awk 'NR == 1') || RQ_TOOL_VERSION=""

# cargo shear selects packages with -p, and checks the whole workspace
# without it (it has no --workspace).
RQ_ARGS=(shear)
if [[ "${RQ_PACKAGE_ARGS[0]}" != --workspace ]]; then
    RQ_ARGS+=("${RQ_PACKAGE_ARGS[@]}")
fi
if [[ "${DENY_WARNINGS}" == true ]]; then
    RQ_ARGS+=(--deny-warnings)
fi
if [[ "${LOCKED}" == true ]]; then
    RQ_ARGS+=(--locked)
fi
RQ_ARGS+=(--format json --color never ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"})
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs

echo "Looking for unused dependencies in ${RQ_PACKAGES[*]:-the workspace} with ${RQ_TOOL_VERSION:-cargo-shear}..."
RC=0
CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${SHEAR}" "${RQ_ARGS[@]}" > "${RQ_WORK}/out.json" 2> "${RQ_BASE}.log" || RC=$?
RQ_REPORTS=("${RQ_BASE}.log")
REPORT="${RQ_BASE}.json"
ERROR=""
if [[ "${RC}" -ne 0 && "${RC}" -ne 1 ]]; then
    ERROR="cargo-shear could not check the workspace (exit code ${RC})"
elif ! rq_json_is "${RQ_WORK}/out.json" 'length == 1 and (.[0] | type == "object" and (.summary | type == "object")
        and (.findings | type == "array"))' -s; then
    ERROR="cargo-shear did not write a report (exit code ${RC})"
fi
if [[ -n "${ERROR}" ]]; then
    # Its error is on stdout, in place of the report.
    cat "${RQ_WORK}/out.json" >> "${RQ_BASE}.log"
    echo '{"summary": null, "findings": []}' > "${REPORT}"
else
    # Each finding's line and column, from the byte offset cargo-shear gives,
    # in the file it names relative to the workspace root.
    positions="[]"
    while IFS=$'\t' read -r index file offset; do
        position=$(LC_ALL=C awk -v offset="${offset}" '
            { if (pos + length($0) + 1 > offset) { print NR "\t" offset - pos + 1; found = 1; exit } pos += length($0) + 1 }
            END { if (!found) print NR + 1 "\t" offset - pos + 1 }' "${RQ_WORKSPACE_ROOT}/${file}" 2> /dev/null) || position=""
        if [[ -n "${position}" ]]; then
            positions=$(jq -c --argjson index "${index}" --argjson line "${position%%$'\t'*}" --argjson column "${position#*$'\t'}" \
                '. + [{index: $index, line: $line, column: $column}]' <<< "${positions}")
        fi
    done < <(jq -r '.findings | to_entries[] | select(.value.file != null and (.value.location.offset | type == "number"))
        | "\(.key)\t\(.value.file)\t\(.value.location.offset)"' "${RQ_WORK}/out.json")
    jq --argjson positions "${positions}" --argjson deny "${DENY_WARNINGS}" '
        .findings |= (to_entries | map(.key as $i | .value
            + ([$positions[] | select(.index == $i) | {line, column}] | first // {line: null, column: null})
            + {counted: (.value.severity == "error" or $deny)}))' "${RQ_WORK}/out.json" > "${REPORT}"
    COUNTED=$(jq '[.findings[] | select(.counted)] | length' "${REPORT}")
    # cargo-shear exits 1 exactly when it finds what this step counts.
    if [[ "${RC}" -eq 1 && "${COUNTED}" -eq 0 ]] || [[ "${RC}" -eq 0 && "${COUNTED}" -gt 0 ]]; then
        ERROR="cargo-shear's exit code (${RC}) doesn't match its report ($(rq_plural "${COUNTED}" finding findings))"
    fi
fi
RQ_REPORTS+=("${REPORT}")
COUNT=$(jq '[.findings[] | select(.counted)] | length' "${REPORT}")
if [[ "${JUNIT}" == true ]]; then
    rq_junit "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" cargo-shear "$(jq -c '[.findings[] | select(.counted)
        | {classname: (.file // "workspace"), name: "\(.code)\(if .line == null then "" else " at \(.line):\(.column)" end)",
           status: "failed", message: .message, detail: .help}]' "${REPORT}")"
    RQ_REPORTS+=("${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

if [[ -n "${ERROR}" ]]; then
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
    RQ_TOOL=${SHEAR}
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -c '{findings: ([.findings[] | select(.counted)] | length),
        errors: ([.findings[] | select(.severity == "error")] | length),
        warnings: ([.findings[] | select(.severity != "error")] | length),
        by_code: ([.findings[] | select(.counted) | .code] | group_by(.) | map({(.[0]): length}) | add // {})}' "${REPORT}")
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_RESULTS=$(jq -c '.findings' "${REPORT}")
    rq_run_record "${RQ_BASE}.run-record.json" unused_deps "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ -n "${ERROR}" ]]; then
    echo "ERROR: ${ERROR}, so the step fails whatever report_only says. Its output:" >&2
    rq_tail "${RQ_BASE}.log"
    exit 1
fi
print_findings() {
    jq -r --argjson counted "$1" '.findings[] | select(.counted == $counted)
        | "  \(.file // "workspace")\(if .line == null then "" else ":\(.line):\(.column)" end): \(.severity)[\(.code)]: \(.message)"
            + (if .help == null then "" else "\n    help: \(.help | gsub("\n"; "\n    "))" end)' "${REPORT}"
}
UNCOUNTED=$(jq '[.findings[] | select(.counted | not)] | length' "${REPORT}")
if [[ "${UNCOUNTED}" -gt 0 ]]; then
    echo "cargo-shear also warns about this, which counts only with deny_warnings:"
    print_findings false
fi
if [[ "${COUNT}" -gt 0 ]]; then
    print_findings true
    echo "Mark a false positive, such as a crate only a macro uses, in Cargo.toml's [package.metadata.cargo-shear] ignored."
    rq_gate true "${REPORT_ONLY}" "cargo-shear found $(rq_plural "${COUNT}" problem problems) in the dependencies of ${RQ_PACKAGES[*]:-the workspace}."
fi
rq_gate false "${REPORT_ONLY}" "cargo-shear found no unused or misplaced dependencies in ${RQ_PACKAGES[*]:-the workspace}."
