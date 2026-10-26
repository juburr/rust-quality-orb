#!/bin/bash
#
# Checks that each package builds with every feature on its own, or every
# combination of them, with cargo-hack, for the features command: one run
# per target (the machine's own, and each in targets), with --keep-going so
# one combination that fails doesn't hide the rest. cargo-hack exits 1 both
# when a combination fails and when it can't start, so its output tells them
# apart: each combination starts with an "info: running" line, one that
# fails prints an error before the next, and a run in which combinations
# failed ends with "failed to run N commands". A run that fails without that
# summary is cargo-hack failing, which fails the step whatever report_only
# says, and so is a combination that failed for a reason other than the
# code (a target whose standard library isn't installed, a download, a
# stale Cargo.lock with locked): only rustc, a build script or a test
# failing makes a combination a finding.

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
NO_DEV_DEPS=$(rq_bool no_dev_deps "${PARAM_NO_DEV_DEPS}")
LOCKED=$(rq_bool locked "${PARAM_LOCKED}")
case "${PARAM_MODE}" in
    each_feature) MODE=(--each-feature) ;;
    feature_powerset) MODE=(--feature-powerset) ;;
    *)
        echo "ERROR: mode must be each_feature or feature_powerset, not '${PARAM_MODE}'." >&2
        exit 1
        ;;
esac
DEPTH=$(rq_subst "${PARAM_DEPTH}")
if [[ -n "${DEPTH}" && "${PARAM_MODE}" == feature_powerset ]]; then
    rq_uint depth "${DEPTH}" 1
    MODE+=(--depth "${DEPTH}")
fi
case "${PARAM_SUBCOMMAND}" in
    check | clippy | build | test) ;;
    *)
        echo "ERROR: subcommand must be check, clippy, build or test, not '${PARAM_SUBCOMMAND}'." >&2
        exit 1
        ;;
esac
if [[ "${NO_DEV_DEPS}" == true && "${PARAM_SUBCOMMAND}" != check && "${PARAM_SUBCOMMAND}" != build ]]; then
    echo "ERROR: no_dev_deps works only with subcommand check or build: ${PARAM_SUBCOMMAND} needs the dev-dependencies." >&2
    echo "  Set no_dev_deps to false." >&2
    exit 1
fi
rq_list skip_features "${PARAM_SKIP_FEATURES}"
SKIP=""
for feature in ${RQ_LIST[@]+"${RQ_LIST[@]}"}; do
    if ! rq_match "${feature}" '^[A-Za-z0-9_][A-Za-z0-9_+.-]*$'; then
        echo "ERROR: skip_features must list feature names, not '${feature}'." >&2
        exit 1
    fi
    SKIP+="${SKIP:+,}${feature}"
done
rq_list targets "${PARAM_TARGETS}"
TARGETS=("")
for target in ${RQ_LIST[@]+"${RQ_LIST[@]}"}; do
    if ! rq_match "${target}" '^[A-Za-z0-9_][A-Za-z0-9_.-]*$'; then
        echo "ERROR: targets must list Rust targets such as wasm32-unknown-unknown, not '${target}'." >&2
        exit 1
    fi
    TARGETS+=("${target}")
