#!/bin/bash
#
# Checks each library package's public API against a baseline with
# cargo-semver-checks (cargo semver-checks check-release), for the
# semver_checks command. Each failed lint, a "--- failure <lint>: ... ---"
# section in its output, is a finding: a change the version number doesn't
# allow. Lints set to warn print "--- warning" sections, which are reported
# but don't count. Since 0.49.0 it exits 100 for failed lints and 101 when it
# can't complete; before, 1 for both, and an "error:" line tells them apart.
# A run that can't complete, or checks no package at all, fails the step
# whatever report_only says.

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
BASELINE_REV=$(rq_subst "${PARAM_BASELINE_REV}")
BASELINE_VERSION=$(rq_subst "${PARAM_BASELINE_VERSION}")
BASELINE_ROOT=$(rq_subst "${PARAM_BASELINE_ROOT}")
RELEASE_TYPE=$(rq_subst "${PARAM_RELEASE_TYPE}")
BASELINE=()
for name in baseline_rev baseline_version baseline_root; do
    case "${name}" in
        baseline_rev) value=${BASELINE_REV} ;;
        baseline_version) value=${BASELINE_VERSION} ;;
        baseline_root) value=${BASELINE_ROOT} ;;
    esac
    if [[ -z "${value}" ]]; then
        continue
    fi
    if [[ "${#BASELINE[@]}" -gt 0 ]]; then
        echo "ERROR: Set at most one of baseline_rev, baseline_version and baseline_root: each names the whole baseline." >&2
        exit 1
    fi
    if [[ "${value}" == -* ]]; then
        echo "ERROR: ${name} can't start with '-': '${value}'." >&2
        exit 1
    fi
    BASELINE=("--${name//_/-}" "${value}")
done
if [[ -n "${BASELINE_VERSION}" ]] && ! rq_match "${BASELINE_VERSION}" '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]*)?$'; then
    echo "ERROR: baseline_version must be a version such as 1.2.3, not '${BASELINE_VERSION}'." >&2
    exit 1
fi
if [[ -n "${BASELINE_ROOT}" && ! -d "${BASELINE_ROOT}" ]]; then
    echo "ERROR: baseline_root must be a directory holding the baseline's source: '${BASELINE_ROOT}' is not one." >&2
    exit 1
fi
case "${RELEASE_TYPE}" in
    "" | major | minor | patch) ;;
    *)
        echo "ERROR: release_type must be major, minor or patch, not '${RELEASE_TYPE}'." >&2
        exit 1
        ;;
esac
rq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
rq_clear_reports .log .json
rq_require_jq
rq_cargo
RQ_WORK=$(mktemp -d)
trap 'rm -rf "${RQ_WORK}"' EXIT
rq_metadata
rq_package_args "${PARAM_PACKAGES}"
rq_extra_args "${PARAM_EXTRA_ARGS}" --color --manifest-path --baseline-rev --baseline-version --baseline-root --release-type --quiet
# Without the status lines that -q hides, the report can't tell which
# package a failed lint belongs to.
for word in ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"}; do
    if rq_match "${word}" '^-q+$'; then
        echo "ERROR: extra_args can't set ${word}: the report reads the status lines it hides." >&2
        exit 1
    fi
done
rq_tool cargo-semver-checks
SEMVER=${RQ_TOOL}
RQ_TOOL_VERSION=$(CARGO=${RQ_CARGO} "${SEMVER}" semver-checks --version 2> /dev/null | awk 'NR == 1') || RQ_TOOL_VERSION=""

RQ_ARGS=(semver-checks check-release "${RQ_PACKAGE_ARGS[@]}" ${BASELINE[@]+"${BASELINE[@]}"})
if [[ -n "${RELEASE_TYPE}" ]]; then
    RQ_ARGS+=(--release-type "${RELEASE_TYPE}")
