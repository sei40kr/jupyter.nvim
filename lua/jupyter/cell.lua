---Cell detection for percent-format buffers.
---
---Cells are delimited by `# %%` (code) or `# %% [markdown]` markers.
---The marker line is the first line of the cell it introduces, and
---each cell extends up to (but not including) the next marker line —
---or the end of the buffer when no further marker exists.
---
---Lines preceding the first marker (the preamble) belong to no cell,
---matching the convention used by VS Code's interactive window and
---Jupytext.
---
---Supported filetypes are listed in `FILETYPE_TO_LANG`; each maps to
---the tree-sitter language whose `queries/<lang>/jupyter.scm` query
---captures the cell markers.

local M = {}

local QUERY_NAME = "jupyter"

---@type table<string, string>
local FILETYPE_TO_LANG = {
	python = "python",
	julia = "julia",
	r = "r",
}

---Tree-sitter language for `bufnr`'s filetype, or nil when unsupported.
---@param bufnr integer
---@return string?
local function lang_for_buf(bufnr)
	local ft = vim.bo[bufnr].filetype
	return FILETYPE_TO_LANG[ft]
end

---@return string[]
function M.supported_filetypes()
	return vim.tbl_keys(FILETYPE_TO_LANG)
end

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
	local lang = lang_for_buf(bufnr)
	if lang == nil then
		error(("jupyter: filetype %q is not supported"):format(vim.bo[bufnr].filetype))
	end

	local query = vim.treesitter.query.get(lang, QUERY_NAME)
	if query == nil then
		error(("jupyter: queries/%s/%s.scm not found in runtimepath"):format(lang, QUERY_NAME))
	end

	local parser = vim.treesitter.get_parser(bufnr, lang)
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

---@alias jupyter.CellPosition "above"|"below"
---@alias jupyter.CellType "code"|"markdown"

---@type table<jupyter.CellType, string>
local MARKER_TEXT = {
	code = "# %%",
	markdown = "# %% [markdown]",
}

---@param bufnr integer
---@param row integer
---@return string
local function get_line(bufnr, row)
	local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
	return lines[1] or ""
end

---Locate the first non-whitespace line within the cell body. Falls back
---to the line right after the marker, or to the marker itself when the
---cell has no body.
---@param bufnr integer
---@param cell jupyter.Cell
---@return integer
local function first_content_row(bufnr, cell)
	if cell.start_row + 1 >= cell.end_row then
		return cell.start_row
	end
	for r = cell.start_row + 1, cell.end_row - 1 do
		if get_line(bufnr, r):match("%S") then
			return r
		end
	end
	return cell.start_row + 1
end

---@param winid integer
---@param row integer
local function place_cursor(winid, row)
	vim.api.nvim_win_set_cursor(winid, { row + 1, 0 })
end

---Move cursor to the start of the next code/markdown cell.
---Returns true if moved.
---@param bufnr integer
---@param winid integer
---@return boolean
function M.next_cell(bufnr, winid)
	local cur = vim.api.nvim_win_get_cursor(winid)[1] - 1
	for _, c in ipairs(M.get_all_cells(bufnr)) do
		if c.start_row > cur then
			place_cursor(winid, first_content_row(bufnr, c))
			return true
		end
	end
	return false
end

---Symmetric to next_cell.
---@param bufnr integer
---@param winid integer
---@return boolean
function M.prev_cell(bufnr, winid)
	local cur = vim.api.nvim_win_get_cursor(winid)[1] - 1
	---@type jupyter.Cell?
	local target = nil
	for _, c in ipairs(M.get_all_cells(bufnr)) do
		if c.end_row <= cur then
			target = c
		else
			break
		end
	end
	if target == nil then
		return false
	end
	place_cursor(winid, first_content_row(bufnr, target))
	return true
end

