---Public entry point for the editor module.
---
---``setup`` wires user options, registers the ``:Jupyter*`` user commands,
---and (optionally) installs a small set of buffer-local keymaps in
---``filetype=python`` buffers. Every command-shaped function lives on
---this module so users can map them directly without poking at internal
---submodules.

local config = require("jupyter.config")
local cell = require("jupyter.cell")
local execute = require("jupyter.execute")
local display = require("jupyter.display")
local hover_mod = require("jupyter.hover")
local registry = require("jupyter.registry")
local lsp = require("jupyter.lsp")

local M = {}

---@type jupyter.Config?
M._cfg = nil

---@return jupyter.Config
local function cfg()
	if M._cfg == nil then
		M._cfg = config.merge(nil)
	end
	return M._cfg
end

---@return integer
local function current_buf()
	return vim.api.nvim_get_current_buf()
end

---@param bufnr integer
---@return integer
local function win_for_buf(bufnr)
	local winid = vim.fn.bufwinid(bufnr)
	if winid == -1 then
		return vim.api.nvim_get_current_win()
	end
	return winid
end

---@param bufnr integer
---@return jupyter_core.Kernel?
local function get_kernel(bufnr)
	return registry.get(bufnr)
end

---@param spec_name string
---@param bufnr integer
local function start_with_spec(spec_name, bufnr)
	local existing = get_kernel(bufnr)
	if existing ~= nil and existing.state ~= "dead" then
		vim.notify("jupyter: a kernel is already attached to this buffer", vim.log.levels.WARN)
		return
	end
	local Kernel = require("jupyter_core").Kernel
	local kernel = Kernel.start(spec_name)
	registry.set(bufnr, kernel)
	if cfg().virtual_lsp then
		lsp.attach(bufnr)
	end
end

---Prompt the user to pick a kernelspec when neither an argument nor a
---configured default is available.
---@param bufnr integer
local function prompt_and_start(bufnr)
	local kernel_spec = require("jupyter_core").KernelSpec
	local specs = kernel_spec.list()
	if #specs == 0 then
		vim.notify("jupyter: no kernelspecs available", vim.log.levels.ERROR)
		return
	end
	vim.ui.select(specs, {
		prompt = "Select Jupyter kernel:",
		---@param item jupyter_core.KernelSpec
		format_item = function(item)
			return ("%s (%s)"):format(item.display_name, item.name)
		end,
	}, function(choice)
		if choice == nil then
			return
		end
		start_with_spec(choice.name, bufnr)
	end)
end

---Start a kernel for the current buffer. If `spec_name` omitted, uses
---``config.default_kernel``; if that's also nil, prompts via
---``vim.ui.select`` with the result of ``KernelSpec.list()``.
---@param spec_name string?
function M.start_kernel(spec_name)
	local bufnr = current_buf()
	if spec_name ~= nil and spec_name ~= "" then
		start_with_spec(spec_name, bufnr)
		return
	end
	local default = cfg().default_kernel
	if default ~= nil and default ~= "" then
		start_with_spec(default, bufnr)
		return
	end
	prompt_and_start(bufnr)
end

function M.stop_kernel()
	local bufnr = current_buf()
	local kernel = get_kernel(bufnr)
	if kernel == nil then
		vim.notify("jupyter: no kernel attached to this buffer", vim.log.levels.WARN)
		return
	end
	kernel:stop()
	registry.clear(bufnr)
	display.clear_all(bufnr)
	lsp.detach(bufnr)
end

function M.restart_kernel()
	local bufnr = current_buf()
	local kernel = get_kernel(bufnr)
	if kernel == nil then
		vim.notify("jupyter: no kernel attached to this buffer", vim.log.levels.WARN)
		return
	end
	kernel:restart()
	display.clear_all(bufnr)
end

function M.execute_cell()
	execute.execute_cell(current_buf(), nil)
end

function M.execute_all()
	execute.execute_all(current_buf())
end

function M.clear_cell()
	execute.clear_cell(current_buf(), nil)
end

function M.clear_all_outputs()
	display.clear_all(current_buf())
end

function M.next_cell()
	local bufnr = current_buf()
	cell.next_cell(bufnr, win_for_buf(bufnr))
end

function M.prev_cell()
	local bufnr = current_buf()
	cell.prev_cell(bufnr, win_for_buf(bufnr))
end

---@param winid integer
---@return integer
local function cursor_row(winid)
	return vim.api.nvim_win_get_cursor(winid)[1] - 1
end

---@param position jupyter.CellPosition
---@param cell_type jupyter.CellType?
local function insert_cell(position, cell_type)
	local bufnr = current_buf()
	local winid = win_for_buf(bufnr)
	local row = cursor_row(winid)
	if cell.get_cell_at(bufnr, row) == nil then
		vim.notify(
			("jupyter: cannot insert cell — cursor is in the preamble (row %d)"):format(row),
			vim.log.levels.WARN
		)
		return
	end
	local target = cell.insert_cell(bufnr, row, position, cell_type or "code")
	vim.api.nvim_win_set_cursor(winid, { target + 1, 0 })
end

---@param cell_type jupyter.CellType?
function M.insert_cell_below(cell_type)
	insert_cell("below", cell_type)
end

---@param cell_type jupyter.CellType?
function M.insert_cell_above(cell_type)
	insert_cell("above", cell_type)
end