done
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
# The per-target logs an earlier run listed, since this run's targets can
# differ.
if [[ -f "${RQ_BASE}.json" ]]; then
    while IFS= read -r log; do
        if [[ "${log}" == "${RQ_BASE}-"*.log && "${log}" != */../* ]]; then
            rm -f -- "${log}"
        fi
    done < <(jq -r '.logs[]? // empty' "${RQ_BASE}.json" 2> /dev/null || true)
fi
rq_clear_reports .log .json
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --keep-going --print-command-list --log-group --color --each-feature --feature-powerset
rq_tool cargo-hack
HACK=${RQ_TOOL}
RQ_TOOL_VERSION=$(CARGO=${RQ_CARGO} "${HACK}" hack --version 2> /dev/null | awk 'NR == 1') || RQ_TOOL_VERSION=""
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs

COMBINATIONS="[]"
ERROR=""
RQ_REPORTS=()
for target in "${TARGETS[@]}"; do
    args=(hack "${PARAM_SUBCOMMAND}" "${RQ_PACKAGE_ARGS[@]}" "${MODE[@]}")
    if [[ "${NO_DEV_DEPS}" == true ]]; then
        args+=(--no-dev-deps)
    fi
    if [[ -n "${SKIP}" ]]; then
        args+=(--skip "${SKIP}")
    fi
    if [[ -n "${target}" ]]; then
        args+=(--target "${target}")
    fi
    if [[ "${LOCKED}" == true ]]; then
        args+=(--locked)
    fi
    args+=(--keep-going --log-group none --color never ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"})
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_ARGS=("${args[@]}")
    log="${RQ_BASE}${target:+-${target}}.log"
    RQ_REPORTS+=("${log}")
    echo "Checking the feature combinations of ${RQ_PACKAGES[*]:-the workspace}${target:+ for ${target}} with ${RQ_TOOL_VERSION:-cargo-hack}..."
    RC=0
    CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${HACK}" "${args[@]}" > "${log}" 2>&1 || RC=$?
    # Each combination, from its "info: running `...` on <package> (i/n)"
    # line: passed without an error line before the next one; failed when
    # rustc, a build script or a test failed (cargo's "could not compile",
    # "failed to run custom build command" or "test failed"), unless the
    # target isn't installed; error for any other failure, with its first
    # error line.
    found=$(awk -v target="${target}" '
        function emit() {
            if (command == "") return
            status = "passed"
            if (bad) status = (code && !env) ? "failed" : "error"
            printf "%s\t%s\t%s\t%s\t%s\n", target, package, command, status, first
            command = ""
        }
        /^info: running `/ {
            emit()
            line = $0
            sub(/^info: running `/, "", line)
            command = line; sub(/`.*$/, "", command)
            package = line
            if (sub(/^[^`]*` on /, "", package)) sub(/ \([0-9]+\/[0-9]+\)$/, "", package)
            else package = ""
            bad = 0; code = 0; env = 0; first = ""
            next
        }
        /^failed to run [0-9]+ commands/ || /^error: failed to run [0-9]+ commands/ { emit(); summary = 1 }
        summary || command == "" { next }
        /^error/ { bad = 1; if (first == "") { first = $0; gsub(/\t/, " ", first) } }
        /^error: could not compile `/ || /failed to run custom build command for/ || /^error: test failed/ { code = 1 }
        /target may not be installed/ { env = 1 }
        END { emit() }
    ' "${log}" | jq -Rn '[inputs | split("\t") | {target: (if .[0] == "" then null else .[0] end), package: .[1], command: .[2],
        status: .[3], error: (if .[3] == "error" then .[4] else null end)}]')
    COMBINATIONS=$(jq -c --argjson found "${found}" '. + $found' <<< "${COMBINATIONS}")
    failed=$(jq '[.[] | select(.status == "failed")] | length' <<< "${found}")
    if [[ "${RC}" -ne 0 ]] && ! grep -qE '^(error: )?failed to run [0-9]+ commands' "${log}"; then
        ERROR="cargo-hack failed${target:+ for ${target}} before it could run every combination (exit code ${RC})"
        break
    fi
    unchecked=$(jq -r 'map(select(.status == "error")) | first // empty | "\(.command) (\(.error))"' <<< "${found}")
    if [[ -n "${unchecked}" ]]; then
        ERROR="cargo-hack could not check ${unchecked}${target:+ for ${target}}, for a reason other than the code"
        break
    fi
    if [[ "${RC}" -ne 0 && "${failed}" -eq 0 ]]; then
        ERROR="cargo-hack reports failed combinations${target:+ for ${target}}, but its output names none"
        break
    fi
    echo "  $(rq_plural "$(jq length <<< "${found}")" combination combinations), ${failed} failed."
done

REPORT="${RQ_BASE}.json"
jq -n --argjson combinations "${COMBINATIONS}" --arg error "${ERROR}" --args '{combinations: $combinations,
    error: (if $error == "" then null else $error end), logs: $ARGS.positional}' ${RQ_REPORTS[@]+"${RQ_REPORTS[@]}"} > "${REPORT}"
RQ_REPORTS+=("${REPORT}")
FAILED=$(jq '[.combinations[] | select(.status == "failed")] | length' "${REPORT}")
if [[ "${JUNIT}" == true ]]; then
    rq_junit "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" features "$(jq -c '[.combinations[] | {classname: (.package
        + (if .target == null then "" else " (" + .target + ")" end)), name: .command,
        status: (if .status == "passed" then "passed" else "failed" end),
        message: (if .status == "failed" then "does not build with these features"
            elif .status == "error" then "could not be checked: \(.error)" else null end)}]' "${REPORT}")"
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
    RQ_TOOL=${HACK}
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -c '{combinations: (.combinations | length), failed: ([.combinations[] | select(.status == "failed")] | length)}' "${REPORT}")
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_RESULTS=$(jq -c '.combinations' "${REPORT}")
    rq_run_record "${RQ_BASE}.run-record.json" features "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ -n "${ERROR}" ]]; then
    echo "ERROR: ${ERROR}, so the step fails whatever report_only says. Its output:" >&2
    rq_tail "${log}"
    exit 1
fi
if [[ "${FAILED}" -gt 0 ]]; then
    jq -r '.combinations[] | select(.status == "failed") | "  \(.package)\(if .target == null then "" else " (\(.target))" end): \(.command)"' "${REPORT}"
    echo "Each combination's output is in the log beside the report."
    rq_gate true "${REPORT_ONLY}" "$(rq_plural "${FAILED}" "feature combination doesn't" "feature combinations don't") build."
fi
rq_gate false "${REPORT_ONLY}" "every feature combination of ${RQ_PACKAGES[*]:-the workspace} builds ($(jq '.combinations | length' "${REPORT}") in all)."
