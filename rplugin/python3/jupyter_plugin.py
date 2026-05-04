"""Neovim Python remote plugin wrapping :mod:`jupyter_client`.

This module hosts the ``Jupyter*`` RPC functions consumed by the
``jupyter_core`` Lua module. It owns no editor state — only a registry of
running kernels, keyed by an opaque id supplied by the Lua side.
"""

from __future__ import annotations

import queue
from typing import Any, cast

import pynvim
from jupyter_client.blocking.client import BlockingKernelClient
from jupyter_client.kernelspec import KernelSpecManager
from jupyter_client.manager import KernelManager

_SHELL_TIMEOUT_SECONDS: float = 30.0
_IOPUB_TIMEOUT_SECONDS: float = 30.0


@pynvim.plugin
class JupyterPlugin:
    """Proxies a registry of Jupyter kernels behind synchronous RPC calls."""

    def __init__(self, nvim: pynvim.Nvim) -> None:
        self._nvim: pynvim.Nvim = nvim
        self._kernels: dict[str, tuple[KernelManager, BlockingKernelClient]] = {}
        self._spec_manager: KernelSpecManager = KernelSpecManager()

    # ------------------------------------------------------------------
    # RPC functions
    # ------------------------------------------------------------------

    @pynvim.function("JupyterStartKernel", sync=True)
    def start_kernel(self, args: list[Any]) -> None:
        kernel_id, spec_name = _expect_args(args, 2, ("kernel_id", "spec_name"))
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        spec_name_s = _as_str(spec_name, "spec_name")

        if kernel_id_s in self._kernels:
            raise ValueError(f"kernel already started: {kernel_id_s}")

        manager = KernelManager(kernel_name=spec_name_s)
        manager.start_kernel()
        client = cast(BlockingKernelClient, manager.client())
        client.start_channels()
        client.wait_for_ready(timeout=_SHELL_TIMEOUT_SECONDS)
        self._kernels[kernel_id_s] = (manager, client)

    @pynvim.function("JupyterStopKernel", sync=True)
    def stop_kernel(self, args: list[Any]) -> None:
        (kernel_id,) = _expect_args(args, 1, ("kernel_id",))
        kernel_id_s = _as_str(kernel_id, "kernel_id")

        entry = self._kernels.pop(kernel_id_s, None)
        if entry is None:
            return
        manager, client = entry
        try:
            client.stop_channels()
        finally:
            manager.shutdown_kernel(now=True)

    @pynvim.function("JupyterRestartKernel", sync=True)
    def restart_kernel(self, args: list[Any]) -> None:
        (kernel_id,) = _expect_args(args, 1, ("kernel_id",))
        kernel_id_s = _as_str(kernel_id, "kernel_id")

        manager, client = self._lookup(kernel_id_s)
        manager.restart_kernel(now=True)
        client.wait_for_ready(timeout=_SHELL_TIMEOUT_SECONDS)

    @pynvim.function("JupyterExecuteCode", sync=True)
    def execute_code(self, args: list[Any]) -> list[dict[str, Any]]:
        kernel_id, code = _expect_args(args, 2, ("kernel_id", "code"))
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        code_s = _as_str(code, "code")

        _, client = self._lookup(kernel_id_s)
        msg_id = client.execute(code_s, store_history=False, allow_stdin=False)
        return _drain_iopub_for(client, msg_id)

    @pynvim.function("JupyterComplete", sync=True)
    def complete(self, args: list[Any]) -> dict[str, Any]:
        kernel_id, code, cursor_pos = _expect_args(args, 3, ("kernel_id", "code", "cursor_pos"))
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        code_s = _as_str(code, "code")
        cursor_pos_i = _as_int(cursor_pos, "cursor_pos")

        _, client = self._lookup(kernel_id_s)
        msg_id = client.complete(code_s, cursor_pos_i)
        reply = _wait_for_shell_reply(client, msg_id, "complete_reply")
        content = _content(reply)

        result: dict[str, Any] = {
            "matches": [str(m) for m in (content.get("matches") or [])],
            "cursor_start": int(content.get("cursor_start", cursor_pos_i)),
            "cursor_end": int(content.get("cursor_end", cursor_pos_i)),
        }
        metadata = content.get("metadata")
        if isinstance(metadata, dict):
            result["metadata"] = dict(metadata)
        return result

    @pynvim.function("JupyterInspect", sync=True)
    def inspect(self, args: list[Any]) -> dict[str, Any]:
        kernel_id, code, cursor_pos = _expect_args(args, 3, ("kernel_id", "code", "cursor_pos"))
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        code_s = _as_str(code, "code")
        cursor_pos_i = _as_int(cursor_pos, "cursor_pos")

        _, client = self._lookup(kernel_id_s)
        msg_id = client.inspect(code_s, cursor_pos_i)
        reply = _wait_for_shell_reply(client, msg_id, "inspect_reply")
        content = _content(reply)

        data = content.get("data")
        return {
            "found": bool(content.get("found", False)),
            "data": dict(data) if isinstance(data, dict) else {},
        }

    @pynvim.function("JupyterListKernelspecs", sync=True)
    def list_kernelspecs(self, args: list[Any]) -> list[dict[str, Any]]:
        del args  # No arguments expected.
        result: list[dict[str, Any]] = []
        specs = self._spec_manager.get_all_specs()
        for name, info in specs.items():
            spec = info.get("spec") if isinstance(info, dict) else None
            if not isinstance(spec, dict):
                continue
            result.append(
                {
                    "name": str(name),
                    "display_name": str(spec.get("display_name", name)),
                    "language": str(spec.get("language", "")),
                }
            )
        return result

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _lookup(self, kernel_id: str) -> tuple[KernelManager, BlockingKernelClient]:
        try:
            return self._kernels[kernel_id]
        except KeyError as exc:
            raise ValueError(f"unknown kernel id: {kernel_id}") from exc


