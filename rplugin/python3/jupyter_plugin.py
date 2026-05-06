"""Neovim Python remote plugin wrapping :mod:`jupyter_client`.

This module hosts the ``Jupyter*`` RPC functions consumed by the
``jupyter_core`` Lua module. It owns no editor state — only a registry of
running kernels, keyed by an opaque id supplied by the Lua side.

A single background daemon thread runs an asyncio event loop; every
kernel is a coroutine context inside that loop. ZMQ sockets stay bound
to that one thread so ``jupyter_client``'s threading invariants are
preserved while every RPC is expressed as a straight coroutine. Sync
RPCs bridge into the loop with
``asyncio.run_coroutine_threadsafe(...).result(timeout=...)``; async RPCs
route their reply back to Lua via ``nvim.async_call`` + ``nvim.exec_lua``.
"""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Coroutine
from concurrent.futures import Future
from typing import Any, TypeVar

import pynvim
from jupyter_client.asynchronous.client import AsyncKernelClient
from jupyter_client.kernelspec import KernelSpecManager
from jupyter_client.manager import AsyncKernelManager

_SHELL_TIMEOUT_SECONDS: float = 30.0
_IOPUB_TIMEOUT_SECONDS: float = 30.0
_KERNEL_START_TIMEOUT_SECONDS: float = 60.0
_RPC_TIMEOUT_SECONDS: float = 60.0

_T = TypeVar("_T")


class _Kernel:
    """A live kernel paired with a per-kernel serialization lock.

    ``client.get_iopub_msg`` / ``get_shell_msg`` read a single ZMQ socket
    each, so concurrent requests on the same kernel would otherwise
    interleave their channel reads. The lock reproduces the ordering
    guarantee the previous worker-thread + queue design provided.
    """

    def __init__(self, manager: AsyncKernelManager, client: AsyncKernelClient) -> None:
        self.manager: AsyncKernelManager = manager
        self.client: AsyncKernelClient = client
        self.lock: asyncio.Lock = asyncio.Lock()


class _LoopRunner:
    """Background daemon thread hosting the shared asyncio event loop."""

    def __init__(self) -> None:
        self.loop: asyncio.AbstractEventLoop = asyncio.new_event_loop()
        self._ready: threading.Event = threading.Event()
        self._thread: threading.Thread = threading.Thread(
            target=self._run,
            name="jupyter-rplugin-loop",
            daemon=True,
        )
        self._thread.start()
        self._ready.wait()

    def _run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self._ready.set()
        self.loop.run_forever()


@pynvim.plugin
class JupyterPlugin:
    """Asyncio-backed bridge between Neovim RPC and ``jupyter_client``."""

    def __init__(self, nvim: pynvim.Nvim) -> None:
        self._nvim: pynvim.Nvim = nvim
        self._kernels: dict[str, _Kernel] = {}
        self._spec_manager: KernelSpecManager = KernelSpecManager()
        self._loop_runner: _LoopRunner | None = None

    @property
    def _loop(self) -> asyncio.AbstractEventLoop:
        if self._loop_runner is None:
            self._loop_runner = _LoopRunner()
        return self._loop_runner.loop

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

        kernel = self._run_sync(
            _start_kernel(spec_name_s),
            timeout=_KERNEL_START_TIMEOUT_SECONDS,
        )
        self._kernels[kernel_id_s] = kernel

    @pynvim.function("JupyterStopKernel", sync=True)
    def stop_kernel(self, args: list[Any]) -> None:
        (kernel_id,) = _expect_args(args, 1, ("kernel_id",))
        kernel_id_s = _as_str(kernel_id, "kernel_id")

        kernel = self._kernels.pop(kernel_id_s, None)
        if kernel is None:
            return
        self._run_sync(_stop_kernel(kernel), timeout=_RPC_TIMEOUT_SECONDS)

    @pynvim.function("JupyterRestartKernel", sync=True)
    def restart_kernel(self, args: list[Any]) -> None:
        (kernel_id,) = _expect_args(args, 1, ("kernel_id",))
        kernel_id_s = _as_str(kernel_id, "kernel_id")

        kernel = self._lookup(kernel_id_s)
        self._run_sync(_restart_kernel(kernel), timeout=_RPC_TIMEOUT_SECONDS)

    @pynvim.function("JupyterExecuteCode", sync=True)
    def execute_code(self, args: list[Any]) -> list[dict[str, Any]]:
        kernel_id, code = _expect_args(args, 2, ("kernel_id", "code"))
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        code_s = _as_str(code, "code")

        kernel = self._lookup(kernel_id_s)
        return self._run_sync(_do_execute(kernel, code_s), timeout=_RPC_TIMEOUT_SECONDS)

    @pynvim.function("JupyterCompleteAsync", sync=False)
    def complete_async(self, args: list[Any]) -> None:
        req_id, kernel_id, code, cursor_pos = _expect_args(
            args, 4, ("req_id", "kernel_id", "code", "cursor_pos")
        )
        req_id_i = _as_int(req_id, "req_id")
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        code_s = _as_str(code, "code")
        cursor_pos_i = _as_int(cursor_pos, "cursor_pos")

        try:
            kernel = self._lookup(kernel_id_s)
        except Exception as exc:
            self._dispatch_resolve(req_id_i, str(exc), None)
            return
        cf = asyncio.run_coroutine_threadsafe(
            _do_complete(kernel, code_s, cursor_pos_i), self._loop
        )
        cf.add_done_callback(lambda f: self._on_async_done(req_id_i, f))

    @pynvim.function("JupyterInspectAsync", sync=False)
    def inspect_async(self, args: list[Any]) -> None:
        req_id, kernel_id, code, cursor_pos = _expect_args(
            args, 4, ("req_id", "kernel_id", "code", "cursor_pos")
        )
        req_id_i = _as_int(req_id, "req_id")
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        code_s = _as_str(code, "code")
        cursor_pos_i = _as_int(cursor_pos, "cursor_pos")

        try:
            kernel = self._lookup(kernel_id_s)
        except Exception as exc:
            self._dispatch_resolve(req_id_i, str(exc), None)
            return
        cf = asyncio.run_coroutine_threadsafe(_do_inspect(kernel, code_s, cursor_pos_i), self._loop)
        cf.add_done_callback(lambda f: self._on_async_done(req_id_i, f))

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

    def _lookup(self, kernel_id: str) -> _Kernel:
        try:
            return self._kernels[kernel_id]
        except KeyError as exc:
            raise ValueError(f"unknown kernel id: {kernel_id}") from exc

    def _run_sync(self, coro: Coroutine[Any, Any, _T], *, timeout: float) -> _T:
        return asyncio.run_coroutine_threadsafe(coro, self._loop).result(timeout=timeout)

    def _on_async_done(self, req_id: int, future: Future[Any]) -> None:
        try:
            result = future.result()
        except BaseException as exc:
            self._dispatch_resolve(req_id, str(exc), None)
            return
        self._dispatch_resolve(req_id, None, result)

    def _dispatch_resolve(
        self, req_id: int, err: str | None, result: dict[str, Any] | None
    ) -> None:
        """Schedule the Lua resolver on the nvim main thread."""

        self._nvim.async_call(self._resolve, req_id, err, result)

    def _resolve(self, req_id: int, err: str | None, result: dict[str, Any] | None) -> None:
        self._nvim.exec_lua("require('jupyter_core.async')._resolve(...)", req_id, err, result)


