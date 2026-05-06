---Pure conversion between an ordered list of source-only cells and the
---percent-format text representation used by jupyter.nvim's buffers.
---
---Phase 1 supports python, julia, and r. All three use ``#`` as the
---line-comment character, so a single set of marker strings and prefix
---rules works uniformly.
---
---Trailing blank lines on a parsed cell are dropped: they round-trip
---ambiguously with the visual blank line that ``cells_to_lines`` inserts
---between adjacent cells, and an unconditional trim keeps the conversion
---stable across save/reload cycles.

local M = {}

---@class jupyter.format.SourceCell
---@field cell_type "code"|"markdown"
---@field source string[]   body lines, no marker, no comment prefix

---@type table<jupyter.CellType, string>
local MARKER_TEXT = {
	code = "# %%",
	markdown = "# %% [markdown]",
}

---Strip the ``#`` line-comment prefix that wraps markdown content in
---percent format. ``#`` (and the empty string) decode to an empty line;
---``# foo`` decodes to ``foo``; lines that do not match the prefix are
---returned verbatim.
---@param line string
---@return string
local function strip_md_prefix(line)
	if line == "" or line == "#" then
		return ""
	end
	local content = line:match("^# (.*)$")
	if content ~= nil then
		return content
	end
	return line
end

---Wrap a markdown body line in the ``#`` line-comment prefix used by
---percent format. Empty lines become ``#`` so they survive a round-trip.
---@param line string
---@return string
local function add_md_prefix(line)
	if line == "" then
		return "#"
	end
	return "# " .. line
end

---Convert an ordered list of source-only cells into percent-format
---buffer lines. Adjacent cells are separated by a single blank line.
---@param cells jupyter.format.SourceCell[]
---@return string[]
function M.cells_to_lines(cells)
	---@type string[]
	local lines = {}
	for i, cell in ipairs(cells) do
		if i > 1 then
			lines[#lines + 1] = ""
		end
		lines[#lines + 1] = MARKER_TEXT[cell.cell_type]
		if cell.cell_type == "markdown" then
			for _, src_line in ipairs(cell.source) do
				lines[#lines + 1] = add_md_prefix(src_line)
			end
		else
			for _, src_line in ipairs(cell.source) do
				lines[#lines + 1] = src_line
			end
		end
	end
	return lines
end

---Pattern for the percent-format cell marker. Matches both ``# %%`` and
---``# %% [markdown]`` regardless of leading whitespace inside the
---comment, mirroring the tree-sitter query in ``queries/<lang>/jupyter.scm``.
local MARKER_PATTERN = "^#%s*%%%%"

---Decode a ``jupyter.Cell`` into a source-only cell. The marker line is
---dropped (when present), markdown bodies are unwrapped, and trailing
---blank lines — which ``cells_to_lines`` uses as visual separators — are
---trimmed.
---
---Implicit cells (a buffer with no markers, surfaced by
---``cell.get_all_cells`` as a single cell whose first line is content)
---are handled by checking ``cell.source[1]`` against the marker pattern;
---if it does not match, no line is dropped.
---@param cell jupyter.Cell
---@return jupyter.format.SourceCell
function M.from_cell(cell)
	local first = cell.source[1]
	local has_marker = first ~= nil and first:match(MARKER_PATTERN) ~= nil
	local start = has_marker and 2 or 1

	---@type string[]
	local source = {}
	for i = start, #cell.source do
		if cell.cell_type == "markdown" then
			source[i - start + 1] = strip_md_prefix(cell.source[i])
		else
			source[i - start + 1] = cell.source[i]
		end
	end
	while #source > 0 and source[#source] == "" do
		source[#source] = nil
	end
	return { cell_type = cell.cell_type, source = source }
end

return M