function M.delete_cell()
	local bufnr = current_buf()
	local winid = win_for_buf(bufnr)
	cell.delete_cell(bufnr, cursor_row(winid))
end

function M.merge_with_prev()
	local bufnr = current_buf()
	local winid = win_for_buf(bufnr)
	cell.merge_with_prev(bufnr, cursor_row(winid))
end

function M.split_at_cursor()
	local bufnr = current_buf()
	local winid = win_for_buf(bufnr)
	cell.split_at(bufnr, cursor_row(winid))
end

function M.hover()
	hover_mod.hover(current_buf())
end

---@type {name: string, fn: fun(args: table), opts: table}[]
local USER_COMMANDS = {
	{
		name = "JupyterStart",
		fn = function(args)
			M.start_kernel(args.fargs[1])
		end,
		opts = {
			nargs = "?",
			complete = function()
				local kernel_spec = require("jupyter_core").KernelSpec
				return vim.tbl_map(function(s)
					return s.name
				end, kernel_spec.list())
			end,
			desc = "Start a Jupyter kernel for the current buffer",
		},
	},
	{
		name = "JupyterStop",
		fn = function()
			M.stop_kernel()
		end,
		opts = { desc = "Stop the buffer's Jupyter kernel" },
	},
	{
		name = "JupyterRestart",
		fn = function()
			M.restart_kernel()
		end,
		opts = { desc = "Restart the buffer's Jupyter kernel" },
	},
	{
		name = "JupyterExecute",
		fn = function()
			M.execute_cell()
		end,
		opts = { desc = "Execute the cell at the cursor" },
	},
	{
		name = "JupyterExecuteAll",
		fn = function()
			M.execute_all()
		end,
		opts = { desc = "Execute every cell in the buffer in order" },
	},
	{
		name = "JupyterClear",
		fn = function()
			M.clear_cell()
		end,
		opts = { desc = "Clear the output of the cell at the cursor" },
	},
	{
		name = "JupyterClearAll",
		fn = function()
			M.clear_all_outputs()
		end,
		opts = { desc = "Clear every cell output in the buffer" },
	},
	{
		name = "JupyterNext",
		fn = function()
			M.next_cell()
		end,
		opts = { desc = "Move cursor to the next cell" },
	},
	{
		name = "JupyterPrev",
		fn = function()
			M.prev_cell()
		end,
		opts = { desc = "Move cursor to the previous cell" },
	},
	{
		name = "JupyterInsertBelow",
		fn = function()
			M.insert_cell_below()
		end,
		opts = { desc = "Insert a new cell below the current cell" },
	},
	{
		name = "JupyterInsertAbove",
		fn = function()
			M.insert_cell_above()
		end,
		opts = { desc = "Insert a new cell above the current cell" },
	},
	{
		name = "JupyterHover",
		fn = function()
			M.hover()
		end,
		opts = { desc = "Show kernel-backed hover for the symbol under the cursor" },
	},
}

---@type {lhs: string, rhs: string, mode: string|string[], desc: string}[]
local DEFAULT_KEYMAPS = {
	{ lhs = "<localleader>jx", rhs = "<Cmd>JupyterExecute<CR>", mode = "n", desc = "Jupyter: execute cell" },
	{ lhs = "<localleader>jX", rhs = "<Cmd>JupyterExecuteAll<CR>", mode = "n", desc = "Jupyter: execute all cells" },
	{ lhs = "<localleader>jc", rhs = "<Cmd>JupyterClear<CR>", mode = "n", desc = "Jupyter: clear cell output" },
	{ lhs = "<localleader>jn", rhs = "<Cmd>JupyterNext<CR>", mode = "n", desc = "Jupyter: next cell" },
	{ lhs = "<localleader>jp", rhs = "<Cmd>JupyterPrev<CR>", mode = "n", desc = "Jupyter: previous cell" },
	{ lhs = "<localleader>jo", rhs = "<Cmd>JupyterInsertBelow<CR>", mode = "n", desc = "Jupyter: insert cell below" },
	{ lhs = "<localleader>jO", rhs = "<Cmd>JupyterInsertAbove<CR>", mode = "n", desc = "Jupyter: insert cell above" },
	{ lhs = "K", rhs = "<Cmd>JupyterHover<CR>", mode = "n", desc = "Jupyter: hover" },
}

local function register_user_commands()
	for _, cmd in ipairs(USER_COMMANDS) do
		vim.api.nvim_create_user_command(cmd.name, cmd.fn, cmd.opts)
	end
end

local DEFAULT_KEYMAPS_AUGROUP = "jupyter.default_keymaps"

local function install_default_keymaps()
	local group = vim.api.nvim_create_augroup(DEFAULT_KEYMAPS_AUGROUP, { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "python",
		callback = function(ev)
			for _, m in ipairs(DEFAULT_KEYMAPS) do
				vim.keymap.set(m.mode, m.lhs, m.rhs, {
					buffer = ev.buf,
					silent = true,
					desc = m.desc,
				})
			end
		end,
	})
end

---Initialize the plugin. Safe to call multiple times — the most recent
---options win, user commands re-register harmlessly, and the
---default-keymap autocmd group is cleared between calls.
---@param opts jupyter.Config?
function M.setup(opts)
	M._cfg = config.merge(opts)
	display.setup(M._cfg.display)
	if M._cfg.create_user_commands then
		register_user_commands()
	end
	if M._cfg.create_default_keymaps then
		install_default_keymaps()
	end
end

return M
