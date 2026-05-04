"""Tests for ``rplugin/python3/jupyter_plugin.py``."""

from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock

import pytest


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------


def _msg(
    msg_type: str,
    parent_msg_id: str,
    content: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "header": {"msg_id": "x", "msg_type": msg_type},
        "msg_type": msg_type,
        "parent_header": {"msg_id": parent_msg_id},
        "content": content or {},
    }


def _install_kernel(
    plugin: Any,
    mock_kernel_manager_cls: MagicMock,
    *,
    kernel_id: str = "k1",
    spec_name: str = "python3",
) -> tuple[MagicMock, MagicMock]:
    """Start a kernel through the plugin and return (manager, client) mocks."""

    manager = MagicMock(name=f"KernelManager[{kernel_id}]")
    client = MagicMock(name=f"KernelClient[{kernel_id}]")
    manager.client.return_value = client
    mock_kernel_manager_cls.return_value = manager

    plugin.start_kernel([kernel_id, spec_name])
    return manager, client


# ----------------------------------------------------------------------
# Registry behavior
# ----------------------------------------------------------------------


def test_start_adds_entry(plugin: Any, mock_kernel_manager_cls: MagicMock) -> None:
    manager, client = _install_kernel(plugin, mock_kernel_manager_cls)

    assert plugin._kernels["k1"] == (manager, client)
    mock_kernel_manager_cls.assert_called_once_with(kernel_name="python3")
    manager.start_kernel.assert_called_once_with()
    client.start_channels.assert_called_once_with()
    client.wait_for_ready.assert_called_once()


def test_start_rejects_duplicate_id(plugin: Any, mock_kernel_manager_cls: MagicMock) -> None:
    _install_kernel(plugin, mock_kernel_manager_cls)
    with pytest.raises(ValueError, match="already started"):
        plugin.start_kernel(["k1", "python3"])


def test_stop_removes_entry(plugin: Any, mock_kernel_manager_cls: MagicMock) -> None:
    manager, client = _install_kernel(plugin, mock_kernel_manager_cls)

    plugin.stop_kernel(["k1"])

    assert "k1" not in plugin._kernels
    client.stop_channels.assert_called_once_with()
    manager.shutdown_kernel.assert_called_once_with(now=True)


def test_stop_unknown_id_is_noop(plugin: Any) -> None:
    plugin.stop_kernel(["never-started"])  # must not raise


def test_restart_preserves_id(plugin: Any, mock_kernel_manager_cls: MagicMock) -> None:
    manager, client = _install_kernel(plugin, mock_kernel_manager_cls)
    client.wait_for_ready.reset_mock()

    plugin.restart_kernel(["k1"])

    assert plugin._kernels["k1"] == (manager, client)
    manager.restart_kernel.assert_called_once_with(now=True)
    client.wait_for_ready.assert_called_once()


def test_restart_unknown_id_raises(plugin: Any) -> None:
    with pytest.raises(ValueError, match="unknown kernel id"):
        plugin.restart_kernel(["nope"])


# ----------------------------------------------------------------------
# Execute
# ----------------------------------------------------------------------


def test_execute_returns_outputs_in_arrival_order_filtered_by_parent(
    plugin: Any,
    mock_kernel_manager_cls: MagicMock,
) -> None:
    _, client = _install_kernel(plugin, mock_kernel_manager_cls)
    client.execute.return_value = "exec-1"

    iopub_messages = [
        _msg("status", "exec-1", {"execution_state": "busy"}),
        _msg("stream", "exec-1", {"name": "stdout", "text": "first\n"}),
        # An unrelated message must be ignored.
        _msg("stream", "other-msg", {"name": "stdout", "text": "noise\n"}),
        _msg(
            "execute_result",
            "exec-1",
            {
                "execution_count": 7,
                "data": {"text/plain": "42", "text/html": "<b>42</b>"},
                "metadata": {},
            },
        ),
        _msg(
            "display_data",
            "exec-1",
            {
                "data": {"text/plain": "fig"},
                "metadata": {},
            },
        ),
        _msg("status", "exec-1", {"execution_state": "idle"}),
    ]
    client.get_iopub_msg.side_effect = iopub_messages

    outputs = plugin.execute_code(["k1", "print('first'); 42"])

    client.execute.assert_called_once_with(
        "print('first'); 42", store_history=False, allow_stdin=False
    )
    assert [o["output_type"] for o in outputs] == [
        "stream",
        "execute_result",
        "display_data",
    ]
    stream, result, display = outputs
    assert stream["name"] == "stdout"
    assert stream["data"] == {"text/plain": "first\n"}
    assert result["data"] == {"text/plain": "42", "text/html": "<b>42</b>"}
    assert result["text"] == ["42"]
    assert result["execution_count"] == 7
    assert display["data"] == {"text/plain": "fig"}


