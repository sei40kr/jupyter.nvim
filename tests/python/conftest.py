"""Shared pytest fixtures for the Python remote plugin."""

from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock

import pytest


@pytest.fixture
def mock_kernel_manager_cls(monkeypatch: pytest.MonkeyPatch) -> MagicMock:
    """Patch ``KernelManager`` in jupyter_plugin with a MagicMock factory."""

    import jupyter_plugin

    factory = MagicMock(name="KernelManagerFactory")
    monkeypatch.setattr(jupyter_plugin, "KernelManager", factory)
    return factory


@pytest.fixture
def mock_kernel_spec_manager_cls(monkeypatch: pytest.MonkeyPatch) -> MagicMock:
    """Patch ``KernelSpecManager`` in jupyter_plugin with a MagicMock factory."""

    import jupyter_plugin

    factory = MagicMock(name="KernelSpecManagerFactory")
    monkeypatch.setattr(jupyter_plugin, "KernelSpecManager", factory)
    return factory


@pytest.fixture
def plugin(
    mock_kernel_manager_cls: MagicMock,
    mock_kernel_spec_manager_cls: MagicMock,
) -> Any:
    """Return a freshly-constructed plugin with mocked external classes."""

    del mock_kernel_manager_cls, mock_kernel_spec_manager_cls
    import jupyter_plugin

    nvim = MagicMock(name="nvim")
    return jupyter_plugin.JupyterPlugin(nvim)
