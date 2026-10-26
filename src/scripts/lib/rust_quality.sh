#!/bin/bash

# Shared helpers for the rust-quality-orb commands. Each command passes this
# file to its step as SCRIPT_RUST_QUALITY_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions and variables.

# rq_subst VALUE: prints VALUE with environment variables expanded. The value
# is piped in on stdin: passed as an argument, a value starting with "-" would
# be parsed as a flag. Without the CircleCI CLI (GitHub Actions and local
# runs), the value is used as is.
rq_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# rq_bool NAME VALUE: prints true or false. CircleCI passes boolean parameters
# as 1 or 0; GitHub Actions and local callers use true or false.
rq_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# rq_words PARAMETER VALUE: sets RQ_WORDS to VALUE split like shell words
# (see split_shell_words), naming PARAMETER in any error. Nothing in it is
# expanded or executed: a $(...) or backtick that reached a parameter through
# an environment variable (a branch name, a commit message) reaches the tool as
# text inside quotes, and fails the step outside them.
rq_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to the tool as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    RQ_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# rq_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, setting
# BASH_REMATCH. In other locales a range such as [a-z] can match letters such
# as é (cimg images set LC_ALL=en_US.UTF-8), so checks with ranges use this.
rq_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# rq_list PARAMETER VALUE: sets RQ_LIST to VALUE, with environment variables
# expanded, split on commas and spaces.
rq_list() {
    local value
    RQ_LIST=()
    value=$(rq_subst "$2")
    if [[ "${value}" == *$'\n'* ]]; then
        echo "ERROR: ${1} must be separated by commas or spaces, not newlines." >&2
        exit 1
    fi
    # shellcheck disable=SC2034 # read by the script that evals this file
    read -r -a RQ_LIST <<< "${value//,/ }"
}

# rq_tool BINARY: sets RQ_TOOL to BINARY's path on the PATH, or stops the
# step saying how to install it. Warns when that binary is not one this
# orb's install verified, such as a copy that came with the image and comes
# first on the PATH: the install leaves a record beside each binary it
# installs, naming the binary's SHA-512.
rq_tool() {
    if ! RQ_TOOL=$(command -v "$1"); then
        echo "ERROR: $1 is not on the PATH. Install it in an earlier step with this orb's install (tools: $1)," >&2
        echo "  or with install_${1//-/_}." >&2
        exit 1
    fi
    rq_tool_verified "$1" "${RQ_TOOL}"
}

# rq_tool_verified NAME PATH: warns unless PATH is a NAME this orb's install
# verified, as the install record it leaves beside the binary says.
rq_tool_verified() {
    local record sha
    record="$(dirname "$2")/.$1.install.json"
    sha=$(sha512sum -- "$2" 2> /dev/null | awk '{ print $1 }') || sha=""
    if [[ -z "${sha}" || ! -f "${record}" ]] || ! grep -qF "\"binary_sha512\":\"${sha}\"" "${record}"; then
        echo "WARN: $2 is not the $1 this orb's install verified against its checksum table." >&2
        echo "WARN: Install $1 with this orb's install, and put its install_path first on the PATH, to run a verified one." >&2
    fi
}

# rq_require_jq: stops the step unless jq, which the reports are built with,
# is on the PATH.
rq_require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is not on the PATH, and this command needs it to write its reports." >&2
        echo "  CircleCI's cimg images and GitHub's hosted runners have it; elsewhere, install jq in an earlier step." >&2
        exit 1
    fi
}

