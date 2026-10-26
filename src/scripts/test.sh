#!/bin/bash
#
# Runs the tests with cargo-nextest, for the test command, then the
# doctests with cargo test --doc, since nextest doesn't run them. nextest's
# JUnit report is turned on with a tool config file (--tool-config-file),
# which the repository's .config/nextest.toml still overrides. Its exit code
# tells failing tests (100) from code that doesn't build (101) and other
# errors; the JUnit report says which tests failed or were flaky.

set -euo pipefail

if [[ -z "${SCRIPT_RUST_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_RUST_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_RUST_QUALITY_LIB}"

STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
JUNIT=$(rq_bool junit "${PARAM_JUNIT}")
RUN_RECORD=$(rq_bool run_record "${PARAM_RUN_RECORD}")
DOCTESTS=$(rq_bool doctests "${PARAM_DOCTESTS}")
PARTITION=$(rq_bool partition "${PARAM_PARTITION}")
LOCKED=$(rq_bool locked "${PARAM_LOCKED}")
PROFILE=$(rq_subst "${PARAM_PROFILE}")
if ! rq_match "${PROFILE}" '^[A-Za-z0-9][A-Za-z0-9_-]*$'; then
    echo "ERROR: profile must be a nextest profile name, such as default or ci, not '${PROFILE}'." >&2
    exit 1
fi
FILTER=$(rq_subst "${PARAM_FILTER}")
if [[ "${FILTER}" == *$'\n'* ]]; then
    echo "ERROR: filter must be one line." >&2
    exit 1
fi
RETRIES=$(rq_subst "${PARAM_RETRIES}")
if [[ -n "${RETRIES}" ]]; then
    rq_uint retries "${RETRIES}"
fi
case "${PARAM_NO_TESTS}" in
    fail | warn | pass) ;;
    *)
        echo "ERROR: no_tests must be fail, warn or pass, not '${PARAM_NO_TESTS}'." >&2
        exit 1
        ;;
esac
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rq_clear_reports .log .doctests.log .json
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_feature_args "${PARAM_FEATURES}" "${PARAM_ALL_FEATURES}" "${PARAM_NO_DEFAULT_FEATURES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --message-format --tool-config-file --profile -P --partition --no-tests --retries \
    -E --filterset --color --no-fail-fast --fail-fast
rq_tool cargo-nextest
NEXTEST=${RQ_TOOL}
RQ_TOOL_VERSION=$(CARGO=${RQ_CARGO} "${NEXTEST}" nextest --version 2> /dev/null | awk 'NR == 1') || RQ_TOOL_VERSION=""

# The JUnit report goes under the profile's directory in the target
# directory. A name of its own keeps it apart from one the repository's
# config asks for.
JUNIT_NAME=rust-quality-orb-junit.xml
printf '[profile.%s.junit]\npath = "%s"\n' "${PROFILE}" "${JUNIT_NAME}" > "${RQ_WORK}/nextest.toml"
NEXTEST_JUNIT="${RQ_TARGET_DIR}/nextest/${PROFILE}/${JUNIT_NAME}"
rm -f "${NEXTEST_JUNIT}"

RQ_ARGS=(nextest run "${RQ_PACKAGE_ARGS[@]}" ${RQ_FEATURE_ARGS[@]+"${RQ_FEATURE_ARGS[@]}"})
if [[ "${LOCKED}" == true ]]; then
    RQ_ARGS+=(--locked)
fi
RQ_ARGS+=(--profile "${PROFILE}" --no-fail-fast "--no-tests=${PARAM_NO_TESTS}" --color never)
if [[ -n "${RETRIES}" ]]; then
    RQ_ARGS+=(--retries "${RETRIES}")
fi
if [[ -n "${FILTER}" ]]; then
    RQ_ARGS+=(-E "${FILTER}")
fi
NODE=0
if [[ "${PARTITION}" == true ]]; then
    TOTAL=${CIRCLE_NODE_TOTAL:-1}
    NODE=${CIRCLE_NODE_INDEX:-0}
    if ! rq_match "${TOTAL}" '^[1-9][0-9]*$' || ! rq_match "${NODE}" '^[0-9]+$' || ((NODE >= TOTAL)); then
        echo "ERROR: partition needs CircleCI's CIRCLE_NODE_TOTAL and CIRCLE_NODE_INDEX, not '${TOTAL}' and '${NODE}'." >&2
        exit 1
    fi
    if [[ "${TOTAL}" -eq 1 ]]; then
        echo "WARN: partition is true, but the job runs on one node (its parallelism is 1), so it runs every test." >&2
    else
        RQ_ARGS+=(--partition "hash:$((NODE + 1))/${TOTAL}")
        echo "Running the share of node $((NODE + 1)) of ${TOTAL}."
    fi