fi
RQ_ARGS+=(--color never ${RQ_EXTRA_ARGS[@]+"${RQ_EXTRA_ARGS[@]}"})
# shellcheck disable=SC2034 # read by rq_run_record
RQ_INPUTS=()
rq_workspace_inputs
if [[ -n "${BASELINE_ROOT}" ]]; then
    RQ_INPUTS+=("baseline:$(cd "${BASELINE_ROOT}" && pwd)/Cargo.toml")
fi

echo "Checking the public API of ${RQ_PACKAGES[*]:-the workspace} for semver with ${RQ_TOOL_VERSION:-cargo-semver-checks}..."
RC=0
CARGO=${RQ_CARGO} CARGO_TERM_COLOR=never "${SEMVER}" "${RQ_ARGS[@]}" > "${RQ_BASE}.log" 2>&1 || RC=$?
RQ_REPORTS=("${RQ_BASE}.log")

# Each package's "Checking <name> v<baseline> -> v<current> (<change>)" and
# "Summary" status lines, and each "--- failure|warning <lint>: <name> ---"
# section after them, with the items listed under "Failed in:".
REPORT="${RQ_BASE}.json"
awk '
    function flush() {
        if (lint != "") printf "lint\t%s\t%s\t%s\t%s\t%s\n", package, level, lint, name, items
        lint = ""; items = ""; listing = 0
    }
    /^ *Checking [^ ]+ v[^ ]+ -> v[^ ]+ \(.*\)$/ {
        flush()
        line = $0; sub(/^ *Checking /, "", line)
        package = line; sub(/ .*$/, "", package)
        baseline = line; sub(/^[^ ]+ v/, "", baseline); sub(/ .*$/, "", baseline)
        current = line; sub(/^[^>]*-> v/, "", current); sub(/ .*$/, "", current)
        change = line; sub(/^[^(]*\(/, "", change); sub(/\)$/, "", change)
        printf "package\t%s\t%s\t%s\t%s\n", package, baseline, current, change
        next
    }
    /^--- (failure|warning) [^ :]+: .* ---$/ {
        flush()
        line = $0; sub(/^--- /, "", line); sub(/ ---$/, "", line)
        level = line; sub(/ .*$/, "", level)
        lint = line; sub(/^[^ ]+ /, "", lint); sub(/:.*$/, "", lint)
        name = line; sub(/^[^:]*: /, "", name)
        next
    }
    lint != "" && /^Failed in:/ { listing = 1; next }
    lint != "" && listing && /^  [^ ]/ { item = $0; sub(/^  /, "", item); gsub(/\t/, " ", item); items = items (items == "" ? "" : "\037") item; next }
    lint != "" && listing && !/^  / { listing = 0 }
    /^ *Summary / { flush(); line = $0; sub(/^ *Summary /, "", line); printf "summary\t%s\t%s\n", package, line; next }
    END { flush() }
' "${RQ_BASE}.log" | jq -Rn '
    [inputs | split("\t")] as $rows
    | {packages: [$rows[] | select(.[0] == "package") | {name: .[1], baseline_version: .[2], current_version: .[3], change: .[4],
                    summary: (.[1] as $p | [$rows[] | select(.[0] == "summary" and .[1] == $p) | .[2]] | last)}],
       lints: [$rows[] | select(.[0] == "lint") | {package: .[1], level: .[2], lint: .[3], name: .[4],
                    items: (if .[5] == "" then [] else .[5] | split("\u001f") end)}]}' > "${RQ_WORK}/parsed.json"
FAILED=$(jq '[.lints[] | select(.level == "failure")] | length' "${RQ_WORK}/parsed.json")
CHECKED=$(jq '.packages | length' "${RQ_WORK}/parsed.json")
ERROR=""
case "${RC}" in
    0) ;;
    100) ;;
    # Releases before 0.49.0 exit 1 for failed lints and errors alike.
    1) if grep -q '^error' "${RQ_BASE}.log"; then ERROR="cargo-semver-checks could not complete the check (exit code 1)"; fi ;;
    *) ERROR="cargo-semver-checks could not complete the check (exit code ${RC})" ;;