# ----------------------------------------------------------------------
# Coroutines
# ----------------------------------------------------------------------


async def _start_kernel(spec_name: str) -> _Kernel:
    manager = AsyncKernelManager(kernel_name=spec_name)
    await manager.start_kernel()
    client = manager.client()
    client.start_channels()
    try:
        await client.wait_for_ready(timeout=_SHELL_TIMEOUT_SECONDS)
    except BaseException:
        client.stop_channels()
        await manager.shutdown_kernel(now=True)
        raise
    return _Kernel(manager, client)


async def _stop_kernel(kernel: _Kernel) -> None:
    async with kernel.lock:
        try:
            kernel.client.stop_channels()
        finally:
            await kernel.manager.shutdown_kernel(now=True)


async def _restart_kernel(kernel: _Kernel) -> None:
    async with kernel.lock:
        await kernel.manager.restart_kernel(now=True)
        await kernel.client.wait_for_ready(timeout=_SHELL_TIMEOUT_SECONDS)


async def _do_execute(kernel: _Kernel, code: str) -> list[dict[str, Any]]:
    async with kernel.lock:
        msg_id = kernel.client.execute(code, store_history=False, allow_stdin=False)
        return await _drain_iopub_for(kernel.client, msg_id)


async def _do_complete(kernel: _Kernel, code: str, cursor_pos: int) -> dict[str, Any]:
    async with kernel.lock:
        msg_id = kernel.client.complete(code, cursor_pos)
        reply = await _wait_for_shell_reply(kernel.client, msg_id, "complete_reply")
    content = _content(reply)
    result: dict[str, Any] = {
        "matches": [str(m) for m in (content.get("matches") or [])],
        "cursor_start": int(content.get("cursor_start", cursor_pos)),
        "cursor_end": int(content.get("cursor_end", cursor_pos)),
    }
    metadata = content.get("metadata")
    if isinstance(metadata, dict):
        result["metadata"] = dict(metadata)
    return result


async def _do_inspect(kernel: _Kernel, code: str, cursor_pos: int) -> dict[str, Any]:
    async with kernel.lock:
        msg_id = kernel.client.inspect(code, cursor_pos)
        reply = await _wait_for_shell_reply(kernel.client, msg_id, "inspect_reply")
    content = _content(reply)
    data = content.get("data")
    return {
        "found": bool(content.get("found", False)),
        "data": dict(data) if isinstance(data, dict) else {},
    }


async def _drain_iopub_for(client: AsyncKernelClient, msg_id: str) -> list[dict[str, Any]]:
    """Await iopub messages for ``msg_id`` until the kernel goes idle.

    Outputs are returned in arrival order. Messages whose ``parent_header``
    does not match ``msg_id`` are ignored, so concurrent kernel activity
    cannot leak into the result.
    """

    outputs: list[dict[str, Any]] = []
    while True:
        try:
            msg = await asyncio.wait_for(client.get_iopub_msg(), timeout=_IOPUB_TIMEOUT_SECONDS)
        except asyncio.TimeoutError as exc:
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


async def _wait_for_shell_reply(
    client: AsyncKernelClient, msg_id: str, expected_type: str
) -> dict[str, Any]:
    """Await a shell reply with parent ``msg_id`` and the given type."""

    while True:
        try:
            msg = await asyncio.wait_for(client.get_shell_msg(), timeout=_SHELL_TIMEOUT_SECONDS)
        except asyncio.TimeoutError as exc:
            raise TimeoutError(f"timed out waiting for {expected_type} for {msg_id}") from exc

        if _parent_msg_id(msg) != msg_id:
            continue
        if _msg_type(msg) != expected_type:
            continue
        return msg


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
