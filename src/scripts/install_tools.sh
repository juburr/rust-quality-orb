#!/bin/bash
#
# Checks the tools parameter of the install command before anything is
# installed. The install command picks each tool's install step with a regular
# expression over the parameter, so a misspelled name would otherwise install
# nothing and fail only later, in the command that needed the tool.
#
# Parameters arrive as PARAM_TOOLS.

set -euo pipefail

KNOWN="rust rustup cargo-nextest cargo-llvm-cov cargo-hack cargo-semver-checks cargo-shear"

if [[ "${PARAM_TOOLS}" =~ [^a-z0-9,\ -] ]]; then
    echo "ERROR: tools must name tools separated by commas or spaces, not '${PARAM_TOOLS}'." >&2
    echo "  Known tools: ${KNOWN// /, }." >&2
    exit 1
fi
read -r -a TOOLS <<< "${PARAM_TOOLS//,/ }"
if [[ "${#TOOLS[@]}" -eq 0 ]]; then
    echo "ERROR: tools names no tool. Known tools: ${KNOWN// /, }." >&2
    exit 1
fi
for tool in "${TOOLS[@]}"; do
    if [[ " ${KNOWN} " != *" ${tool} "* ]]; then
        echo "ERROR: tools names '${tool}', which this orb does not install. Known tools: ${KNOWN// /, }." >&2
        exit 1
    fi
done
# Both would put a cargo on the PATH, and the pinned release would shadow
# rustup's.
if [[ " ${TOOLS[*]} " == *" rust "* && " ${TOOLS[*]} " == *" rustup "* ]]; then
    echo "ERROR: tools names both rust and rustup. Pick one: rust pins one Rust release; rustup follows" >&2
    echo "  rust-toolchain.toml and can install several toolchains." >&2
    exit 1
fi
echo "Installing: ${TOOLS[*]}"
