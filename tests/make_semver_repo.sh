#!/usr/bin/env bash
#
# Makes a git repository of the semver fixture, and a blobless clone of it,
# for testing semver_checks' baseline_rev in a partial clone:
#
#   DIR/source   main holds tests/fixtures/semver/baseline; feature, from
#                main, holds tests/fixtures/semver/current, which drops a
#                public function
#   DIR/partial  a blobless clone of DIR/source on feature, as CircleCI's
#                checkout makes by default: it lacks the files of the
#                baseline that feature changed, until something fetches them
#
# FIXTURES is the directory holding semver/baseline and semver/current
# (default: this checkout's tests/fixtures).
#
# Run from a checkout:
#   bash tests/make_semver_repo.sh DIR [FIXTURES]

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 DIR [FIXTURES]" >&2
    exit 2
fi
DIR=$1
FIXTURES=${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures}
SOURCE="${DIR}/source"

commit() {
    git -C "${SOURCE}" add -A
    git -C "${SOURCE}" -c user.name=Test -c user.email=test@example.com commit -q -m "$1"
}

mkdir -p "${DIR}"
git init -q -b main "${SOURCE}"
cp -R "${FIXTURES}/semver/baseline/." "${SOURCE}/"
rm -rf "${SOURCE}/target"
commit baseline
git -C "${SOURCE}" checkout -q -b feature
find "${SOURCE}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R "${FIXTURES}/semver/current/." "${SOURCE}/"
rm -rf "${SOURCE}/target"
commit current
git -C "${SOURCE}" config uploadpack.allowFilter true
git -C "${SOURCE}" config uploadpack.allowAnySHA1InWant true
git clone -q --filter=blob:none -b feature "file://$(cd "${SOURCE}" && pwd)" "${DIR}/partial"
echo "Made ${DIR}/partial, a blobless clone on feature, with the baseline on origin/main."
