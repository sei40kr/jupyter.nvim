"""Pytest configuration for the opt-in real-kernel suite.

Tests in this directory spawn an actual Jupyter ``python3`` kernel via
``jupyter_client``. They are excluded from the default ``pytest`` run
(see ``pyproject.toml``) and from ``nix flake check``; invoke them
explicitly with ``scripts/test-integration.sh``.
"""

from __future__ import annotations

import os
import shutil

import pytest


def _has_python3_kernelspec() -> bool:
    """Best-effort probe for a usable ``python3`` kernel without importing it.

    Returns False when ``JUPYTER_PATH`` points at a directory without a
    ``python3`` kernelspec, which is what happens outside ``nix develop``.
    """

    jupyter_path = os.environ.get("JUPYTER_PATH")
    if jupyter_path:
        for root in jupyter_path.split(os.pathsep):
            if os.path.isdir(os.path.join(root, "kernels", "python3")):
                return True
        return False
    # Fall back to whatever ``jupyter`` is on PATH; the per-test fixture
    # below will skip if discovery fails.
    return shutil.which("jupyter") is not None


@pytest.fixture(scope="session")
def python3_kernelspec() -> str:
    """Skip the test if a real ``python3`` kernel cannot be discovered."""

    if not _has_python3_kernelspec():
        pytest.skip(
            "no python3 kernelspec on JUPYTER_PATH — run inside `nix develop`",
            allow_module_level=False,
        )
    return "python3"
