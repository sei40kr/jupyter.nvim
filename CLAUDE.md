# jupyter.nvim

A Neovim plugin that reproduces the Jupyter Notebook experience inside the editor.

## Goal

Provide an interactive code execution experience equivalent to Jupyter Notebook from within Neovim, while preserving the editor's native strengths (text editing, Treesitter, LSP integration). Users can run code, get completions, and inspect symbols against a live Jupyter kernel without leaving Neovim.

## Overall Strategy: Two Lua Modules in One Repository

The implementation lives in a single repository but is split into **two Lua modules**, separated by responsibility:

1. **`jupyter_core`** (`lua/jupyter_core/`) — the API module.
   - Backed by a Python remote plugin (`rplugin/python3/`) that wraps `jupyter_client` and speaks RPC to Neovim.
   - Exposes a higher-level, typed Lua abstraction (`Kernel`, `Output`, `KernelSpec`, …) over the raw RPC.
   - Knows nothing about cells, buffers, virtual text, or the percent format. Pure Jupyter-domain abstraction.
   - Reusable in principle: another plugin could `require("jupyter_core")` directly for Jupyter access.

2. **`jupyter`** (`lua/jupyter/`) — the editor module.
   - Depends on `jupyter_core`.
   - Owns everything editor-facing: cell detection, navigation, virtual-text display, completion sources, hover, format conversion, commands, keymaps.

Boundary rule: `jupyter_core` must contain no editor concepts (no buffers, no extmarks, no Treesitter), and `jupyter` must not speak the Jupyter protocol directly — it always goes through `jupyter_core`'s Lua interface.

## Supported File Formats

- **Phase 1 (initial):** Python files using percent format (`# %%`) only.
  - Edited and saved as ordinary `.py` files.
  - Cell boundaries are detected via Treesitter.
- **Phase 2 (later):** automatic round-trip conversion with `.ipynb`.
  - On load: `.ipynb` → percent format expanded into the buffer.
  - On save: percent format → `.ipynb`.
  - Metadata and execution outputs are preserved on the `.ipynb` side.

## Feature Requirements

### 1. Cell Detection (Treesitter)

- A Treesitter query detects `# %%` markers and extracts code-block ranges.
- The query lives at `queries/python/jupyter.scm`.
- Cell type (code / markdown) is distinguished by the marker variant (`# %%` vs `# %% [markdown]`).

### 2. Cell Execution

- Send the cell under the cursor to the Jupyter kernel.
- Display results **without modifying file contents**, using virtual text (extmarks) only.
  - Floating windows and split windows are explicitly out of scope for output display.
- Execution status (busy / idle / error) is also surfaced as an indicator via virtual text.
- **(Future)** Format outputs based on their MIME / content-type as needed — e.g. render `text/plain` as plain virtual text, format `application/json` for readability, surface `text/html` or `image/*` in some lightweight inline form. Phase 1 ships plain-text rendering only.

### 3. Cell Navigation and Creation

- Move to the next / previous cell (`next_cell`, `prev_cell`).
- Insert a new cell above / below the cursor (`insert_cell_above`, `insert_cell_below`).
- Delete / merge / split cells.
- Text object / visual selection that covers a whole cell.

### 4. Completion

- Use the Jupyter kernel's `complete_request` (via `jupyter_core`) to provide completions based on the live kernel context.
- Integration targets:
  - **nvim-cmp** source.
  - **blink.cmp** provider.
- Aim to surface completions that pure static analysis (LSP) cannot — e.g. dynamic attributes, DataFrame column names, runtime-defined symbols.

### 5. Hover

- Use the Jupyter kernel's `inspect_request` (via `jupyter_core`) to fetch documentation / signature info for the symbol under the cursor.
- Exposed as an API equivalent to `K` / `vim.lsp.buf.hover()`.

### 6. (Future) Enhanced Cell Visualization

- Use virtual text to decorate cell boundaries, execution counters, timestamps, etc.
- Folding / highlighting for readability.

## Architecture

