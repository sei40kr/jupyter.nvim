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
> Early. Phase 1 covers Python, Julia, and R source files using the
> percent format (`# %%`); Phase 2 adds round-trip conversion with
> `.ipynb` — opening a notebook expands the JSON into the percent format
> in the buffer, and `:w` writes it back as JSON with outputs and
> metadata for unchanged cells preserved.

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
- **`.ipynb` round-trip** — opening a notebook expands it into the
  percent format in the buffer; `:w` writes the JSON back, preserving
  outputs, cell ids, and metadata for cells whose source has not
  changed (see [`.ipynb` round-trip](#ipynb-round-trip)).
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
| `.ipynb` round-trip           | Yes — load expands to percent, save writes JSON | Via jupytext             |
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

1. `:lua require("jupyter").start_kernel()` — pick a kernelspec (or pass one:
   `require("jupyter").start_kernel("python3")`).
2. Place the cursor inside a cell and call `require("jupyter").execute_cell()`.
3. Output appears below the cell as virtual text.

The same workflow applies to `.ipynb` notebooks. `nvim foo.ipynb`
expands the JSON into percent format in the buffer; edit and execute
cells normally, then `:w` to round-trip back to the file on disk. See
[`.ipynb` round-trip](#ipynb-round-trip).

### Keymaps

There are **no default keymaps**. Bind the bits you want via
`vim.keymap.set` — typically buffer-local, scoped to the supported
filetypes:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "python", "julia", "r" },
  callback = function(ev)
    local jupyter = require("jupyter")
    local function map(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, silent = true, desc = desc })
    end

    -- Cell navigation (bracket-motion family: ]d, ]g, ]q, ]j…)
    map("]j", jupyter.next_cell, "Next Cell")
    map("[j", jupyter.prev_cell, "Previous Cell")

    -- Filetype-local verbs under <localleader>j
    map("<localleader>jj", jupyter.execute_cell,       "Execute Cell")
    map("<localleader>ja", jupyter.execute_all,        "Execute All Cells")
    map("<localleader>jo", jupyter.insert_cell_below,  "Insert Cell Below")
    map("<localleader>jO", jupyter.insert_cell_above,  "Insert Cell Above")
    map("<localleader>jd", jupyter.delete_cell,        "Delete Cell")
    map("<localleader>jm", jupyter.merge_with_prev,    "Merge with Previous")
    map("<localleader>js", jupyter.split_at_cursor,    "Split Cell at Cursor")
    map("<localleader>jc", jupyter.clear_cell,         "Clear Cell Output")
    map("<localleader>jC", jupyter.clear_all_outputs,  "Clear All Outputs")
    map("<localleader>jr", jupyter.restart_kernel,     "Restart Kernel")
    map("<localleader>jk", function() jupyter.start_kernel() end, "Start Kernel")
    map("<localleader>jq", jupyter.stop_kernel,        "Stop Kernel")
    map("<localleader>ji", jupyter.hover,              "Inspect Symbol")
  end,
})
```

`K` is intentionally not bound — when a kernel is attached the
in-process LSP serves `textDocument/hover`, so the editor's normal
LSP `K` mapping already produces kernel-backed inspection.

If you use [lazy.nvim](https://github.com/folke/lazy.nvim), the same
binding set fits naturally into a plugin spec via `keys` and `ft`:

```lua
{
  "sei40kr/jupyter.nvim",
  build = ":UpdateRemotePlugins",
  ft = { "python", "julia", "r" },
  opts = {},
  keys = {
    { "]j", function() require("jupyter").next_cell() end, ft = { "python", "julia", "r" }, desc = "Next Cell" },
    { "[j", function() require("jupyter").prev_cell() end, ft = { "python", "julia", "r" }, desc = "Previous Cell" },
    { "<localleader>jj", function() require("jupyter").execute_cell() end, ft = { "python", "julia", "r" }, desc = "Execute Cell" },
    { "<localleader>ja", function() require("jupyter").execute_all() end,  ft = { "python", "julia", "r" }, desc = "Execute All Cells" },
    -- …add the rest as needed
  },
}
```

## Lua API

`require("jupyter")` exposes:

| Function                                    | Description                                        |
| ------------------------------------------- | -------------------------------------------------- |
| `start_kernel(spec_name?)`                  | Start a kernel for the current buffer              |
| `stop_kernel()`                             | Stop the buffer's kernel                           |
| `restart_kernel()`                          | Restart the buffer's kernel                        |
| `execute_cell()`                            | Execute the cell at the cursor                     |
| `execute_all()`                             | Execute every cell in the buffer in order          |
| `clear_cell()`                              | Clear the output of the cell at the cursor         |
| `clear_all_outputs()`                       | Clear every cell output in the buffer              |
| `next_cell()`                               | Move cursor to the next cell                       |
| `prev_cell()`                               | Move cursor to the previous cell                   |
| `insert_cell_below(cell_type?)`             | Insert a new cell below the current cell           |
| `insert_cell_above(cell_type?)`             | Insert a new cell above the current cell           |
| `delete_cell()`                             | Delete the cell at the cursor                      |
| `merge_with_prev()`                         | Merge the current cell with the previous cell      |
| `split_at_cursor()`                         | Split the current cell at the cursor               |
| `hover()`                                   | Kernel-backed hover for the symbol under cursor    |

`start_kernel` accepts an optional kernelspec name. Without an argument
it uses `default_kernel`, then falls back to a filetype-based default
(`python` → `python3`, `julia` → first `julia*`, `r` → `ir`), and
finally to a `vim.ui.select` prompt when no installed kernel matches.

## Configuration

`require("jupyter").setup({...})` accepts the following options. All are
optional; unknown keys produce a warning rather than a hard error so older
plugin versions tolerate newer configs.

```lua
require("jupyter").setup({
  -- Kernelspec name to use when start_kernel() is invoked without arguments.
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

## `.ipynb` round-trip

Opening any `*.ipynb` file routes through `BufReadCmd`: the JSON is
parsed, cells are expanded into percent format, and the buffer's
filetype is set from `metadata.kernelspec.language` (falling back to
`metadata.language_info.name`, then `python`). The original document is
stashed on `b:jupyter_ipynb`.

Saving with `:w` is the symmetric `BufWriteCmd`: the buffer is
re-parsed by `jupyter.cell`, cells are matched against the stashed
document by position, and a new JSON file is written. For cells whose
source is unchanged, the cell id, metadata, `execution_count`, and
`outputs` are preserved verbatim. When the source changes the cell id
is preserved but outputs are dropped; when the cell type changes a
fresh id is minted.

See [`examples/example.ipynb`](examples/example.ipynb) for a runnable
notebook.

## Roadmap

Phase 2 (in progress):

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
