---Cell execution orchestration.
---
---Glue between `jupyter.cell` (where the cell lives), `jupyter_core.Kernel`
---(how code is executed), and `jupyter.display` (how results are shown).
---Does not own kernel lifecycle: the buffer-local kernel must already be
---stored at `vim.b[bufnr].jupyter_kernel` (a `jupyter_core.Kernel`) by the
---caller — typically `jupyter.start_kernel`.

local cell_mod = require("jupyter.cell")
local display = require("jupyter.display")

local M = {}

---@param bufnr integer
---@return jupyter_core.Kernel?
local function get_kernel(bufnr)
	---@type jupyter_core.Kernel?
	local kernel = vim.b[bufnr].jupyter_kernel
	return kernel
end

---@param bufnr integer
---@param row integer?
---@return integer
local function resolve_row(bufnr, row)
	if row ~= nil then
		return row
	end
	local winid = vim.fn.bufwinid(bufnr)
	if winid == -1 then
		winid = vim.api.nvim_get_current_win()
	end
	return vim.api.nvim_win_get_cursor(winid)[1] - 1
end

---@param outputs jupyter_core.Output[]
---@return boolean
local function has_error(outputs)
	for _, out in ipairs(outputs) do
		if out.output_type == "error" then
			return true
		end
	end
	return false
end

---Execute a single cell. Returns true when the run finished without an
---error output, false otherwise. Returns nil when nothing was executed
---(no kernel, dead kernel, no cell at row).
---@param bufnr integer
---@param cell jupyter.Cell
---@param kernel jupyter_core.Kernel
---@return boolean
local function run_cell(bufnr, cell, kernel)
	display.set_status(bufnr, cell, "busy")
	local outputs = kernel:execute(table.concat(cell.source, "\n"))
	display.show_output(bufnr, cell, outputs)
	if has_error(outputs) then
		display.set_status(bufnr, cell, "error")
		return false
	end
	display.set_status(bufnr, cell, "idle")
	return true
end

---Execute the cell at the cursor (or at `row` if given) using the
---buffer-local kernel stored in `vim.b[bufnr].jupyter_kernel`.
---On success: status=busy → outputs rendered → status=idle.
---On error: status=error and the traceback is rendered as the cell's output.
---@param bufnr integer
---@param row integer?  -- 0-indexed; default: cursor row in current window
function M.execute_cell(bufnr, row)
	local kernel = get_kernel(bufnr)
	if kernel == nil then
		vim.notify("jupyter: no Jupyter kernel started for this buffer; run :JupyterStart", vim.log.levels.WARN)
		return
	end
	if kernel.state == "dead" then
		vim.notify("jupyter: kernel is dead; restart it before executing", vim.log.levels.ERROR)
		return
	end

	local target_row = resolve_row(bufnr, row)
	local cell = cell_mod.get_cell_at(bufnr, target_row)
	if cell == nil then
		vim.notify(("jupyter: no cell at row %d"):format(target_row), vim.log.levels.WARN)
		return
	end

	run_cell(bufnr, cell, kernel)
end

---Execute every cell in the buffer in order. Stops on the first error.
---@param bufnr integer
function M.execute_all(bufnr)
	local kernel = get_kernel(bufnr)
	if kernel == nil then
		vim.notify("jupyter: no Jupyter kernel started for this buffer; run :JupyterStart", vim.log.levels.WARN)
		return
	end
	if kernel.state == "dead" then
		vim.notify("jupyter: kernel is dead; restart it before executing", vim.log.levels.ERROR)
		return
	end

	for _, cell in ipairs(cell_mod.get_all_cells(bufnr)) do
		if cell.cell_type == "code" then
			local ok = run_cell(bufnr, cell, kernel)
			if not ok then
				vim.notify(("jupyter: execution halted at row %d"):format(cell.start_row), vim.log.levels.INFO)
				return
			end
		end
	end
end

---Clear the output marks for the cell at `row` (or cursor row).
---@param bufnr integer
---@param row integer?
function M.clear_cell(bufnr, row)
	local target_row = resolve_row(bufnr, row)
	local cell = cell_mod.get_cell_at(bufnr, target_row)
	if cell == nil then
		return
	end
	display.clear_output(bufnr, cell)
end

return M
