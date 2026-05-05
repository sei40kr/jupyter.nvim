#!/usr/bin/env bash
# Run the opt-in integration suite against a real Jupyter kernel.
#
# Requires a working kernelspec environment (``nix develop`` provides
# ``JUPYTER_PATH`` automatically). Tests skip themselves rather than
# fail when no kernel is reachable, so this is safe to invoke anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."
exec pytest -q tests/python/integration "$@"
