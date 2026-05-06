"""Shared pytest fixtures for the Python remote plugin."""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest


# ----------------------------------------------------------------------
# Per-class mock fixtures (used by the existing rplugin unit tests).
# ----------------------------------------------------------------------


@pytest.fixture
def mock_kernel_manager_cls(monkeypatch: pytest.MonkeyPatch) -> MagicMock:
    """Patch ``AsyncKernelManager`` in jupyter_plugin with a MagicMock factory."""

    import jupyter_plugin

    factory = MagicMock(name="AsyncKernelManagerFactory")
    monkeypatch.setattr(jupyter_plugin, "AsyncKernelManager", factory)
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


def make_async_manager_mock(name: str) -> MagicMock:
    """Build a MagicMock manager whose async methods are AsyncMocks."""

    manager = MagicMock(name=name)
    manager.start_kernel = AsyncMock(name=f"{name}.start_kernel")
    manager.shutdown_kernel = AsyncMock(name=f"{name}.shutdown_kernel")
    manager.restart_kernel = AsyncMock(name=f"{name}.restart_kernel")
    return manager


def make_async_client_mock(name: str) -> MagicMock:
    """Build a MagicMock client whose async methods are AsyncMocks."""

    client = MagicMock(name=name)
    client.wait_for_ready = AsyncMock(name=f"{name}.wait_for_ready")
    client.get_iopub_msg = AsyncMock(name=f"{name}.get_iopub_msg")
    client.get_shell_msg = AsyncMock(name=f"{name}.get_shell_msg")
    return client
