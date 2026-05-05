"""End-to-end smoke tests against a real Jupyter ``python3`` kernel.

Excluded from default ``pytest`` discovery — see ``scripts/test-integration.sh``.
"""

from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock

import pytest


@pytest.fixture
def real_plugin(python3_kernelspec: str) -> Any:
    del python3_kernelspec  # presence asserted via the fixture
    import jupyter_plugin

    return jupyter_plugin.JupyterPlugin(MagicMock(name="nvim"))


def test_execute_evaluates_expression(real_plugin: Any) -> None:
    real_plugin.start_kernel(["it-exec", "python3"])
    try:
        outputs = real_plugin.execute_code(["it-exec", "1 + 1"])
    finally:
        real_plugin.stop_kernel(["it-exec"])

    results = [o for o in outputs if o["output_type"] == "execute_result"]
    assert results, f"expected execute_result, got: {[o['output_type'] for o in outputs]}"
    assert results[-1]["text"] == ["2"]


def test_list_kernelspecs_includes_python3(real_plugin: Any) -> None:
    specs = real_plugin.list_kernelspecs([])
    names = {spec["name"] for spec in specs}
    assert "python3" in names
