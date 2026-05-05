---Virtual-text rendering of kernel outputs and execution status.
---
---Outputs are placed below the cell's last line via `virt_lines`,
---and a status indicator is placed at the cell's marker line via
---right-of-line `virt_text`. The buffer's text is never modified.

local M = {}

---@class jupyter.display.Config
---@field max_lines? integer
---@field truncation_hint? string
---@field hl_group? string
---@field status_hl? table<string, string>

---@class jupyter.display.ResolvedConfig
---@field max_lines integer
---@field truncation_hint string
---@field hl_group string
---@field status_hl table<string, string>

---@type jupyter.display.ResolvedConfig
local config = {
	max_lines = 20,
	truncation_hint = "+ %d more lines",
	hl_group = "Comment",
	status_hl = {
		starting = "DiagnosticHint",
		idle = "DiagnosticHint",
		busy = "DiagnosticInfo",
		error = "DiagnosticError",
	},
}

local NS = vim.api.nvim_create_namespace("jupyter.display")

---@class jupyter.display.CellEntry
---@field anchor_id integer        -- extmark anchored at the cell's marker row
---@field output_ids integer[]     -- ids of virt_lines marks below the cell
---@field status_id integer?       -- id of the eol status mark, when set

---Per-buffer list of live cell entries. Looked up by resolving each
---anchor's current row and matching against the requested cell.
---@type table<integer, jupyter.display.CellEntry[]>
local state = {}

---Strip ANSI CSI escape sequences (e.g. color codes) from `s`.
---@param s string
---@return string
local function strip_ansi(s)
	local stripped = (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
	return stripped
end

---Render an output value into a flat list of plain-text lines.
---Phase 1 only handles `text/plain`; the dispatch shape leaves room
---for MIME-aware renderers in Phase 2.
---@param output jupyter_core.Output
---@return string[]
local function render_output(output)
	---@type string[]
	local lines = {}

	for _, line in ipairs(output.text) do
		lines[#lines + 1] = strip_ansi(line)
	end

	if #lines == 0 then
		local plain = output.data["text/plain"]
		if type(plain) == "string" and plain ~= "" then
			for _, line in ipairs(vim.split(plain, "\n", { plain = true })) do
				lines[#lines + 1] = strip_ansi(line)
			end
		end
	end

	if output.output_type == "error" then
		-- Errors may carry an extra traceback string on data even when
		-- output.text is already populated. Append anything we find.
		local extra = output.data["traceback"] or output.data["application/vnd.jupyter.stderr"]
		if type(extra) == "string" and extra ~= "" then
			for _, line in ipairs(vim.split(extra, "\n", { plain = true })) do
				lines[#lines + 1] = strip_ansi(line)
			end
		end
	end

	return lines
end

---@param bufnr integer
---@param row integer
---@return jupyter.display.CellEntry?
local function find_entry(bufnr, row)
	local entries = state[bufnr]
	if entries == nil then
		return nil
	end
	for _, entry in ipairs(entries) do
		local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, NS, entry.anchor_id, {})
		if ok and pos[1] == row then
			return entry
		end
	end
	return nil
end

---@param bufnr integer
---@param cell jupyter.Cell
---@return jupyter.display.CellEntry
local function ensure_entry(bufnr, cell)
	local existing = find_entry(bufnr, cell.start_row)
	if existing ~= nil then
		return existing
	end
	state[bufnr] = state[bufnr] or {}
	local anchor_id = vim.api.nvim_buf_set_extmark(bufnr, NS, cell.start_row, 0, {})
	---@type jupyter.display.CellEntry
	local entry = { anchor_id = anchor_id, output_ids = {}, status_id = nil }
	table.insert(state[bufnr], entry)
	return entry
end

---@param bufnr integer
---@param entry jupyter.display.CellEntry
local function clear_output_marks(bufnr, entry)
	for _, id in ipairs(entry.output_ids) do
		pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, id)
	end
	entry.output_ids = {}
end

---Set or merge the global config. Idempotent.
---@param cfg jupyter.display.Config?
function M.setup(cfg)
	if cfg == nil then
		return
	end
	if cfg.max_lines ~= nil then
		config.max_lines = cfg.max_lines
	end
	if cfg.truncation_hint ~= nil then
		config.truncation_hint = cfg.truncation_hint
	end
	if cfg.hl_group ~= nil then
		config.hl_group = cfg.hl_group
	end
	if cfg.status_hl ~= nil then
		for k, v in pairs(cfg.status_hl) do
			config.status_hl[k] = v
		end
	end
end

---Render `outputs` for `cell` in `bufnr`. Replaces any prior output
---marks for this cell. Safe to call repeatedly.
---@param bufnr integer
---@param cell jupyter.Cell
---@param outputs jupyter_core.Output[]
function M.show_output(bufnr, cell, outputs)
	local entry = ensure_entry(bufnr, cell)
	clear_output_marks(bufnr, entry)

	---@type string[]
	local lines = {}
	for _, output in ipairs(outputs) do
		for _, line in ipairs(render_output(output)) do
			lines[#lines + 1] = line
		end
	end

	local dropped = 0
	if #lines > config.max_lines then
		dropped = #lines - config.max_lines
		for _ = 1, dropped do
			table.remove(lines)
		end
	end

	---@type {[1]:string,[2]:string}[][]
	local virt_lines = {}
	for _, line in ipairs(lines) do
		virt_lines[#virt_lines + 1] = { { line, config.hl_group } }
	end
	if dropped > 0 then
		virt_lines[#virt_lines + 1] = {
			{ config.truncation_hint:format(dropped), config.hl_group },
		}
	end

	if #virt_lines == 0 then
		return
	end

	local anchor_row = math.max(cell.end_row - 1, cell.start_row)
	local id = vim.api.nvim_buf_set_extmark(bufnr, NS, anchor_row, 0, {
		virt_lines = virt_lines,
	})
	entry.output_ids[#entry.output_ids + 1] = id
end

---Show a status indicator on the cell's marker line. Replaces any
---prior status mark for this cell.
---@param bufnr integer
---@param cell jupyter.Cell
---@param status "starting"|"idle"|"busy"|"error"
function M.set_status(bufnr, cell, status)
	local entry = ensure_entry(bufnr, cell)
	if entry.status_id ~= nil then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, entry.status_id)
		entry.status_id = nil
	end
	local hl = config.status_hl[status] or config.hl_group
	local id = vim.api.nvim_buf_set_extmark(bufnr, NS, cell.start_row, 0, {
		virt_text = { { "[" .. status .. "]", hl } },
		virt_text_pos = "eol",
	})
	entry.status_id = id
end

---Clear output marks (but not the status mark) for a single cell.
---@param bufnr integer
---@param cell jupyter.Cell
function M.clear_output(bufnr, cell)
	local entry = find_entry(bufnr, cell.start_row)
	if entry == nil then
		return
	end
	clear_output_marks(bufnr, entry)
end

---Clear all display marks (output + status + anchors) for `bufnr`.
---@param bufnr integer
function M.clear_all(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
	state[bufnr] = nil
end

return M
