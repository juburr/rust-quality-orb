#!/bin/bash
#
# Writes the file the msrv command's cache key is computed from, before the
# cache is restored: the CPU, HOME, and the Rust versions msrv.sh will
# install, which are rust_version or else the rust-version of each selected
# package. With toolchain_source rust, the cache holds those releases'
# verified downloads. A workspace cargo can't read gets a key of its own;
# msrv.sh then reports why.
#
# Parameters arrive as PARAM_PACKAGES, PARAM_RUST_VERSION and
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

versions=$(expand "${PARAM_RUST_VERSION}")
if [[ -z "${versions}" ]]; then
    packages=" $(expand "${PARAM_PACKAGES}" | tr ',' ' ') "
    if ! versions=$(cargo metadata --format-version 1 --no-deps 2> /dev/null | jq -r --arg packages "${packages}" '. as $m
        | [.packages[] | select(.id as $id | $m.workspace_members | index($id))
            | select(.name as $name | ($packages | test("^ *$")) or ($packages | contains(" " + $name + " "))) | .rust_version // empty]
        | unique | join(" ")' 2> /dev/null); then
        versions=unknown
    fi
fi
# The file is written under a new name and renamed into place, so a file or
# symlink someone else left at its name in a shared /tmp is never written
# through. mv would move it into a directory, so that is refused.
tmp=$(mktemp "${ORB_CACHE_KEY_FILE}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
printf '%s\n%s\n%s\n' "$(uname -m)" "${HOME:-}" "${versions}" > "${tmp}"
if [[ -d "${ORB_CACHE_KEY_FILE}" ]] || ! mv -f "${tmp}" "${ORB_CACHE_KEY_FILE}"; then
    echo "ERROR: Could not write ${ORB_CACHE_KEY_FILE}." >&2
    exit 1
fi