```
┌────────────────────────────────────────────────────┐
│  lua/jupyter/   (editor module)                    │
│                                                    │
│   Public API / Commands / Keymaps                  │
│   Cell navigation · Display (virtual text) ·       │
│   Completion (cmp / blink) · Hover ·               │
│   Format conversion (Phase 2)                      │
│   Treesitter cell detection                        │
└──────────────────────┬─────────────────────────────┘
                       │ require("jupyter_core")
┌──────────────────────┴─────────────────────────────┐
│  lua/jupyter_core/   (API module)                  │
│                                                    │
│   Lua API layer:                                   │
│     Kernel · Output · KernelSpec · …               │
│                       │                            │
│                       │ vim.fn.Jupyter*  (RPC)     │
│                       │                            │
│   rplugin/python3/   (Python remote plugin):       │
│     jupyter_client wrapper                         │
└──────────────────────┬─────────────────────────────┘
                       │ ZMQ (jupyter_client)
┌──────────────────────┴─────────────────────────────┐
│                 Jupyter Kernel                     │
└────────────────────────────────────────────────────┘
```

## Repository Layout

```
lua/
├── jupyter_core/               # API module
│   ├── init.lua                # Public Lua API entry point
│   ├── kernel.lua              # Kernel class (lifecycle, execute, complete, inspect)
│   ├── kernel_spec.lua         # KernelSpec value object + listing
│   ├── output.lua              # Output value object (MIME bundle, stream text, error)
│   └── rpc.lua                 # Internal: thin wrapper over vim.fn.Jupyter*
│
└── jupyter/                    # Editor module
    ├── init.lua                # Public API (setup, commands)
    ├── config.lua              # User configuration management
    │
    ├── cell.lua                # Cell detection (Treesitter wrapper),
    │                           # navigation, creation, deletion
    │
    ├── execute.lua             # Cell execution orchestration
    │                           # → jupyter_core.Kernel:execute → display
    │
    ├── display.lua             # Virtual text / extmark output rendering
    │                           # (Phase 2: content-type-aware formatting)
    │
    ├── hover.lua               # Hover feature
    │
    ├── completion/
    │   ├── init.lua            # Shared completion logic
    │   ├── cmp.lua             # nvim-cmp source
    │   └── blink.lua           # blink.cmp provider
    │
    └── format/                 # Phase 2
        ├── ipynb.lua           # .ipynb ↔ cell data conversion
        └── percent.lua         # percent ↔ cell data conversion

rplugin/python3/
├── __init__.py
└── jupyter_plugin.py           # Python remote plugin (jupyter_client wrapper)

queries/python/
└── jupyter.scm                 # Treesitter query for cell detection
```

## Module Responsibilities

### `jupyter_core` (API module)

Provides a typed, object-oriented Lua API. Consumers never call `vim.fn.Jupyter*` directly.

#### `kernel.lua`

```lua
---@class jupyter_core.Kernel
---@field id string
---@field spec_name string
---@field state "starting"|"idle"|"busy"|"dead"
local Kernel = {}

---@param spec_name string
---@return jupyter_core.Kernel
function Kernel.start(spec_name) end

function Kernel:stop() end
function Kernel:restart() end

---@param code string
---@return jupyter_core.Output[]
function Kernel:execute(code) end

---@param code string
---@param cursor_pos integer
---@return jupyter_core.CompletionResult
function Kernel:complete(code, cursor_pos) end

---@param code string
---@param cursor_pos integer
---@return jupyter_core.InspectResult
function Kernel:inspect(code, cursor_pos) end
```

#### `kernel_spec.lua`

```lua
---@class jupyter_core.KernelSpec
---@field name string
---@field display_name string
---@field language string

---@return jupyter_core.KernelSpec[]
function M.list() end
```

#### `output.lua`

```lua
---@class jupyter_core.Output
---@field output_type "execute_result"|"stream"|"display_data"|"error"
---@field data table<string, string>  -- MIME bundle keyed by content-type
---@field text string[]                -- text/plain fallback
```

The `data` field carries the full MIME bundle so downstream plugins can implement content-type-aware rendering.

#### `rpc.lua` (internal)

Thin wrapper over `vim.fn.Jupyter*`. Not part of the public API.

#### `jupyter_plugin.py`

Python remote plugin. Wraps `jupyter_client.KernelManager` / `KernelClient`. Message protocol details are delegated to `jupyter_client`.

Exported RPC functions:

- `JupyterStartKernel(kernel_id, spec_name)`
- `JupyterStopKernel(kernel_id)`
- `JupyterRestartKernel(kernel_id)`
- `JupyterExecuteCode(kernel_id, code)` → outputs (with full MIME bundle)
- `JupyterComplete(kernel_id, code, cursor_pos)` → matches + cursor range
- `JupyterInspect(kernel_id, code, cursor_pos)` → docstring / signature
- `JupyterListKernelspecs()` → list of kernelspecs

### `jupyter` (editor module)

#### `init.lua` (Public API)