def test_execute_surfaces_error_outputs_with_traceback(
    plugin: Any, mock_kernel_manager_cls: MagicMock
) -> None:
    _, client = _install_kernel(plugin, mock_kernel_manager_cls)
    client.execute.return_value = "exec-2"

    client.get_iopub_msg.side_effect = [
        _msg("status", "exec-2", {"execution_state": "busy"}),
        _msg(
            "error",
            "exec-2",
            {
                "ename": "ValueError",
                "evalue": "boom",
                "traceback": [
                    "Traceback (most recent call last):",
                    "  File ...",
                    "ValueError: boom",
                ],
            },
        ),
        _msg("status", "exec-2", {"execution_state": "idle"}),
    ]

    outputs = plugin.execute_code(["k1", "raise ValueError('boom')"])

    assert len(outputs) == 1
    err = outputs[0]
    assert err["output_type"] == "error"
    assert err["ename"] == "ValueError"
    assert err["evalue"] == "boom"
    assert err["traceback"] == [
        "Traceback (most recent call last):",
        "  File ...",
        "ValueError: boom",
    ]


def test_execute_unknown_kernel_raises(plugin: Any) -> None:
    with pytest.raises(ValueError, match="unknown kernel id"):
        plugin.execute_code(["missing", "x = 1"])


# ----------------------------------------------------------------------
# Complete
# ----------------------------------------------------------------------


def test_complete_returns_expected_shape(plugin: Any, mock_kernel_manager_cls: MagicMock) -> None:
    _, client = _install_kernel(plugin, mock_kernel_manager_cls)
    client.complete.return_value = "comp-1"
    client.get_shell_msg.side_effect = [
        # Unrelated reply that must be skipped.
        {
            "header": {"msg_id": "y", "msg_type": "execute_reply"},
            "msg_type": "execute_reply",
            "parent_header": {"msg_id": "other"},
            "content": {},
        },
        {
            "header": {"msg_id": "z", "msg_type": "complete_reply"},
            "msg_type": "complete_reply",
            "parent_header": {"msg_id": "comp-1"},
            "content": {
                "matches": ["foo", "foobar"],
                "cursor_start": 0,
                "cursor_end": 3,
                "metadata": {"_jupyter_types_experimental": []},
                "status": "ok",
            },
        },
    ]

    result = plugin.complete(["k1", "foo", 3])

    client.complete.assert_called_once_with("foo", 3)
    assert result["matches"] == ["foo", "foobar"]
    assert result["cursor_start"] == 0
    assert result["cursor_end"] == 3
    assert result["metadata"] == {"_jupyter_types_experimental": []}


# ----------------------------------------------------------------------
# Inspect
# ----------------------------------------------------------------------


def test_inspect_found_true(plugin: Any, mock_kernel_manager_cls: MagicMock) -> None:
    _, client = _install_kernel(plugin, mock_kernel_manager_cls)
    client.inspect.return_value = "ins-1"
    client.get_shell_msg.side_effect = [
        {
            "header": {"msg_id": "r", "msg_type": "inspect_reply"},
            "msg_type": "inspect_reply",
            "parent_header": {"msg_id": "ins-1"},
            "content": {
                "found": True,
                "data": {"text/plain": "Signature: foo()"},
                "metadata": {},
                "status": "ok",
            },
        },
    ]

    result = plugin.inspect(["k1", "foo", 0])

    client.inspect.assert_called_once_with("foo", 0)
    assert result == {"found": True, "data": {"text/plain": "Signature: foo()"}}


def test_inspect_found_false(plugin: Any, mock_kernel_manager_cls: MagicMock) -> None:
    _, client = _install_kernel(plugin, mock_kernel_manager_cls)
    client.inspect.return_value = "ins-2"
    client.get_shell_msg.side_effect = [
        {
            "header": {"msg_id": "r", "msg_type": "inspect_reply"},
            "msg_type": "inspect_reply",
            "parent_header": {"msg_id": "ins-2"},
            "content": {
                "found": False,
                "data": {},
                "metadata": {},
                "status": "ok",
            },
        },
    ]

    result = plugin.inspect(["k1", "nope", 0])

    assert result == {"found": False, "data": {}}


# ----------------------------------------------------------------------
# Kernelspecs
# ----------------------------------------------------------------------


def test_list_kernelspecs_maps_to_dict_shape(
    plugin: Any, mock_kernel_spec_manager_cls: MagicMock
) -> None:
    instance = mock_kernel_spec_manager_cls.return_value
    instance.get_all_specs.return_value = {
        "python3": {
            "spec": {
                "display_name": "Python 3",
                "language": "python",
                "argv": ["python", "-m", "ipykernel_launcher"],
            },
            "resource_dir": "/tmp/python3",
        },
        "ir": {
            "spec": {
                "display_name": "R",
                "language": "R",
                "argv": ["R", "--slave"],
            },
            "resource_dir": "/tmp/ir",
        },
    }

    result = plugin.list_kernelspecs([])

    assert sorted(r["name"] for r in result) == ["ir", "python3"]
    by_name = {r["name"]: r for r in result}
    assert by_name["python3"] == {
        "name": "python3",
        "display_name": "Python 3",
        "language": "python",
    }
    assert by_name["ir"] == {
        "name": "ir",
        "display_name": "R",
        "language": "R",
    }


def test_list_kernelspecs_skips_malformed_entries(
    plugin: Any, mock_kernel_spec_manager_cls: MagicMock
) -> None:
    instance = mock_kernel_spec_manager_cls.return_value
    instance.get_all_specs.return_value = {
        "broken": {"resource_dir": "/x"},  # no "spec" key
        "python3": {
            "spec": {"display_name": "Py", "language": "python"},
            "resource_dir": "/y",
        },
    }

    result = plugin.list_kernelspecs([])

    assert [r["name"] for r in result] == ["python3"]
