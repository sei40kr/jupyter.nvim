#!/usr/bin/env bash
# Run the default Python unit-test suite.
#
# Excludes ``tests/python/integration`` — see ``scripts/test-integration.sh``
# for the opt-in real-kernel suite.
set -euo pipefail

cd "$(dirname "$0")/.."
exec pytest -q tests/python "$@"
