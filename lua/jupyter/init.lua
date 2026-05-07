---Public entry point for the editor module.
---
---``setup`` wires user options and (optionally) installs a small set of
---buffer-local keymaps in supported filetype buffers (see
---``cell.supported_filetypes``). Every command-shaped function lives on
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

---Per-filetype kernel selection. Each entry's `match` runs against the
---list returned by ``KernelSpec.list()`` and the first hit wins.
---@type table<string, fun(spec: jupyter_core.KernelSpec): boolean>[]
local KERNEL_DEFAULTS_BY_FILETYPE = {
	python = {
		function(spec)
			return spec.name == "python3"
		end,
		function(spec)
			return spec.language == "python"
		end,
	},
	julia = {
		function(spec)
			return spec.name == "julia"
		end,
		function(spec)
			return spec.name:match("^julia") ~= nil
		end,
		function(spec)
			return spec.language == "julia"
		end,
	},
	r = {
		function(spec)
			return spec.name == "ir"
		end,
		function(spec)
			return (spec.language or ""):lower() == "r"
		end,
	},
}

---Pick a kernelspec name based on `bufnr`'s filetype. Returns nil when
---no installed spec matches any of the rules.
---@param bufnr integer
---@return string?
local function default_kernel_for_filetype(bufnr)
	local rules = KERNEL_DEFAULTS_BY_FILETYPE[vim.bo[bufnr].filetype]
	if rules == nil then
		return nil
	end
	local kernel_spec = require("jupyter_core").KernelSpec
	local specs = kernel_spec.list()
	for _, predicate in ipairs(rules) do
		for _, spec in ipairs(specs) do
			if predicate(spec) then
				return spec.name
			end
		end
	end
	return nil
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

---Start a kernel for the current buffer. Resolution order:
---  1. explicit ``spec_name`` argument
---  2. ``config.default_kernel``
---  3. installed kernelspec matching the buffer's filetype
---  4. ``vim.ui.select`` prompt
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
	local ft_default = default_kernel_for_filetype(bufnr)
	if ft_default ~= nil then
		start_with_spec(ft_default, bufnr)
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

---@type {lhs: string, rhs: fun(), mode: string|string[], desc: string}[]
local DEFAULT_KEYMAPS = {
	{
		lhs = "<localleader>jx",
		rhs = function()
			M.execute_cell()
		end,
		mode = "n",
		desc = "Jupyter: execute cell",
	},
	{
		lhs = "<localleader>jX",
		rhs = function()
			M.execute_all()
		end,
		mode = "n",
		desc = "Jupyter: execute all cells",
	},
	{
		lhs = "<localleader>jc",
		rhs = function()
			M.clear_cell()
		end,
		mode = "n",
		desc = "Jupyter: clear cell output",
	},
	{
		lhs = "<localleader>jn",
		rhs = function()
			M.next_cell()
		end,
		mode = "n",
		desc = "Jupyter: next cell",
	},
	{
		lhs = "<localleader>jp",
		rhs = function()
			M.prev_cell()
		end,
		mode = "n",
		desc = "Jupyter: previous cell",
	},
	{
		lhs = "<localleader>jo",
		rhs = function()
			M.insert_cell_below()
		end,
		mode = "n",
		desc = "Jupyter: insert cell below",
	},
	{
		lhs = "<localleader>jO",
		rhs = function()
			M.insert_cell_above()
		end,
		mode = "n",
		desc = "Jupyter: insert cell above",
	},
	{
		lhs = "K",
		rhs = function()
			M.hover()
		end,
		mode = "n",
		desc = "Jupyter: hover",
	},
}

local DEFAULT_KEYMAPS_AUGROUP = "jupyter.default_keymaps"

local function install_default_keymaps()
	local group = vim.api.nvim_create_augroup(DEFAULT_KEYMAPS_AUGROUP, { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = cell.supported_filetypes(),
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
---options win and the default-keymap autocmd group is cleared between
---calls.
---@param opts jupyter.Config?
function M.setup(opts)
	M._cfg = config.merge(opts)
	display.setup(M._cfg.display)
	if M._cfg.create_default_keymaps then
		install_default_keymaps()
	end
end

return M
