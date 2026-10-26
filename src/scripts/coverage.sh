#!/bin/bash
#
# Measures line coverage with cargo-llvm-cov, for the coverage command: the
# tests run once on an instrumented build (cargo llvm-cov --no-report, with
# cargo test or, with nextest, cargo-nextest), then each report is written
# from that run (cargo llvm-cov report). A test run that fails, or doesn't
# build, leaves no coverage to measure, so it fails the step whatever
# report_only says; the test command reports which tests failed. Coverage
# below coverage_min is a finding.

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
USE_NEXTEST=$(rq_bool nextest "${PARAM_NEXTEST}")
LOCKED=$(rq_bool locked "${PARAM_LOCKED}")
rq_list formats "${PARAM_FORMATS}"
FORMATS=(${RQ_LIST[@]+"${RQ_LIST[@]}"})
for format in ${FORMATS[@]+"${FORMATS[@]}"}; do
    case "${format}" in
        lcov | cobertura | html) ;;
        *)
            echo "ERROR: formats can name lcov, cobertura and html, not '${format}'." >&2
            exit 1
            ;;
    esac
done
MINIMUM=$(rq_subst "${PARAM_COVERAGE_MIN}")
if [[ -n "${MINIMUM}" ]] && { ! rq_match "${MINIMUM}" '^[0-9]{1,3}(\.[0-9]+)?$' || awk -v m="${MINIMUM}" 'BEGIN { exit !(m > 100) }'; }; then
    echo "ERROR: coverage_min must be a percentage from 0 to 100, such as 80 or 82.5, not '${MINIMUM}'." >&2
    exit 1
fi
IGNORE=$(rq_subst "${PARAM_IGNORE_FILENAME_REGEX}")
if [[ "${IGNORE}" == *$'\n'* ]]; then
    echo "ERROR: ignore_filename_regex must be one line." >&2
    exit 1
fi
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rq_clear_reports .log .json .lcov .cobertura.xml -html
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_feature_args "${PARAM_FEATURES}" "${PARAM_ALL_FEATURES}" "${PARAM_NO_DEFAULT_FEATURES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --json --lcov --cobertura --codecov --html --text --open --output-path --output-dir \
    --no-report --summary-only --fail-under-lines --fail-under-functions --fail-under-regions --fail-under-file-lines \
    --fail-uncovered-lines --fail-uncovered-regions --fail-uncovered-functions --ignore-filename-regex
rq_tool cargo-llvm-cov
LLVM_COV=${RQ_TOOL}
RQ_TOOL_VERSION=$(CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${LLVM_COV}" llvm-cov --version 2> /dev/null | awk 'NR == 1') || RQ_TOOL_VERSION=""
if [[ "${USE_NEXTEST}" == true ]]; then
    rq_tool cargo-nextest
fi
# shellcheck disable=SC2034 # read by rq_run_record
RQ_TOOL=${LLVM_COV}

# llvm cov runs the tests; report writes each report from what they left.
RQ_ARGS=(llvm-cov)
if [[ "${USE_NEXTEST}" == true ]]; then
    RQ_ARGS+=(nextest)
fi
RQ_ARGS+=(--no-report "${RQ_PACKAGE_ARGS[@]}" ${RQ_FEATURE_ARGS[@]+"${RQ_FEATURE_ARGS[@]}"})
if [[ "${LOCKED}" == true ]]; then
    RQ_ARGS+=(--locked)
fi
RQ_ARGS+=(${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"})
REPORT_ARGS=(llvm-cov report)
if [[ -n "${IGNORE}" ]]; then
    REPORT_ARGS+=(--ignore-filename-regex "${IGNORE}")
fi
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs

echo "Measuring the coverage of ${RQ_PACKAGES[*]:-the workspace} with ${RQ_TOOL_VERSION:-cargo-llvm-cov}..."
RC=0
# Profiles left by an earlier run would count toward this one.
CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${LLVM_COV}" llvm-cov clean --workspace > "${RQ_WORK}/clean.log" 2>&1 || RC=$?
if [[ "${RC}" -eq 0 ]]; then
    CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${LLVM_COV}" "${RQ_ARGS[@]}" > "${RQ_BASE}.log" 2>&1 || RC=$?
    cat "${RQ_BASE}.log"
else
    cp "${RQ_WORK}/clean.log" "${RQ_BASE}.log"
fi
RQ_REPORTS=("${RQ_BASE}.log")
ERROR=""
if [[ "${RC}" -ne 0 ]]; then
    ERROR="the tests failed or did not build, so their coverage can't be measured"
    if grep -qiE 'llvm-tools|llvm-profdata|llvm-cov[^-]* (was )?not found' "${RQ_BASE}.log"; then
        ERROR="cargo-llvm-cov can't find the toolchain's llvm-tools component. Install it with install_rust or install_rustup (components: llvm-tools), or rustup component add llvm-tools"
    fi
fi

REPORT="${RQ_BASE}.json"
if [[ -z "${ERROR}" ]]; then
    if ! CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${LLVM_COV}" "${REPORT_ARGS[@]}" --json --summary-only --output-path "${REPORT}" > "${RQ_WORK}/report.log" 2>&1 \
        || ! rq_json_is "${REPORT}" '.data[0].totals.lines.count | type == "number"'; then
        cat "${RQ_WORK}/report.log" >> "${RQ_BASE}.log"
        ERROR="cargo-llvm-cov could not write the coverage report"
    else
        RQ_REPORTS+=("${REPORT}")
        for format in ${FORMATS[@]+"${FORMATS[@]}"}; do
            case "${format}" in
                lcov) out=(--lcov --output-path "${RQ_BASE}.lcov"); file="${RQ_BASE}.lcov" ;;
                cobertura) out=(--cobertura --output-path "${RQ_BASE}.cobertura.xml"); file="${RQ_BASE}.cobertura.xml" ;;
                html) out=(--html --output-dir "${RQ_BASE}-html"); file="${RQ_BASE}-html/html/index.html" ;;
            esac
            if ! CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${LLVM_COV}" "${REPORT_ARGS[@]}" "${out[@]}" > "${RQ_WORK}/report.log" 2>&1; then
                cat "${RQ_WORK}/report.log" >> "${RQ_BASE}.log"
                ERROR="cargo-llvm-cov could not write the ${format} report"
                break
            fi
            if [[ -f "${file}" ]]; then
                RQ_REPORTS+=("${file}")
            fi
        done
    fi
