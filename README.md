<div align="center">

# jupyter.nvim

The Jupyter Notebook experience, native to Neovim. Run code, see output,
and get kernel-backed completion and hover — without leaving the editor.

[![Neovim](https://img.shields.io/badge/Neovim-0.10+-57A143?logo=neovim&logoColor=white&style=flat-square)](https://neovim.io)
[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?logo=python&logoColor=white&style=flat-square)](https://python.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](#license)

</div>

## Status

> [!IMPORTANT]
> Early / Phase 1. Today the plugin operates on Python, Julia, and R
> source files using the percent format (`# %%`). Round-trip conversion
> with `.ipynb` lands in Phase 2 — see [Roadmap](#roadmap).

## Features

- **Cell detection via Treesitter** — `# %%` and `# %% [markdown]` markers
  parsed from Python, Julia, and R buffers
  ([`queries/python/jupyter.scm`](queries/python/jupyter.scm),
  [`queries/julia/jupyter.scm`](queries/julia/jupyter.scm),
  [`queries/r/jupyter.scm`](queries/r/jupyter.scm)).
- **Cell execution against a live Jupyter kernel** — code dispatched
  through a Python remote plugin built on `jupyter_client`.
- **Virtual-text output rendering** — results, streams, and tracebacks are
  shown as extmarks below each cell. The buffer is never modified.
- **Cell navigation and editing** — jump between cells, insert above /
  below, delete, merge, split.
- **In-process virtual LSP** — a Lua-`cmd` LSP server registered with
  `vim.lsp.start` exposes `textDocument/completion` and `textDocument/hover`
  backed by the kernel's `complete_request` / `inspect_request`. Any
  LSP-aware client (built-in, nvim-cmp, blink.cmp, …) picks it up through
  its generic LSP source — no plugin-specific adapter required.
- **Fully async I/O** — the Python remote plugin runs a single asyncio event
  loop in a daemon thread; every kernel is a coroutine context inside it.
  Completion and hover round-trips are non-blocking, so the editor stays
  responsive while the kernel is busy executing a long-running cell.

## Comparison with [molten-nvim][molten]

molten-nvim is the closest neighbour — both run code against a Jupyter
kernel and render outputs in-buffer. A best-effort snapshot at the time of
writing; check the project for its current state.

| Feature                       | jupyter.nvim                          | [molten-nvim][molten]    |
| ----------------------------- | ------------------------------------- | ------------------------ |
| Jupyter kernel execution      | Yes                                   | Yes                      |
| Cell detection via Treesitter | Yes                                   | Range-based; pair with NotebookNavigator/jupytext for cells |
| Virtual-text output rendering | Yes                                   | Yes                      |
| Inline images / rich MIME     | Planned (Phase 2)                     | Yes (image.nvim)         |
| Kernel-backed completion      | Yes — generic LSP source              | No                       |
| Kernel-backed hover           | Yes — generic LSP source              | No                       |
| `.ipynb` round-trip           | Planned (Phase 2)                     | Via jupytext             |
| Multi-buffer / multi-kernel   | Yes (one kernel per buffer)           | Yes                      |
| Non-blocking completion/hover | Yes — async RPC, editor stays responsive while a cell is running | N/A (no kernel completion) |

**TL;DR:** molten-nvim is the more feature-complete option today, especially
if you need inline images. jupyter.nvim's distinguishing bet is exposing
kernel-backed completion and hover through an in-process LSP server — any
LSP-aware client (built-in, nvim-cmp, blink.cmp, …) picks them up for free,
and they're served by a fully async rplugin so the editor stays responsive
even while a cell is executing.

[molten]: https://github.com/benlubas/molten-nvim

## Requirements

- Neovim with `vim.lsp.start` (recent stable release).
- Python 3.10+ available to Neovim's `python3` provider, with:
  - `pynvim`
  - `jupyter_client`
- After installing or updating the plugin, run `:UpdateRemotePlugins` and
  restart Neovim so the Python remote plugin's manifest is picked up.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "sei40kr/jupyter.nvim",
  build = ":UpdateRemotePlugins",
  opts = {},
}
```

## Quick start

```lua
require("jupyter").setup({
  -- Skip the kernelspec picker by pinning a default.
  default_kernel = "python3",

  -- Recommended starter keymaps (off by default).
  create_default_keymaps = true,
})
```

Then open a Python file with cell markers:

```python
# %% [markdown]
# # Demo

# %%
print("hello from the kernel")

# %%
import math
[math.sqrt(n) for n in range(1, 6)]
```

1. `:JupyterStart` — pick a kernelspec (or pass one: `:JupyterStart python3`).
2. Place the cursor inside a cell and run `:JupyterExecute`.
3. Output appears below the cell as virtual text.

There are **no default keymaps** unless `create_default_keymaps = true` is
passed to `setup`. When enabled, the plugin installs the following
buffer-local maps in supported buffers (`python`, `julia`, `r`):

| Mapping            | Command               | Description           |
| ------------------ | --------------------- | --------------------- |
| `<localleader>jx`  | `:JupyterExecute`     | Execute current cell  |
| `<localleader>jX`  | `:JupyterExecuteAll`  | Execute every cell    |
| `<localleader>jc`  | `:JupyterClear`       | Clear cell output     |
| `<localleader>jn`  | `:JupyterNext`        | Next cell             |
| `<localleader>jp`  | `:JupyterPrev`        | Previous cell         |
| `<localleader>jo`  | `:JupyterInsertBelow` | Insert cell below     |
| `<localleader>jO`  | `:JupyterInsertAbove` | Insert cell above     |
| `K`                | `:JupyterHover`       | Kernel-backed hover   |

Or roll your own:

```lua
vim.keymap.set("n", "<leader>x", "<Cmd>JupyterExecute<CR>", { desc = "Execute cell" })
vim.keymap.set("n", "]j",        "<Cmd>JupyterNext<CR>",    { desc = "Next cell" })
vim.keymap.set("n", "[j",        "<Cmd>JupyterPrev<CR>",    { desc = "Prev cell" })
```

## Commands

> [!WARNING]
> User commands are likely to be removed in a future release in favor of a
> Lua-only API. Prefer `require("jupyter").<fn>()` from your config when
> wiring up keymaps.

<details>
<summary>The full <code>:Jupyter*</code> command list</summary>

| Command                | Description                                        |
| ---------------------- | -------------------------------------------------- |
| `:JupyterStart [spec]` | Start a kernel for the current buffer              |
| `:JupyterStop`         | Stop the buffer's kernel                           |
| `:JupyterRestart`      | Restart the buffer's kernel                        |
| `:JupyterExecute`      | Execute the cell at the cursor                     |
| `:JupyterExecuteAll`   | Execute every cell in the buffer in order          |
| `:JupyterClear`        | Clear the output of the cell at the cursor         |
| `:JupyterClearAll`     | Clear every cell output in the buffer              |
| `:JupyterNext`         | Move cursor to the next cell                       |
| `:JupyterPrev`         | Move cursor to the previous cell                   |
| `:JupyterInsertBelow`  | Insert a new cell below the current cell           |
| `:JupyterInsertAbove`  | Insert a new cell above the current cell           |
| `:JupyterHover`        | Kernel-backed hover for the symbol under cursor    |

`:JupyterStart` accepts a kernelspec name and tab-completes the list returned
by `jupyter kernelspec list`. Without an argument it uses `default_kernel`,
then falls back to a filetype-based default
(`python` → `python3`, `julia` → first `julia*`, `r` → `ir`),
and finally to a `vim.ui.select` prompt when no installed kernel matches.

</details>

## Configuration

`require("jupyter").setup({...})` accepts the following options. All are
optional; unknown keys produce a warning rather than a hard error so older
plugin versions tolerate newer configs.

```lua
require("jupyter").setup({
  -- Kernelspec name to use when :JupyterStart is invoked without arguments.
  default_kernel = nil,

  -- Virtual-text output rendering. nil uses the built-in defaults.
  display = {
    max_lines = 20,                       -- truncate output at this many lines
    truncation_hint = "+ %d more lines",  -- printf-style; %d gets the elided count
    hl_group = "Comment",                 -- highlight group for output text
    status_hl = {                         -- per-state status indicator highlights
      starting = "DiagnosticHint",
      idle     = "DiagnosticHint",
      busy     = "DiagnosticInfo",
      error    = "DiagnosticError",
    },
  },

  -- Register :Jupyter* user commands.
  create_user_commands = true,

  -- Install buffer-local <localleader>j* keymaps in supported buffers
  -- (python, julia, r).
  create_default_keymaps = false,

  -- Auto-attach the in-process LSP (completion + hover) when a kernel starts.
  virtual_lsp = true,
})
```

## Architecture

The implementation lives in two Lua modules backed by a Python remote plugin:

- `lua/jupyter_core/` — typed Lua API (`Kernel`, `KernelSpec`, `Output`)
  over the RPC surface exposed by `rplugin/python3/jupyter_plugin.py`. Knows
  nothing about buffers, extmarks, or cells.
- `lua/jupyter/` — everything editor-facing: cell detection, navigation,
  virtual-text display, the in-process LSP, commands, and keymaps. Always
  goes through `jupyter_core`.

The rplugin is built on `jupyter_client`'s `AsyncKernelManager` /
`AsyncKernelClient`. A single daemon thread hosts one asyncio event loop;
each kernel is a coroutine context inside it, with a per-kernel
`asyncio.Lock` to preserve `jupyter_client`'s channel-ordering invariants.
Async RPCs (completion, hover) route their reply back to Lua via
`nvim.async_call` + `nvim.exec_lua`, so neither Neovim's main loop nor the
LSP client ever blocks on a kernel round-trip.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture, repository layout,
module responsibilities, and design rationale.

## Roadmap

Phase 2 (planned, not yet implemented):

- Round-trip conversion with `.ipynb` — load a notebook into the buffer as
  percent format, save back as `.ipynb` while preserving metadata and
  execution outputs.
- Content-type-aware output rendering — pretty-print JSON, format
  tracebacks, surface `image/*` and `text/html` inline where feasible.
- Enhanced cell visualization — execution counters, timestamps, and
  highlighting on cell boundaries.

## Contributing / Development

A `flake.nix` is provided. `nix develop` drops you into a shell with Neovim,
the plugin, `jupyter_client`, an isolated `ipykernel` (plus `numpy` /
`pandas`), Julia (`IJulia`) and R (`IRkernel`) kernels, `vusted`, the Lua
language server, and `basedpyright`. The Jupyter runtime is rooted under a
temporary directory so it does not touch your host's Jupyter installation.

```sh
nix develop             # drop into the dev shell

make test               # run both Lua and Python unit tests
make test-lua           # vusted (lua/)
make test-python        # pytest (rplugin/)
make test-integration   # opt-in; spawns a real ipykernel
make lint-lua           # lua-language-server --check
make check              # lint + tests
```

Formatters and linters (`stylua`, `luacheck` / `selene`, `ruff`,
`basedpyright`) are wired through the dev shell's pre-commit hook; running
`nix develop` installs the hook automatically.

Commit messages follow [Angular Conventional Commits](https://github.com/angular/angular/blob/main/contributing-docs/commit-message-guidelines.md):
`<type>(<scope>): <subject>`. Common scopes: `core`, `cell`, `display`,
`completion`, `rplugin`, `flake`.

## License

MIT