fi
RQ_ARGS+=(${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"})
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs
if [[ -f "${RQ_WORKSPACE_ROOT}/.config/nextest.toml" ]]; then
    RQ_INPUTS+=("config:${RQ_WORKSPACE_ROOT}/.config/nextest.toml")
fi

echo "Running the tests of ${RQ_PACKAGES[*]:-the workspace} with ${RQ_TOOL_VERSION:-cargo-nextest}..."
RC=0
CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${NEXTEST}" "${RQ_ARGS[@]}" --tool-config-file "rust-quality-orb:${RQ_WORK}/nextest.toml" \
    > "${RQ_BASE}.log" 2>&1 || RC=$?
RQ_REPORTS=("${RQ_BASE}.log")
cat "${RQ_BASE}.log"

# The tests, from nextest's JUnit: one line per test, with its status
# (passed, failed or flaky), class name and name.
: > "${RQ_WORK}/tests.tsv"
if [[ -f "${NEXTEST_JUNIT}" ]]; then
    awk '
        function attr(line, name,    value) {
            if (match(line, " " name "=\"[^\"]*\"")) {
                value = substr(line, RSTART + length(name) + 3, RLENGTH - length(name) - 4)
                return value
            }
            return ""
        }
        function emit() { if (open) printf "%s\t%s\t%s\n", status, classname, name; open = 0 }
        /<testcase / { emit(); name = attr($0, "name"); classname = attr($0, "classname"); status = "passed"; open = 1
            if ($0 ~ /\/>[[:space:]]*$/) emit()
            next }
        open && /<(failure|error)[ >]/ { status = "failed" }
        open && /<flaky(Failure|Error)[ >]/ && status != "failed" { status = "flaky" }
        /<\/testcase>/ { emit() }
    ' "${NEXTEST_JUNIT}" > "${RQ_WORK}/tests.tsv"
fi
TESTS_JSON=$(jq -Rn '[inputs | split("\t") | {status: .[0], classname: .[1], name: .[2]}
    | .classname |= (gsub("&apos;"; "'"'"'") | gsub("&quot;"; "\"") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&"))
    | .name |= (gsub("&apos;"; "'"'"'") | gsub("&quot;"; "\"") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&"))]' \
    < "${RQ_WORK}/tests.tsv")
FAILED=$(jq '[.[] | select(.status == "failed")] | length' <<< "${TESTS_JSON}")

ERROR=""
case "${RC}" in
    0 | 100) ;;
    4) ERROR="no test ran, and no_tests is fail" ;;
    101) ERROR="the tests did not build" ;;
    *) ERROR="cargo-nextest failed (exit code ${RC})" ;;
esac
if [[ "${RC}" -eq 100 && "${FAILED}" -eq 0 ]]; then
    ERROR="cargo-nextest reported failing tests, but its JUnit report (${NEXTEST_JUNIT}) names none"
fi

# The doctests, which nextest doesn't run, only on the first node.
DOC_STATUS=skipped
DOC_RC=0
DOC_TESTS="[]"
DOC_FAILED="[]"
DOC_PASSED=0
LIBS=$(jq -r --arg packages " ${RQ_PACKAGES[*]} " '[.packages[] | select((.name as $name | $packages | contains(" " + $name + " ")) and
    any(.targets[]; any(.kind[]; . == "lib" or . == "rlib" or . == "proc-macro")))] | length' "${RQ_METADATA}")
if [[ "${DOCTESTS}" == true && -z "${ERROR}" && "${NODE}" -eq 0 && "${LIBS}" -gt 0 ]]; then
    DOC_ARGS=(test --doc "${RQ_PACKAGE_ARGS[@]}" ${RQ_FEATURE_ARGS[@]+"${RQ_FEATURE_ARGS[@]}"} --no-fail-fast)
    if [[ "${LOCKED}" == true ]]; then
        DOC_ARGS+=(--locked)
    fi
    echo "Running the doctests..."
    CARGO_TERM_COLOR=never "${RQ_CARGO}" "${DOC_ARGS[@]}" > "${RQ_BASE}.doctests.log" 2>&1 || DOC_RC=$?
    RQ_REPORTS+=("${RQ_BASE}.doctests.log")
    cat "${RQ_BASE}.doctests.log"
    # One line per doctest: test <file> - <item> (line <n>) ... ok
    DOC_TESTS=$(sed -n 's/^test \(.*\) \.\.\. \(ok\|FAILED\|ignored\)$/\2\t\1/p' "${RQ_BASE}.doctests.log" \
        | jq -Rn '[inputs | split("\t") | {status: (if .[0] == "ok" then "passed" elif .[0] == "FAILED" then "failed" else "skipped" end),
            name: .[1]}]')
    DOC_PASSED=$(jq '[.[] | select(.status == "passed")] | length' <<< "${DOC_TESTS}")
    DOC_FAILED=$(jq '[.[] | select(.status == "failed") | .name]' <<< "${DOC_TESTS}")
    if [[ "${DOC_RC}" -eq 0 ]]; then
        DOC_STATUS=passed
    elif grep -q '^test result: FAILED' "${RQ_BASE}.doctests.log" && [[ "$(jq length <<< "${DOC_FAILED}")" -gt 0 ]]; then
        DOC_STATUS=failed
    else
        DOC_STATUS=error
        ERROR="the doctests did not build"
    fi