fi

COUNT=0
COVERED=0
PERCENT=""
BELOW=false
if [[ -z "${ERROR}" ]]; then
    COUNT=$(jq '.data[0].totals.lines.count' "${REPORT}")
    COVERED=$(jq '.data[0].totals.lines.covered' "${REPORT}")
    # Compared exactly: covered / count < minimum / 100, without rounding.
    PERCENT=$(awk -v c="${COVERED}" -v n="${COUNT}" 'BEGIN { if (n == 0) print "100.00"; else printf "%.2f\n", 100 * c / n }')
    if [[ -n "${MINIMUM}" ]] && awk -v c="${COVERED}" -v n="${COUNT}" -v m="${MINIMUM}" 'BEGIN { exit !(100 * c < m * n) }'; then
        BELOW=true
    fi
fi
if [[ "${JUNIT}" == true && -z "${ERROR}" ]]; then
    rq_junit "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" coverage "$(jq -cn --arg percent "${PERCENT}" --arg min "${MINIMUM}" \
        --argjson below "${BELOW}" --argjson covered "${COVERED}" --argjson count "${COUNT}" '[{classname: "coverage",
        name: (if $min == "" then "line coverage" else "line coverage of at least \($min)%" end),
        status: (if $below then "failed" else "passed" end),
        message: (if $below then "\($percent)% of lines covered (\($covered) of \($count)), below \($min)%" else null end)}]')"
    RQ_REPORTS+=("${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml")
fi

if [[ -n "${ERROR}" ]]; then
    OUTCOME=error
elif [[ "${BELOW}" == true && "${REPORT_ONLY}" == true ]]; then
    OUTCOME=findings-reported
elif [[ "${BELOW}" == true ]]; then
    OUTCOME=findings
else
    OUTCOME=passed
fi
if [[ "${RUN_RECORD}" == true ]]; then
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -cn --argjson count "${COUNT}" --argjson covered "${COVERED}" --arg percent "${PERCENT}" --arg min "${MINIMUM}" \
        '{lines: $count, lines_covered: $covered, percent: (if $percent == "" then null else ($percent | tonumber) end),
          coverage_min: (if $min == "" then null else ($min | tonumber) end)}')
    rq_run_record "${RQ_BASE}.run-record.json" coverage "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ -n "${ERROR}" ]]; then
    echo "ERROR: ${ERROR}, so the step fails whatever report_only says." >&2
    if [[ "${ERROR}" != *llvm-tools* ]]; then
        echo "  cargo-llvm-cov's output is above, and in ${RQ_BASE}.log." >&2
    fi
    exit 1
fi
SUMMARY="${PERCENT}% of lines are covered ($(rq_plural "${COVERED}" line lines) of ${COUNT})"
if [[ "${BELOW}" == true ]]; then
    rq_gate true "${REPORT_ONLY}" "${SUMMARY}, below coverage_min (${MINIMUM}%)."
fi
rq_gate false "${REPORT_ONLY}" "${SUMMARY}${MINIMUM:+, at least coverage_min (${MINIMUM}%)}."