# rq_output DIR NAME: checks output_dir and report_name, creates DIR, and sets
# RQ_OUT to DIR and RQ_BASE to the path every report of this run starts with.
rq_output() {
    if [[ "$1" != /* || "$1" == *$'\n'* ]]; then
        echo "ERROR: output_dir must be an absolute path, not '$1'." >&2
        exit 1
    fi
    if ! rq_match "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
        echo "ERROR: report_name must be letters, digits, '.', '_' and '-', not '$2'." >&2
        exit 1
    fi
    if ! mkdir -p "$1"; then
        echo "ERROR: Could not create output_dir $1." >&2
        exit 1
    fi
    RQ_OUT=${1%/}
    RQ_OUT=${RQ_OUT:-/}
    # shellcheck disable=SC2034 # read by the script that evals this file
    RQ_BASE="${RQ_OUT%/}/$2"
}

# rq_clear_reports SUFFIX...: removes what an earlier run with the same
# report_name left in output_dir: <report_name> followed by each SUFFIX, its
# run record and its JUnit. Otherwise a report this run doesn't write, such
# as the SARIF of a check that didn't complete, would be stored with this
# run's artifacts as if it described them.
rq_clear_reports() {
    local suffix
    for suffix in .run-record.json "$@"; do
        rm -rf -- "${RQ_BASE}${suffix}"
    done
    rm -rf -- "${RQ_OUT}/junit/${RQ_BASE##*/}.xml" "${RQ_OUT}/junit/${RQ_BASE##*/}"
}

# rq_uint PARAMETER VALUE [MIN]: stops the step unless VALUE is a whole number
# of at least MIN (default 0).
rq_uint() {
    if ! rq_match "$2" '^[0-9]{1,9}$' || ((10#$2 < ${3:-0})); then
        echo "ERROR: ${1} must be a whole number of at least ${3:-0}, not '$2'." >&2
        exit 1
    fi
}

# rq_junit FILE SUITE CASES: writes JUnit XML to FILE, for CircleCI's Tests
# tab or any other JUnit reader, from CASES, a JSON array of test cases:
#   {"classname": ..., "name": ..., "status": "failed" | "skipped" | "passed",
#    "message": ..., "detail": ...}
# A run with no cases gets one passing case, so the tab shows it ran.
rq_junit() {
    local dir=${1%/*}
    mkdir -p "${dir}"
    # shellcheck disable=SC2016 # jq program, not shell
    jq -r --arg suite "$2" '
        (if length == 0 then [{classname: $suite, name: "no findings", status: "passed"}] else . end) as $cases
        | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<testsuites>",
          "  <testsuite name=\"\($suite | @html)\" tests=\"\($cases | length)\" failures=\"\([$cases[] | select(.status == "failed")] | length)\" skipped=\"\([$cases[] | select(.status == "skipped")] | length)\">",
          ($cases[] |
            "    <testcase classname=\"\(.classname | @html)\" name=\"\(.name | @html)\">"
            + (if .status == "failed" then "<failure message=\"\((.message // "") | @html)\">\((.detail // "") | @html)</failure>"
               elif .status == "skipped" then "<skipped message=\"\((.message // "") | @html)\"/>"
               else "" end)
            + "</testcase>"),
          "  </testsuite>",
          "</testsuites>"
    ' <<< "$3" > "$1"
}

# rq_gate FINDINGS REPORT_ONLY SUMMARY: ends a check. Without findings it
# succeeds. With findings it fails with SUMMARY, unless REPORT_ONLY is true,
# when it only warns: the reports are written either way.
rq_gate() {
    if [[ "$1" == false ]]; then
        echo "Passed: $3"
        exit 0
    fi
    if [[ "$2" == true ]]; then
        echo "WARN: $3" >&2
        echo "WARN: report_only is true, so this step passes. The reports are in ${RQ_OUT}." >&2
        exit 0
    fi
    echo "ERROR: $3" >&2
    echo "  The reports are in ${RQ_OUT}. Set report_only to true to report findings without failing." >&2
    exit 1
}

# rq_plural COUNT SINGULAR PLURAL: prints COUNT and the word that goes with
# it, such as "1 file" or "2 files".
rq_plural() {
    if [[ "$1" -eq 1 ]]; then
        printf '%s %s\n' "$1" "$2"
    else
        printf '%s %s\n' "$1" "$3"
    fi
}

# rq_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV (on GitHub Actions, the action passes it on through
# GITHUB_ENV).
rq_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}

# rq_json_is FILE FILTER [JQ_OPTION...]: whether FILE holds one JSON value for
# which FILTER is true. It compares jq's output instead of using -e, since jq
# 1.6 (as on Ubuntu 22.04 and some cimg images) exits 0 with -e when the file
# is empty, as a tool that failed before writing its report leaves it.
rq_json_is() {
    local file=$1 filter=$2 options=()
    if [[ $# -gt 2 ]]; then
        options=("${@:3}")
    fi
    [[ "$(jq -c ${options[@]+"${options[@]}"} "(${filter}) | if . then true else false end" "${file}" 2> /dev/null)" == true ]]
}

# rq_sha256 FILE: prints FILE's SHA-256.
rq_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

# rq_url_public URL: prints URL without the userinfo, query and fragment,
# which can hold credentials, so it can go in a log or an artifact.
rq_url_public() {
    local url=$1
    if [[ "${url}" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^?#]*) ]]; then
        printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${url%%[?#]*}"
    fi
}

# rq_ci_json: describes the CI job this runs in, for run records: a CircleCI
# job or a GitHub Actions run, or null elsewhere.
rq_ci_json() {
    if [[ -n "${CIRCLE_BUILD_URL:-}" ]]; then
        jq -cn --arg url "${CIRCLE_BUILD_URL}" --arg sha "${CIRCLE_SHA1:-}" --arg job "${CIRCLE_JOB:-}" \
            --arg repo "${CIRCLE_PROJECT_USERNAME:-}${CIRCLE_PROJECT_REPONAME:+/${CIRCLE_PROJECT_REPONAME}}" \
            '{provider: "circleci", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    elif [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        jq -cn --arg url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}/attempts/${GITHUB_RUN_ATTEMPT:-1}" \
            --arg sha "${GITHUB_SHA:-}" --arg job "${GITHUB_JOB:-}" --arg repo "${GITHUB_REPOSITORY:-}" \
            '{provider: "github-actions", build_url: $url, sha1: $sha, job: $job, repository: $repo}'
    else
        echo null
    fi
}

# rq_tool_json PATH VERSION: describes a binary that ran for the run record:
# its SHA-512, and how the orb installed it, from the install record beside
# it when that record describes this very binary.
rq_tool_json() {
    local sha="" install="null" entry
    if [[ -n "$1" && -f "$1" ]]; then
        # Without sha512sum the record says so with a null SHA-512, as rq_tool
        # only warns.
        sha=$(sha512sum -- "$1" 2> /dev/null | awk '{ print $1 }') || sha=""
        entry="$(dirname "$1")/.${1##*/}.install.json"
        # shellcheck disable=SC2016 # jq program, not shell
        if [[ -f "${entry}" ]] && rq_json_is "${entry}" '.binary_sha512 == $sha' --arg sha "${sha}"; then
            install=$(jq -c 'del(.binary_sha512)' "${entry}")
        fi
    fi
    jq -cn --arg name "${1##*/}" --arg path "$1" --arg version "$2" --arg sha "${sha}" --argjson install "${install}" \
        '{name: $name, path: $path, version: $version, sha512: (if $sha == "" then null else $sha end), install: $install}'
}

# rq_args_json ARG...: the arguments as a JSON array. They pass through jq
# NUL-separated, so arguments that start with "-" never reach jq's own option
# parsing, and a URL among them loses its userinfo, query and fragment.
rq_args_json() {
    if [[ $# -eq 0 ]]; then
        echo '[]'
        return 0
    fi
    # Ended by a word rather than a NUL, which jq 1.6 drops from the end of
    # raw input.
    { printf '%s\0' "$@"; printf 'end'; } | jq -Rsc 'split("\u0000") | .[:-1]
        | map(gsub("(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://)[^/?#\\s]*@"; "\(.scheme)")
            | gsub("(?<url>[A-Za-z][A-Za-z0-9+.-]*://[^?#\\s]*)[?#]\\S*"; "\(.url)"))'
}

# rq_tail FILE [LINES]: prints the last LINES (default 40) lines of FILE to
# stderr, indented, to show why a tool failed.
rq_tail() {
    tail -n "${2:-40}" "$1" | sed 's/^/  /' >&2
}

# rq_cargo: stops the step unless cargo is on the PATH, and sets RQ_CARGO
# to it.
rq_cargo() {
    if ! RQ_CARGO=$(command -v cargo); then
        echo "ERROR: cargo is not on the PATH. Use an image with Rust, such as cimg/rust, or install Rust in an" >&2
        echo "  earlier step with this orb's install (tools: rust or rustup), install_rust or install_rustup." >&2
        exit 1
    fi
}

# rq_metadata: reads the workspace of the current directory with cargo
# metadata (without dependencies) into RQ_WORK/metadata.json, and sets
# RQ_WORKSPACE_ROOT and RQ_TARGET_DIR. Stops the step when cargo can't read
# it, which no check could get past.
rq_metadata() {
    # shellcheck disable=SC2153 # RQ_WORK is the work directory the script made
    RQ_METADATA="${RQ_WORK}/metadata.json"
    if ! "${RQ_CARGO}" metadata --format-version 1 --no-deps > "${RQ_METADATA}" 2> "${RQ_WORK}/metadata.err"; then
        echo "ERROR: cargo could not read the workspace in $(pwd). Its output:" >&2
        rq_tail "${RQ_WORK}/metadata.err"
        exit 1
    fi
    RQ_WORKSPACE_ROOT=$(jq -r '.workspace_root' "${RQ_METADATA}")
    # shellcheck disable=SC2034 # read by the script that evals this file
    RQ_TARGET_DIR=$(jq -r '.target_directory' "${RQ_METADATA}")
}

# rq_package_args VALUE: sets RQ_PACKAGE_ARGS to cargo's package selection
# for the packages parameter: --workspace when it is empty, else -p for each
# package it lists, which must be workspace members. Also sets RQ_PACKAGES to
# the selected members' names.
rq_package_args() {
    local name
    local -a members=()
    mapfile -t members < <(jq -r '. as $m | .packages[] | select(.id as $id | $m.workspace_members | index($id)) | .name' "${RQ_METADATA}")
    rq_list packages "$1"
    RQ_PACKAGE_ARGS=()
    RQ_PACKAGES=()
    if [[ "${#RQ_LIST[@]}" -eq 0 ]]; then
        RQ_PACKAGE_ARGS=(--workspace)
        RQ_PACKAGES=(${members[@]+"${members[@]}"})
        return 0
    fi
    for name in "${RQ_LIST[@]}"; do
        if [[ " ${members[*]} " != *" ${name} "* ]]; then
            echo "ERROR: packages names '${name}', which is not a member of the workspace in ${RQ_WORKSPACE_ROOT}." >&2
            echo "  Its members: ${members[*]:-none}." >&2
            exit 1
        fi
        RQ_PACKAGE_ARGS+=(-p "${name}")
        RQ_PACKAGES+=("${name}")
    done
}

# rq_feature_args FEATURES ALL_FEATURES NO_DEFAULT_FEATURES: sets
# RQ_FEATURE_ARGS to cargo's feature options for those parameters.
rq_feature_args() {
    local feature all no_default list=""
    all=$(rq_bool all_features "$2")
    no_default=$(rq_bool no_default_features "$3")
    rq_list features "$1"
    for feature in ${RQ_LIST[@]+"${RQ_LIST[@]}"}; do
        if ! rq_match "${feature}" '^[A-Za-z0-9_][A-Za-z0-9_+.-]*(/[A-Za-z0-9_][A-Za-z0-9_+.-]*)?$'; then
            echo "ERROR: features must list feature names, such as serde or my-crate/serde, not '${feature}'." >&2
            exit 1
        fi
        list+="${list:+,}${feature}"
    done
    if [[ "${all}" == true && -n "${list}" ]]; then
        echo "ERROR: features and all_features can't both be set: all_features turns every feature on." >&2
        exit 1
    fi
    RQ_FEATURE_ARGS=()
    if [[ -n "${list}" ]]; then
        RQ_FEATURE_ARGS+=(--features "${list}")
    fi
    if [[ "${all}" == true ]]; then
        RQ_FEATURE_ARGS+=(--all-features)
    fi
    if [[ "${no_default}" == true ]]; then
        RQ_FEATURE_ARGS+=(--no-default-features)
    fi
}

# rq_extra_args VALUE OPTION...: sets RQ_EXTRA_ARGS to the extra_args
# parameter split like shell words, refusing each OPTION (given as --name or
# -n), alone or with a value after "=": the command sets those itself, and
# its reports depend on them.
rq_extra_args() {
    local word option
    rq_words extra_args "$(rq_subst "$1")"
    shift
    for word in ${RQ_WORDS[@]+"${RQ_WORDS[@]}"}; do
        for option in "$@"; do
            if [[ "${word}" == "${option}" || "${word}" == "${option}="* ]]; then
                echo "ERROR: extra_args can't set ${option}: this command sets it itself, and its reports depend on it." >&2
                exit 1
            fi
        done
    done
    # shellcheck disable=SC2034 # read by the script that evals this file
    RQ_EXTRA_ARGS=(${RQ_WORDS[@]+"${RQ_WORDS[@]}"})
}

# RQ_DIAGNOSTICS_JQ: turns the JSON messages cargo writes with
# --message-format=json, read with jq -s, into the orb's summary:
#   findings  every lint rustc, clippy or rustdoc reported, at warning or
#             error level, once each (cargo reports a lint once per target
#             that compiles the file, such as a lib and its tests)
#   errors    everything else at error level: code that doesn't compile
#   complete  whether the build ran to the end, or stopped only on lints that
#             were denied (deny or forbid): anything else means the check
#             couldn't run
# A lint is a diagnostic whose code is a lint name, such as dead_code,
# clippy::needless_return or rustdoc::broken_intra_doc_links; errors have an
# E0000-style code or none.
# shellcheck disable=SC2016,SC2034 # jq program, read by lint.sh and docs.sh
RQ_DIAGNOSTICS_JQ='
    def is_lint: type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$") and (test("^E[0-9]+$") | not);
    [.[] | select(.reason == "compiler-message") | .message as $m
        | ([($m.spans // [])[] | select(.is_primary)] | first) as $span
        | {level: $m.level, code: ($m.code.code // null), message: $m.message,
           rendered: ($m.rendered // $m.message), file: ($span.file_name // null),
           line: ($span.line_start // null), column: ($span.column_start // null),
           end_line: ($span.line_end // null), end_column: ($span.column_end // null)}] as $messages
    | ([$messages[] | select((.level == "warning" or .level == "error") and (.code | is_lint))]
        | unique_by([.code, .file, .line, .column, .message])) as $findings
    | ([$messages[] | select(.level == "error" and (.code | is_lint | not))]
        | unique_by([.code, .file, .line, .column, .message])) as $errors
    | [.[] | select(.reason == "build-finished") | .success] as $finished
    | {complete: (($finished | length) > 0 and ($finished | all) or (($finished | length) > 0 and ($errors | length) == 0 and ($findings | any(.level == "error")))),
       findings: $findings, errors: $errors}'

# rq_print_findings SUMMARY [LIMIT]: prints the findings in SUMMARY (a file
# RQ_DIAGNOSTICS_JQ wrote), at most LIMIT (default 50) of them.
rq_print_findings() {
    jq -r --argjson limit "${2:-50}" '.findings as $f | ($f[:$limit][]
        | "  \(.file // "?"):\(.line // "?"):\(.column // "?"): \(.level)[\(.code)]: \(.message)"),
        (if ($f | length) > $limit then "  ... and \(($f | length) - $limit) more, in the report" else empty end)' "$1"
}

# rq_print_errors SUMMARY [LIMIT]: prints the rendered errors in SUMMARY, at
# most LIMIT (default 10) of them, to stderr.
rq_print_errors() {
    jq -r --argjson limit "${2:-10}" '.errors[:$limit][] | .rendered' "$1" | sed 's/^/  /' >&2
}

# rq_findings_junit SUMMARY SUITE FILE: writes the findings in SUMMARY as
# JUnit, one failed case per finding, named after its lint and grouped by
# file.
rq_findings_junit() {
    rq_junit "$3" "$2" "$(jq -c '[.findings[] | {classname: (.file // "unknown"),
        name: "\(.code) at \(.line // "?"):\(.column // "?")", status: "failed", message: .message, detail: .rendered}]' "$1")"
}

# rq_sarif SUMMARY TOOL VERSION URI: prints a SARIF 2.1.0 log of the findings
# in SUMMARY, with TOOL (at VERSION, documented at URI) as the driver. Paths
# are relative to the workspace root, as rustc reports them. Clippy lints
# link to their documentation.
rq_sarif() {
    # shellcheck disable=SC2016 # jq program, not shell
    jq --arg tool "$2" --arg version "$3" --arg uri "$4" '
        def help: if startswith("clippy::") then "https://rust-lang.github.io/rust-clippy/master/index.html#" + ltrimstr("clippy::")
            elif startswith("rustdoc::") then "https://doc.rust-lang.org/rustdoc/lints.html"
            else "https://doc.rust-lang.org/rustc/lints/listing/index.html" end;
        {version: "2.1.0", "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
         runs: [{tool: {driver: {name: $tool, version: $version, informationUri: $uri,
                    rules: [.findings | map(.code) | unique | .[] | {id: ., name: ., helpUri: help}]}},
                 results: [.findings[] | {ruleId: .code, level: (if .level == "error" then "error" else "warning" end),
                    message: {text: .message},
                    locations: (if .file == null then [] else [{physicalLocation: {
                        artifactLocation: {uri: .file},
                        region: ({startLine: .line, startColumn: .column, endLine: .end_line, endColumn: .end_column}
                            | with_entries(select(.value != null)))}}] end)}]}]}' "$1"
}

# rq_toolchain_json: the cargo and rustc on the PATH, the rustup toolchain
# they come from when rustup manages them, and the settings that change what
# cargo builds, for the run record; null without cargo.
rq_toolchain_json() {
    local cargo cargo_version rustc_version="" rustup_toolchain=""
    if ! cargo=$(command -v cargo); then
        echo null
        return 0
    fi
    cargo_version=$("${cargo}" --version 2> /dev/null) || cargo_version=""
    rustc_version=$(rustc -vV 2> /dev/null) || rustc_version=""
    if command -v rustup > /dev/null 2>&1; then
        rustup_toolchain=$(rustup show active-toolchain 2> /dev/null | awk 'NR == 1') || rustup_toolchain=""
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    jq -cn --argjson cargo "$(rq_tool_json "${cargo}" "${cargo_version}")" --arg rustc "${rustc_version}" \
        --arg rustup "${rustup_toolchain}" --arg rustflags "${RUSTFLAGS:-}" --arg rustdocflags "${RUSTDOCFLAGS:-}" \
        --arg build_target "${CARGO_BUILD_TARGET:-}" --arg target_dir "${CARGO_TARGET_DIR:-}" \
        --arg toolchain "${RUSTUP_TOOLCHAIN:-}" '
        def blank: if . == "" then null else . end;
        {cargo: $cargo,
         rustc: ($rustc | [split("\n")[] | select(length > 0)]
            | if length == 0 then null
              else {version: .[0]} + (.[1:] | map(capture("^(?<key>[^:]+): (?<value>.*)$")) | from_entries) end),
         rustup_toolchain: ($rustup | blank),
         env: {RUSTFLAGS: ($rustflags | blank), RUSTDOCFLAGS: ($rustdocflags | blank),
               CARGO_BUILD_TARGET: ($build_target | blank), CARGO_TARGET_DIR: ($target_dir | blank),
               RUSTUP_TOOLCHAIN: ($toolchain | blank)}}'
}

# rq_workspace_inputs: adds the files that decide what a cargo command
# checks to RQ_INPUTS, for the run record: the workspace's Cargo.lock and
# rust-toolchain.toml, and every member's Cargo.toml.
rq_workspace_inputs() {
    local manifest
    RQ_INPUTS+=("lockfile:${RQ_WORKSPACE_ROOT}/Cargo.lock")
    for manifest in "${RQ_WORKSPACE_ROOT}/rust-toolchain.toml" "${RQ_WORKSPACE_ROOT}/rust-toolchain"; do
        if [[ -f "${manifest}" ]]; then
            RQ_INPUTS+=("toolchain:${manifest}")
        fi
    done
    while IFS= read -r manifest; do
        RQ_INPUTS+=("manifest:${manifest}")
    done < <(jq -r '. as $m | .packages[] | select(.id as $id | $m.workspace_members | index($id)) | .manifest_path' "${RQ_METADATA}")
}

# rq_run_record FILE COMMAND OUTCOME EXIT_CODE STARTED: writes a run record,
# the JSON document schemas/run-record.v1.json describes, saying what exactly
# this command checked, so a reviewer can tell without running it again. It
# reads what the command set:
#   RQ_TOOL          the tool binary that ran
#   RQ_TOOL_VERSION  what it reports as its version
#   RQ_ARGS          the arguments it ran with, as an array
#   RQ_INPUTS        "role:path" entries, such as "manifest:Cargo.toml"
#   RQ_REPORTS       the report files written
#   RQ_COUNTS        a JSON object of the command's counts
#   RQ_RESULTS       a JSON array of per-item results, such as one per test
# OUTCOME is passed, findings, findings-reported (findings with report_only)
# or error.
rq_run_record() {
    local file=$1 entry path role sha inputs="[]" reports="[]" args
    for entry in ${RQ_INPUTS[@]+"${RQ_INPUTS[@]}"}; do
        role=${entry%%:*}
        path=${entry#*:}
        sha=""
        if [[ -f "${path}" ]]; then
            sha=$(rq_sha256 "${path}")
        fi
        if [[ -d "$(dirname "${path}")" ]]; then
            path=$(cd "$(dirname "${path}")" && pwd)/${path##*/}
        fi
        inputs=$(jq -c --arg role "${role}" --arg path "${path}" --arg sha "${sha}" \
            '. + [{role: $role, path: $path, sha256: (if $sha == "" then null else $sha end)}]' <<< "${inputs}")
    done
    for path in ${RQ_REPORTS[@]+"${RQ_REPORTS[@]}"}; do
        if [[ -f "${path}" ]]; then
            reports=$(jq -c --arg path "${path}" --arg sha "$(rq_sha256 "${path}")" '. + [{path: $path, sha256: $sha}]' <<< "${reports}")
        fi
    done
    # shellcheck disable=SC2153 # RQ_ARGS is set by the script
    args=$(rq_args_json ${RQ_ARGS[@]+"${RQ_ARGS[@]}"})
    if ! jq -n --arg command "$2" --arg outcome "$3" --argjson code "$4" --arg started "$5" \
        --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$(pwd)" --argjson ci "$(rq_ci_json)" \
        --argjson tool "$(if [[ -n "${RQ_TOOL:-}" ]]; then rq_tool_json "${RQ_TOOL}" "${RQ_TOOL_VERSION:-}"; else echo null; fi)" \
        --argjson toolchain "$(rq_toolchain_json)" --arg workspace "${RQ_WORKSPACE_ROOT:-}" \
        --argjson inputs "${inputs}" --argjson reports "${reports}" --argjson counts "${RQ_COUNTS:-null}" \
        --argjson results "${RQ_RESULTS:-null}" --argjson args "${args}" '{
            schema: "https://github.com/juburr/rust-quality-orb/blob/main/schemas/run-record.v1.json",
            command: $command, outcome: $outcome, exit_code: $code,
            started_at: $started, finished_at: $finished, ci: $ci, working_directory: $cwd,
            workspace_root: (if $workspace == "" then null else $workspace end),
            tool: $tool, arguments: $args, toolchain: $toolchain,
            inputs: $inputs, counts: $counts, results: $results, reports: $reports
        }' > "${file}"; then
        echo "WARN: Could not write the run record ${file}." >&2
        return 0
    fi
    echo "Run record: ${file}"
}
