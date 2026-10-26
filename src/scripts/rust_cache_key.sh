#!/bin/bash
#
# Writes the second file install_rust's cache key is computed from: the
# components and targets it installs, with environment variables expanded,
# sorted and without duplicates. The cache holds their archives, and a saved
# cache can't be replaced, so each set of them gets a cache of its own.
# cache_key.sh writes the first file, which names the CPU, HOME and version.
#
# Parameters arrive as PARAM_COMPONENTS, PARAM_TARGETS and
# ORB_CACHE_KEY_FILE.

set -euo pipefail

expand() {
    # The value is piped in on stdin: passed as an argument, a value starting
    # with "-" would be parsed as a flag.
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# words: the words of a list separated by commas or spaces, sorted and
# without duplicates, on one line.
words() {
    awk '{ gsub(/[, ]+/, "\n"); print }' | awk 'NF' | sort -u | tr '\n' ' '
}

components=$(expand "${PARAM_COMPONENTS}" | words)
targets=$(expand "${PARAM_TARGETS}" | words)
# The file is written under a new name and renamed into place, so a file or
# symlink someone else left at its name in a shared /tmp is never written
# through. mv would move it into a directory, so that is refused.
tmp=$(mktemp "${ORB_CACHE_KEY_FILE}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
printf 'components: %s\ntargets: %s\n' "${components}" "${targets}" > "${tmp}"
if [[ -d "${ORB_CACHE_KEY_FILE}" ]] || ! mv -f "${tmp}" "${ORB_CACHE_KEY_FILE}"; then
    echo "ERROR: Could not write ${ORB_CACHE_KEY_FILE}." >&2
    exit 1
fi
