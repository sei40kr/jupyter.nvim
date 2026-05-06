"""Neovim Python remote plugin wrapping :mod:`jupyter_client`.

This module hosts the ``Jupyter*`` RPC functions consumed by the
``jupyter_core`` Lua module. It owns no editor state — only a registry of
running kernels, keyed by an opaque id supplied by the Lua side.

Each kernel runs in its own dedicated worker thread. ZMQ sockets are
thread-bound, so every channel operation must happen on the thread that
opened the channels; cross-thread access raises ``Socket operation on
non-socket``. Sync RPCs block on a future submitted to the worker; async
RPCs return immediately and route the reply back to Lua via
``nvim.async_call`` + ``nvim.exec_lua``.
"""

from __future__ import annotations

import queue
import threading
from collections.abc import Callable
from concurrent.futures import Future
from typing import Any, cast

import pynvim
from jupyter_client.blocking.client import BlockingKernelClient
from jupyter_client.kernelspec import KernelSpecManager
from jupyter_client.manager import KernelManager

_SHELL_TIMEOUT_SECONDS: float = 30.0
_IOPUB_TIMEOUT_SECONDS: float = 30.0
_KERNEL_START_TIMEOUT_SECONDS: float = 60.0
_RPC_TIMEOUT_SECONDS: float = 60.0


class _KernelWorker:
    """A kernel + its dedicated worker thread.

    All channel operations (``client.complete``, ``client.execute``, …)
    are submitted to this thread via :meth:`submit`. Sync callers block
    on ``future.result()``; async callers attach ``done_callback``.
    """

    def __init__(self, spec_name: str) -> None:
        self._spec_name: str = spec_name
        self._queue: queue.Queue[
            tuple[Callable[[BlockingKernelClient], Any], Future[Any]] | None
        ] = queue.Queue()
        self._ready: threading.Event = threading.Event()
        self._start_error: BaseException | None = None
        self._manager: KernelManager | None = None
        self._client: BlockingKernelClient | None = None
        self._thread: threading.Thread = threading.Thread(
            target=self._run,
            name=f"jupyter-kernel-{spec_name}",
            daemon=True,
        )
        self._thread.start()

    def wait_ready(self, timeout: float) -> None:
        if not self._ready.wait(timeout=timeout):
            raise TimeoutError(f"timed out starting kernel {self._spec_name!r}")
        if self._start_error is not None:
            raise self._start_error

    @property
    def client(self) -> BlockingKernelClient:
        if self._client is None:
            raise RuntimeError("kernel client not initialized")
        return self._client

    @property
    def manager(self) -> KernelManager:
        if self._manager is None:
            raise RuntimeError("kernel manager not initialized")
        return self._manager

    def submit(self, fn: Callable[[BlockingKernelClient], Any]) -> Future[Any]:
        future: Future[Any] = Future()
        self._queue.put((fn, future))
        return future

    def stop(self) -> None:
        self._queue.put(None)
        self._thread.join(timeout=_RPC_TIMEOUT_SECONDS)

    def _run(self) -> None:
        try:
            manager = KernelManager(kernel_name=self._spec_name)
            manager.start_kernel()
            client = cast(BlockingKernelClient, manager.client())
            client.start_channels()
            client.wait_for_ready(timeout=_SHELL_TIMEOUT_SECONDS)
        except BaseException as exc:  # pragma: no cover — propagated to wait_ready
            self._start_error = exc
            self._ready.set()
            return

        self._manager = manager
        self._client = client
        self._ready.set()

        while True:
            item = self._queue.get()
            if item is None:
                self._shutdown(manager, client)
                return
            fn, future = item
            if future.cancelled():
                continue
            try:
                result = fn(client)
            except BaseException as exc:
                future.set_exception(exc)
            else:
                future.set_result(result)

    @staticmethod
    def _shutdown(manager: KernelManager, client: BlockingKernelClient) -> None:
        try:
            client.stop_channels()
        finally:
            manager.shutdown_kernel(now=True)


@pynvim.plugin
class JupyterPlugin:
    """Per-kernel worker threads behind sync + async RPC entry points."""

    def __init__(self, nvim: pynvim.Nvim) -> None:
        self._nvim: pynvim.Nvim = nvim
        self._kernels: dict[str, _KernelWorker] = {}
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

        worker = _KernelWorker(spec_name_s)
        try:
            worker.wait_ready(timeout=_KERNEL_START_TIMEOUT_SECONDS)
        except BaseException:
            worker.stop()
            raise
        self._kernels[kernel_id_s] = worker

    @pynvim.function("JupyterStopKernel", sync=True)
    def stop_kernel(self, args: list[Any]) -> None:
        (kernel_id,) = _expect_args(args, 1, ("kernel_id",))
        kernel_id_s = _as_str(kernel_id, "kernel_id")

        worker = self._kernels.pop(kernel_id_s, None)
        if worker is None:
            return
        worker.stop()

    @pynvim.function("JupyterRestartKernel", sync=True)
    def restart_kernel(self, args: list[Any]) -> None:
        (kernel_id,) = _expect_args(args, 1, ("kernel_id",))
        kernel_id_s = _as_str(kernel_id, "kernel_id")

        worker = self._lookup(kernel_id_s)

        def _do(client: BlockingKernelClient) -> None:
            del client  # we use the manager directly
            worker.manager.restart_kernel(now=True)
            worker.client.wait_for_ready(timeout=_SHELL_TIMEOUT_SECONDS)

        worker.submit(_do).result(timeout=_RPC_TIMEOUT_SECONDS)

    @pynvim.function("JupyterExecuteCode", sync=True)
    def execute_code(self, args: list[Any]) -> list[dict[str, Any]]:
        kernel_id, code = _expect_args(args, 2, ("kernel_id", "code"))
        kernel_id_s = _as_str(kernel_id, "kernel_id")
        code_s = _as_str(code, "code")

        worker = self._lookup(kernel_id_s)

        def _do(client: BlockingKernelClient) -> list[dict[str, Any]]:
            msg_id = client.execute(code_s, store_history=False, allow_stdin=False)
            return _drain_iopub_for(client, msg_id)

        return cast(
            list[dict[str, Any]],
            worker.submit(_do).result(timeout=_RPC_TIMEOUT_SECONDS),
        )

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
            worker = self._lookup(kernel_id_s)
        except Exception as exc:
            self._dispatch_resolve(req_id_i, str(exc), None)
            return

        def _do(client: BlockingKernelClient) -> dict[str, Any]:
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

        future = worker.submit(_do)
        future.add_done_callback(lambda f: self._on_async_done(req_id_i, f))

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
            worker = self._lookup(kernel_id_s)
        except Exception as exc:
            self._dispatch_resolve(req_id_i, str(exc), None)
            return

        def _do(client: BlockingKernelClient) -> dict[str, Any]:
            msg_id = client.inspect(code_s, cursor_pos_i)
            reply = _wait_for_shell_reply(client, msg_id, "inspect_reply")
            content = _content(reply)
            data = content.get("data")
            return {
                "found": bool(content.get("found", False)),
                "data": dict(data) if isinstance(data, dict) else {},
            }

        future = worker.submit(_do)
        future.add_done_callback(lambda f: self._on_async_done(req_id_i, f))

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

    def _lookup(self, kernel_id: str) -> _KernelWorker:
        try:
            return self._kernels[kernel_id]
        except KeyError as exc:
            raise ValueError(f"unknown kernel id: {kernel_id}") from exc

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