elif [[ "${DOCTESTS}" == true && "${LIBS}" -eq 0 ]]; then
    echo "No selected package has a library, so there are no doctests."
fi
DOC_FAILED_COUNT=$(jq length <<< "${DOC_FAILED}")

REPORT="${RQ_BASE}.json"
jq -n --argjson tests "${TESTS_JSON}" --argjson rc "${RC}" --arg error "${ERROR}" --arg doc_status "${DOC_STATUS}" \
    --argjson doc_passed "${DOC_PASSED}" --argjson doc_failed "${DOC_FAILED}" '{
        nextest: {exit_code: $rc, tests: ($tests | length),
            passed: [$tests[] | select(.status == "passed")] | length,
            failed: [$tests[] | select(.status == "failed")] | length,
            flaky: [$tests[] | select(.status == "flaky")] | length,
            failures: [$tests[] | select(.status == "failed") | "\(.classname) \(.name)"],
            flaky_tests: [$tests[] | select(.status == "flaky") | "\(.classname) \(.name)"]},
        doctests: {status: $doc_status, passed: $doc_passed, failed: ($doc_failed | length), failures: $doc_failed},
        error: (if $error == "" then null else $error end)}' > "${REPORT}"
RQ_REPORTS+=("${REPORT}")

if [[ "${JUNIT}" == true ]]; then
    JUNIT_DIR="${RQ_OUT}/junit/${PARAM_REPORT_NAME}"
    rm -rf "${JUNIT_DIR}"
    mkdir -p "${JUNIT_DIR}"
    if [[ -f "${NEXTEST_JUNIT}" ]]; then
        cp "${NEXTEST_JUNIT}" "${JUNIT_DIR}/nextest.xml"
        RQ_REPORTS+=("${JUNIT_DIR}/nextest.xml")
    fi
    if [[ "${DOC_STATUS}" == passed || "${DOC_STATUS}" == failed ]]; then
        rq_junit "${JUNIT_DIR}/doctests.xml" doctests "$(jq -c '[.[] | {classname: "doctests", name, status,
            message: (if .status == "failed" then "doctest failed; its output is in the doctests log" else null end)}]' <<< "${DOC_TESTS}")"
        RQ_REPORTS+=("${JUNIT_DIR}/doctests.xml")
    fi
fi

if [[ -n "${ERROR}" ]]; then
    OUTCOME=error
elif [[ "${FAILED}" -gt 0 || "${DOC_FAILED_COUNT}" -gt 0 ]]; then
    OUTCOME=findings
else
    OUTCOME=passed
fi
if [[ "${RUN_RECORD}" == true ]]; then
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -c '{tests: .nextest.tests, passed: .nextest.passed, failed: .nextest.failed, flaky: .nextest.flaky,
        doctests_passed: .doctests.passed, doctests_failed: .doctests.failed}' "${REPORT}")
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_RESULTS=${TESTS_JSON}
    rq_run_record "${RQ_BASE}.run-record.json" test "${OUTCOME}" "$([[ "${OUTCOME}" == passed ]] && echo 0 || echo 1)" "${STARTED}"
fi

if [[ -n "${ERROR}" ]]; then
    echo "ERROR: The tests could not run: ${ERROR}. nextest's output is above, and in ${RQ_BASE}.log." >&2
    exit 1
fi
FLAKY=$(jq '.nextest.flaky' "${REPORT}")
if [[ "${FLAKY}" -gt 0 ]]; then
    echo "WARN: $(rq_plural "${FLAKY}" "test was" "tests were") flaky, passing only on a retry:" >&2
    jq -r '.nextest.flaky_tests[] | "  " + .' "${REPORT}" >&2
fi
if [[ "${OUTCOME}" == findings ]]; then
    echo "ERROR: $(rq_plural "$((FAILED + DOC_FAILED_COUNT))" "test failed" "tests failed"):" >&2
    jq -r '(.nextest.failures + .doctests.failures)[] | "  " + .' "${REPORT}" >&2
    echo "  The reports are in ${RQ_OUT}." >&2
    exit 1
fi
echo "Passed: $(rq_plural "$(jq '.nextest.passed + .nextest.flaky' "${REPORT}")" test tests) and $(rq_plural "${DOC_PASSED}" doctest doctests) passed."
