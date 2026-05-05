"""Shared pytest fixtures for the Python remote plugin."""

from __future__ import annotations

import queue
from typing import Any
from unittest.mock import MagicMock

import pytest


# ----------------------------------------------------------------------
# Per-class mock fixtures (used by the existing rplugin unit tests).
# ----------------------------------------------------------------------


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


# ----------------------------------------------------------------------
# In-memory ``jupyter_client`` stubs.
#
# These let tests exercise the rplugin end-to-end (start_kernel ->
# execute_code -> stop_kernel) without ever spawning a real kernel.
# ----------------------------------------------------------------------


def _msg(
    msg_type: str,
    parent_msg_id: str,
    content: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "header": {"msg_id": f"reply-{parent_msg_id}", "msg_type": msg_type},
        "msg_type": msg_type,
        "parent_header": {"msg_id": parent_msg_id},
        "content": content or {},
    }


class StubKernelClient:
    """Deterministic in-memory replacement for ``BlockingKernelClient``.

    Tests can pre-load ``iopub_messages`` / ``shell_messages`` to control
    what the rplugin observes. By default ``execute`` / ``complete`` /
    ``inspect`` fabricate just enough traffic to drive the rplugin to
    completion.
    """

    def __init__(self) -> None:
        self.iopub_messages: list[dict[str, Any]] = []
        self.shell_messages: list[dict[str, Any]] = []
        self.executed: list[str] = []
        self.completed: list[tuple[str, int]] = []
        self.inspected: list[tuple[str, int]] = []
        self.channels_started: bool = False
        self.channels_stopped: bool = False
        self.ready_waits: int = 0
        self._counter: int = 0

    def _next_msg_id(self, prefix: str) -> str:
        self._counter += 1
        return f"{prefix}-{self._counter}"

    # Channel lifecycle ------------------------------------------------

    def start_channels(self) -> None:
        self.channels_started = True

    def stop_channels(self) -> None:
        self.channels_stopped = True

    def wait_for_ready(self, timeout: float | None = None) -> None:
        del timeout
        self.ready_waits += 1

    # Requests ---------------------------------------------------------

    def execute(self, code: str, store_history: bool = False, allow_stdin: bool = False) -> str:
        del store_history, allow_stdin
        msg_id = self._next_msg_id("exec")
        self.executed.append(code)
        # Default conversation: busy -> stream(echo) -> idle.
        self.iopub_messages.extend(
            [
                _msg("status", msg_id, {"execution_state": "busy"}),
                _msg("stream", msg_id, {"name": "stdout", "text": code}),
                _msg("status", msg_id, {"execution_state": "idle"}),
            ]
        )
        return msg_id

    def complete(self, code: str, cursor_pos: int) -> str:
        msg_id = self._next_msg_id("comp")
        self.completed.append((code, cursor_pos))
        self.shell_messages.append(
            _msg(
                "complete_reply",
                msg_id,
                {
                    "matches": [],
                    "cursor_start": cursor_pos,
                    "cursor_end": cursor_pos,
                    "metadata": {},
                    "status": "ok",
                },
            )
        )
        return msg_id

    def inspect(self, code: str, cursor_pos: int) -> str:
        msg_id = self._next_msg_id("ins")
        self.inspected.append((code, cursor_pos))
        self.shell_messages.append(
            _msg(
                "inspect_reply",
                msg_id,
                {"found": False, "data": {}, "metadata": {}, "status": "ok"},
            )
        )
        return msg_id

    # Reply queues -----------------------------------------------------

    def get_iopub_msg(self, timeout: float | None = None) -> dict[str, Any]:
        del timeout
        if not self.iopub_messages:
            raise queue.Empty
        return self.iopub_messages.pop(0)

    def get_shell_msg(self, timeout: float | None = None) -> dict[str, Any]:
        del timeout
        if not self.shell_messages:
            raise queue.Empty
        return self.shell_messages.pop(0)


class StubKernelManager:
    def __init__(self, client: StubKernelClient, kernel_name: str) -> None:
        self.kernel_name: str = kernel_name
        self._client: StubKernelClient = client
        self.started: bool = False
        self.shutdown: bool = False
        self.restarts: int = 0

    def start_kernel(self) -> None:
        self.started = True

    def shutdown_kernel(self, now: bool = False) -> None:
        del now
        self.shutdown = True

    def restart_kernel(self, now: bool = False) -> None:
        del now
        self.restarts += 1

    def client(self) -> StubKernelClient:
        return self._client


class StubKernelSpecManager:
    def __init__(self, specs: dict[str, dict[str, Any]] | None = None) -> None:
        self._specs: dict[str, dict[str, Any]] = specs or {
            "python3": {
                "spec": {
                    "display_name": "Python 3",
                    "language": "python",
                    "argv": ["python", "-m", "ipykernel_launcher", "-f", "{connection_file}"],
                },
                "resource_dir": "/stub/python3",
            },
        }

    def get_all_specs(self) -> dict[str, dict[str, Any]]:
        return self._specs


class JupyterClientStubs:
    """Bundle of stubs exposed by the ``mock_jupyter_client`` fixture."""

    def __init__(self) -> None:
        self.clients: list[StubKernelClient] = []
        self.managers: list[StubKernelManager] = []
        self.spec_manager: StubKernelSpecManager = StubKernelSpecManager()

    def make_manager(self, *, kernel_name: str) -> StubKernelManager:
        client = StubKernelClient()
        manager = StubKernelManager(client, kernel_name)
        self.clients.append(client)
        self.managers.append(manager)
        return manager


@pytest.fixture
def mock_jupyter_client(monkeypatch: pytest.MonkeyPatch) -> JupyterClientStubs:
    """Replace ``KernelManager`` / ``KernelSpecManager`` with in-memory stubs.

    Each call to ``KernelManager(kernel_name=...)`` produces a fresh
    ``StubKernelManager`` paired with its own ``StubKernelClient`` —
    available on the returned bundle as ``managers`` / ``clients``.
    """

    import jupyter_plugin

    stubs = JupyterClientStubs()
    monkeypatch.setattr(
        jupyter_plugin,
        "KernelManager",
        lambda *, kernel_name: stubs.make_manager(kernel_name=kernel_name),
    )
    monkeypatch.setattr(jupyter_plugin, "KernelSpecManager", lambda: stubs.spec_manager)
    return stubs
