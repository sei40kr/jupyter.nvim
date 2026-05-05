#!/usr/bin/env bash
# Run the vusted Lua test suite.
#
# Honors ``VUSTED_ARGS`` (the dev shell sets it to ``--headless``).
set -euo pipefail

cd "$(dirname "$0")/.."
exec vusted tests/lua "$@"