def _drain_iopub_for(client: BlockingKernelClient, msg_id: str) -> list[dict[str, Any]]:
    """Block until ``msg_id`` reaches ``idle`` on iopub and return outputs.

    Outputs are returned in arrival order. Messages whose ``parent_header``
    does not match ``msg_id`` are ignored, so concurrent kernel activity
    cannot leak into the result.
    """

    outputs: list[dict[str, Any]] = []
    while True:
        try:
            msg = client.get_iopub_msg(timeout=_IOPUB_TIMEOUT_SECONDS)
        except queue.Empty as exc:
            raise TimeoutError(f"timed out waiting for iopub idle for {msg_id}") from exc

        if _parent_msg_id(msg) != msg_id:
            continue

        msg_type = _msg_type(msg)
        content = _content(msg)

        if msg_type == "status":
            if content.get("execution_state") == "idle":
                break
            continue

        output = _output_from_iopub(msg_type, content)
        if output is not None:
            outputs.append(output)

    return outputs


def _wait_for_shell_reply(
    client: BlockingKernelClient, msg_id: str, expected_type: str
) -> dict[str, Any]:
    """Wait for a shell reply with parent ``msg_id`` and the given type."""

    while True:
        try:
            msg = client.get_shell_msg(timeout=_SHELL_TIMEOUT_SECONDS)
        except queue.Empty as exc:
            raise TimeoutError(f"timed out waiting for {expected_type} for {msg_id}") from exc

        if _parent_msg_id(msg) != msg_id:
            continue
        if _msg_type(msg) != expected_type:
            continue
        return cast(dict[str, Any], msg)


def _output_from_iopub(msg_type: str | None, content: dict[str, Any]) -> dict[str, Any] | None:
    if msg_type == "execute_result":
        data = _mime_bundle(content.get("data"))
        return {
            "output_type": "execute_result",
            "data": data,
            "text": _text_lines(data.get("text/plain")),
            "execution_count": content.get("execution_count"),
        }
    if msg_type == "display_data":
        data = _mime_bundle(content.get("data"))
        return {
            "output_type": "display_data",
            "data": data,
            "text": _text_lines(data.get("text/plain")),
        }
    if msg_type == "stream":
        text_value = str(content.get("text") or "")
        return {
            "output_type": "stream",
            "name": str(content.get("name") or "stdout"),
            "data": {"text/plain": text_value},
            "text": _text_lines(text_value),
        }
    if msg_type == "error":
        traceback = [str(line) for line in (content.get("traceback") or [])]
        return {
            "output_type": "error",
            "ename": str(content.get("ename") or ""),
            "evalue": str(content.get("evalue") or ""),
            "traceback": traceback,
            "data": {},
            "text": list(traceback),
        }
    return None


def _mime_bundle(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    bundle: dict[str, str] = {}
    for key, payload in value.items():
        if isinstance(payload, list):
            bundle[str(key)] = "".join(str(part) for part in payload)
        elif payload is None:
            bundle[str(key)] = ""
        else:
            bundle[str(key)] = str(payload)
    return bundle


def _text_lines(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        joined = "".join(str(part) for part in value)
        return joined.splitlines() or ([""] if joined == "" else [joined])
    text = str(value)
    return text.splitlines() or ([""] if text == "" else [text])


def _msg_type(msg: dict[str, Any]) -> str | None:
    msg_type = msg.get("msg_type")
    if isinstance(msg_type, str):
        return msg_type
    header = msg.get("header")
    if isinstance(header, dict):
        inner = header.get("msg_type")
        if isinstance(inner, str):
            return inner
    return None


def _parent_msg_id(msg: dict[str, Any]) -> str | None:
    parent = msg.get("parent_header")
    if not isinstance(parent, dict):
        return None
    parent_id = parent.get("msg_id")
    return parent_id if isinstance(parent_id, str) else None


def _content(msg: dict[str, Any]) -> dict[str, Any]:
    content = msg.get("content")
    return content if isinstance(content, dict) else {}


def _expect_args(args: list[Any], expected: int, names: tuple[str, ...]) -> list[Any]:
    if len(args) != expected:
        raise ValueError(f"expected {expected} args ({', '.join(names)}), got {len(args)}")
    return args


def _as_str(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a string, got {type(value).__name__}")
    return value


def _as_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{name} must be an int, got {type(value).__name__}")
    return value