esac
if [[ -z "${ERROR}" && "${RC}" -ne 0 && "${FAILED}" -eq 0 ]]; then
    ERROR="cargo-semver-checks failed (exit code ${RC}), but its output names no failed lint"
elif [[ -z "${ERROR}" && "${RC}" -eq 0 && "${FAILED}" -gt 0 ]]; then
    ERROR="cargo-semver-checks passed, but its output names $(rq_plural "${FAILED}" "failed lint" "failed lints")"
elif [[ -z "${ERROR}" && "${CHECKED}" -eq 0 ]]; then
    ERROR="cargo-semver-checks checked no package: it skips workspace members with publish = false unless packages names them"
fi
jq --arg error "${ERROR}" '. + {error: (if $error == "" then null else $error end)}' "${RQ_WORK}/parsed.json" > "${REPORT}"
RQ_REPORTS+=("${REPORT}")
if [[ "${JUNIT}" == true ]]; then
    rq_junit "${RQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" cargo-semver-checks "$(jq -c '. as $r | [.packages[] | .name as $p
        | ([$r.lints[] | select(.package == $p and .level == "failure")] as $failed
        | if ($failed | length) == 0 then {classname: $p, name: "semver (v\(.baseline_version) -> v\(.current_version))", status: "passed"}
          else $failed[] | {classname: $p, name: .lint, status: "failed", message: .name, detail: (.items | join("\n"))} end)]' "${REPORT}")"
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
    RQ_TOOL=${SEMVER}
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_COUNTS=$(jq -c '{packages: (.packages | length), failed_lints: ([.lints[] | select(.level == "failure")] | length),
        warnings: ([.lints[] | select(.level == "warning")] | length)}' "${REPORT}")
    # shellcheck disable=SC2034 # read by rq_run_record
    RQ_RESULTS=$(jq -c '. as $r | [.packages[] | . + {lints: [.name as $p | $r.lints[] | select(.package == $p) | del(.package)]}]' "${REPORT}")
    rq_run_record "${RQ_BASE}.run-record.json" semver_checks "${OUTCOME}" "$([[ "${OUTCOME}" == error || "${OUTCOME}" == findings ]] && echo 1 || echo 0)" "${STARTED}"
fi

if [[ -n "${ERROR}" ]]; then
    echo "ERROR: ${ERROR}, so the step fails whatever report_only says. Its output:" >&2
    rq_tail "${RQ_BASE}.log"
    if grep -qiE 'rustc version is not high enough|rustdoc (json )?format|format version' "${RQ_BASE}.log"; then
        echo "  Each cargo-semver-checks release reads the rustdoc JSON of a range of Rust releases: install one that" >&2
        echo "  reads this toolchain's (cargo_semver_checks_version), or check with a toolchain it reads." >&2
    fi
    exit 1
fi
jq -r '.packages[] | "  \(.name): v\(.baseline_version) -> v\(.current_version) (\(.change)): \(.summary // "checked")"' "${REPORT}"
jq -r '.lints[] | select(.level == "warning") | "  \(.package): warning[\(.lint)]: \(.name)", (.items[] | "    \(.)")' "${REPORT}"
if [[ "${FAILED}" -gt 0 ]]; then
    jq -r '.lints[] | select(.level == "failure") | "  \(.package): failure[\(.lint)]: \(.name)", (.items[] | "    \(.)")' "${REPORT}"
    rq_gate true "${REPORT_ONLY}" "$(rq_plural "${FAILED}" "semver lint fails" "semver lints fail"): these changes need a bigger version bump."
fi
rq_gate false "${REPORT_ONLY}" "the public API of $(rq_plural "${CHECKED}" package packages) keeps semver."
