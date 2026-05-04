---Cell detection for Python percent-format buffers.
---
---Cells are delimited by `# %%` (code) or `# %% [markdown]` markers.
---The marker line is the first line of the cell it introduces, and
---each cell extends up to (but not including) the next marker line —
---or the end of the buffer when no further marker exists.
---
---Lines preceding the first marker (the preamble) belong to no cell,
---matching the convention used by VS Code's interactive window and
---Jupytext.

local M = {}

local LANG = "python"
local QUERY_NAME = "jupyter"

---@class jupyter.Cell
---@field cell_type "code"|"markdown"
---@field start_row integer  0-indexed, inclusive
---@field end_row integer    0-indexed, exclusive
---@field source string[]    buffer lines in [start_row, end_row)

---@class jupyter.cell.Marker
---@field row integer        0-indexed row of the marker comment
---@field is_markdown boolean

---Collect every cell-marker comment in the buffer in source order.
---@param bufnr integer
---@return jupyter.cell.Marker[]
local function collect_markers(bufnr)
	local query = vim.treesitter.query.get(LANG, QUERY_NAME)
	if query == nil then
		error(("jupyter: queries/%s/%s.scm not found in runtimepath"):format(LANG, QUERY_NAME))
	end

	local parser = vim.treesitter.get_parser(bufnr, LANG)
	local tree = parser:parse()[1]
	local root = tree:root()

	-- A markdown comment matches both `@cell.marker` and `@cell.markdown`
	-- patterns, so we deduplicate by row and OR the markdown flag.
	---@type table<integer, jupyter.cell.Marker>
	local by_row = {}
	for id, node in query:iter_captures(root, bufnr, 0, -1) do
		local name = query.captures[id]
		local row = node:start()
		local entry = by_row[row]
		if entry == nil then
			entry = { row = row, is_markdown = false }
			by_row[row] = entry
		end
		if name == "cell.markdown" then
			entry.is_markdown = true
		end
	end

	---@type jupyter.cell.Marker[]
	local markers = {}
	for _, entry in pairs(by_row) do
		table.insert(markers, entry)
	end
	table.sort(markers, function(a, b)
		return a.row < b.row
	end)
	return markers
end

---@param bufnr integer
---@param marker jupyter.cell.Marker
---@param end_row integer
---@return jupyter.Cell
local function make_cell(bufnr, marker, end_row)
	return {
		cell_type = marker.is_markdown and "markdown" or "code",
		start_row = marker.row,
		end_row = end_row,
		source = vim.api.nvim_buf_get_lines(bufnr, marker.row, end_row, false),
	}
end

---Return every cell in the buffer in source order.
---
---When the buffer has no `# %%` markers, a single implicit code cell
---spanning the entire buffer is returned. Trailing lines after the
---last marker remain inside that last cell.
---@param bufnr integer
---@return jupyter.Cell[]
function M.get_all_cells(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local markers = collect_markers(bufnr)

	if #markers == 0 then
		return {
			{
				cell_type = "code",
				start_row = 0,
				end_row = line_count,
				source = vim.api.nvim_buf_get_lines(bufnr, 0, line_count, false),
			},
		}
	end

	---@type jupyter.Cell[]
	local cells = {}
	for i, marker in ipairs(markers) do
		local next_marker = markers[i + 1]
		local end_row = next_marker and next_marker.row or line_count
		cells[#cells + 1] = make_cell(bufnr, marker, end_row)
	end
	return cells
end

---Return the cell containing the given 0-indexed row, or nil when
---the row falls in the preamble before the first marker.
---@param bufnr integer
---@param row integer
---@return jupyter.Cell?
function M.get_cell_at(bufnr, row)
	for _, cell in ipairs(M.get_all_cells(bufnr)) do
		if row >= cell.start_row and row < cell.end_row then
			return cell
		end
	end
	return nil
end

return M