Entry point. Registers commands, keymaps, autocmds.

- `setup(opts)` — initialize the plugin.
- `start_kernel(spec_name?)` — start a kernel for the current buffer (delegates to `jupyter_core.Kernel.start`).
- `stop_kernel()` / `restart_kernel()`.
- `execute_cell()` — execute the cell under the cursor.
- `next_cell()` / `prev_cell()` — navigate between cells.
- `insert_cell_below()` / `insert_cell_above()` — create new cells.

The buffer-local kernel is stored in `vim.b[bufnr].jupyter_kernel`.

#### `config.lua`

Validates and merges user options with defaults.

#### `cell.lua`

Cell detection and manipulation backed by a Treesitter query.

- `get_cell_at(bufnr, row)` — return the cell containing the given row.
- `get_all_cells(bufnr)` — return every cell in the buffer.
- `next_cell(bufnr, row)` / `prev_cell(bufnr, row)`.
- `insert_cell(bufnr, row, position, cell_type)`.

Cell info is a plain table:

```lua
---@class jupyter.Cell
---@field cell_type "code"|"markdown"
---@field start_row integer  -- 0-indexed
---@field end_row integer    -- 0-indexed, exclusive
---@field source string[]
```

#### `execute.lua`

Execution orchestration: get the cell from `cell`, run it via `jupyter_core.Kernel:execute`, render results via `display`.

#### `display.lua`

Render outputs as extmarks / virtual text. Never mutates buffer text.

- `show_output(bufnr, cell, outputs)`
- `clear_output(bufnr, cell)`
- `clear_all(bufnr)`

Phase 1 renders the `text/plain` representation only. Phase 2 introduces content-type-aware formatting that picks a renderer based on the MIME bundle on each `Output` (e.g. pretty-print JSON, format tracebacks, handle `image/*` inline where feasible).

#### `hover.lua`

Calls `jupyter_core.Kernel:inspect` and shows the result in Neovim's standard hover floating window.

#### `completion/`

- `cmp.lua` — source object for `cmp.register_source`.
- `blink.lua` — provider definition for blink.cmp.
- `init.lua` — shared completion logic (calls `jupyter_core.Kernel:complete`).

#### `format/` (Phase 2)

Round-trip conversion between `.ipynb` and percent format. Detailed design deferred until Phase 2.

## Development Environment (Nix + Blueprint)

`flake.nix` is built on top of [blueprint](https://github.com/numtide/blueprint).

### devShell

`nix develop` makes the following available:

- Neovim (for manual verification).
- Python with `jupyter_client`, `pynvim`, and a working kernelspec (`ipykernel`).
- Lua lint / format tooling (stylua, luacheck or selene).
- Python lint / format tooling (ruff, mypy).
- vusted for Lua tests.

### kernelspec

The devShell ships `ipykernel` so that `jupyter kernelspec list` returns `python3` out of the box. This lets contributors verify the plugin end-to-end immediately after `nix develop`.

## Development Guidelines

### Type Annotations (critical)

- **Lua:** every function, module, and public data structure must carry LuaLS-style type annotations.
  - Use `---@class` for structures.
  - Use `---@param` / `---@return` for function signatures.
  - Avoid `any`; prefer union types when a single concrete type doesn't fit.
  - `.luarc.json` enables strict mode; the language server should report no type errors.
- **Python:** PEP 484 type hints on every function and method.
  - Always include return-type annotations.
  - The codebase should pass `mypy --strict`.

### Testing

- Lua: unit tests with vusted.
- Python: unit tests with pytest.
- Mock the `jupyter_core` Lua API when testing `jupyter` in isolation.
- Mock the RPC boundary when testing `jupyter_core`'s Lua and Python sides independently.

### Code Style

- Small modules with a single responsibility.
- Names should reveal intent; comments explain *why*, not *what*.
- YAGNI: build what's needed now. Don't pre-implement Phase 2 features during Phase 1.

### Commit Messages

- Follow the [Angular Conventional Commits](https://github.com/angular/angular/blob/main/contributing-docs/commit-message-guidelines.md) specification.
- Format: `<type>(<scope>): <subject>`
  - **type**: one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
  - **scope** (optional): the area touched, e.g. `core`, `cell`, `display`, `completion`, `rplugin`, `flake`.
  - **subject**: imperative, present tense, lower-case, no trailing period.
- Use `BREAKING CHANGE:` in the footer for incompatible changes.
- Keep the subject under ~70 characters; put detail in the body.