---Insert a new empty cell relative to the cell at `row`.
---Returns the row of the new cell's first content line.
---@param bufnr integer
---@param row integer
---@param position jupyter.CellPosition
---@param cell_type jupyter.CellType
---@return integer
function M.insert_cell(bufnr, row, position, cell_type)
	local marker = MARKER_TEXT[cell_type]
	if marker == nil then
		error(("jupyter.cell: unknown cell_type %q"):format(tostring(cell_type)))
	end
	local cell = M.get_cell_at(bufnr, row)
	if cell == nil then
		error(("jupyter.cell: no cell at row %d"):format(row))
	end

	local insert_at
	if position == "above" then
		insert_at = cell.start_row
	elseif position == "below" then
		insert_at = cell.end_row
	else
		error(("jupyter.cell: unknown position %q"):format(tostring(position)))
	end

	local block = { marker, "" }
	local lead_blank = false
	if insert_at > 0 and get_line(bufnr, insert_at - 1) ~= "" then
		table.insert(block, 1, "")
		lead_blank = true
	end

	vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, block)
	local marker_row = insert_at + (lead_blank and 1 or 0)
	return marker_row + 1
end

---Delete the cell containing `row` (marker + body). Any run of blank
---lines ending at the deletion site is collapsed to a single blank.
---@param bufnr integer
---@param row integer
function M.delete_cell(bufnr, row)
	local cell = M.get_cell_at(bufnr, row)
	if cell == nil then
		error(("jupyter.cell: no cell at row %d"):format(row))
	end
	vim.api.nvim_buf_set_lines(bufnr, cell.start_row, cell.end_row, false, {})

	local first_blank = cell.start_row
	while first_blank > 0 and get_line(bufnr, first_blank - 1) == "" do
		first_blank = first_blank - 1
	end
	if cell.start_row - first_blank > 1 then
		vim.api.nvim_buf_set_lines(bufnr, first_blank + 1, cell.start_row, false, {})
	end
end

---Merge the cell containing `row` into the previous cell (drop this
---cell's marker, keep its body). Cell types must match.
---@param bufnr integer
---@param row integer
function M.merge_with_prev(bufnr, row)
	local cells = M.get_all_cells(bufnr)
	---@type integer?
	local idx = nil
	for i, c in ipairs(cells) do
		if row >= c.start_row and row < c.end_row then
			idx = i
			break
		end
	end
	if idx == nil then
		error(("jupyter.cell: no cell at row %d"):format(row))
	end
	if idx == 1 then
		error("jupyter.cell: no previous cell to merge with")
	end
	local cur = cells[idx]
	local prev = cells[idx - 1]
	if cur.cell_type ~= prev.cell_type then
		error(("jupyter.cell: cannot merge %s cell into %s cell"):format(cur.cell_type, prev.cell_type))
	end
	vim.api.nvim_buf_set_lines(bufnr, cur.start_row, cur.start_row + 1, false, {})
end

---Split the current cell at `row`, inserting a new marker of the same
---type at that row. The line at `row` becomes the first line of the
---new cell.
---@param bufnr integer
---@param row integer
function M.split_at(bufnr, row)
	local cell = M.get_cell_at(bufnr, row)
	if cell == nil then
		error(("jupyter.cell: no cell at row %d"):format(row))
	end
	if row == cell.start_row then
		error("jupyter.cell: cannot split on the cell's marker line")
	end
	vim.api.nvim_buf_set_lines(bufnr, row, row, false, { MARKER_TEXT[cell.cell_type] })
end

---Return inclusive (start_row, end_row) for the cell at `row`.
---For `inner`, exclude the marker line. For `outer`, include it.
---@param bufnr integer
---@param row integer
---@param scope "inner"|"outer"
---@return integer, integer
function M.cell_range(bufnr, row, scope)
	local cell = M.get_cell_at(bufnr, row)
	if cell == nil then
		error(("jupyter.cell: no cell at row %d"):format(row))
	end
	if scope == "outer" then
		return cell.start_row, cell.end_row - 1
	elseif scope == "inner" then
		return cell.start_row + 1, cell.end_row - 1
	end
	error(("jupyter.cell: unknown scope %q"):format(tostring(scope)))
end

return M
