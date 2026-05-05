---Shared completion logic.
---
---Translates the cursor position in a buffer into a Jupyter
---``complete_request`` against the buffer's kernel and maps the
---kernel's matches into editor-agnostic ``jupyter.CompletionItem``s.
---Adapter modules (nvim-cmp, blink.cmp) wrap this with their own
---source-contract glue.

local cell_mod = require("jupyter.cell")

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

local M = {}

---@class jupyter.CompletionItem
---@field label string
---@field kind integer  LSP CompletionItemKind; defaults to Text
---@field detail string?
---@field range {start: integer, ["end"]: integer}  byte offsets within the cell

---Classify a completion match into an LSP CompletionItemKind.
---Heuristic: a trailing ``(`` marks a callable, all-caps marks a
---constant, otherwise we fall back to Variable.
---@param label string
---@return integer
function M._kind_for(label)
	if label:sub(-1) == "(" then
		return CompletionItemKind.Function
	end
	if label:match("^[%u_][%u%d_]*$") then
		return CompletionItemKind.Constant
	end
	return CompletionItemKind.Variable
end

---Byte offset of the cursor within the cell's source string.
---``code = table.concat(cell.source, "\n")`` joins lines with a single
---newline, so the offset is (sum of preceding line byte-lengths) +
---(line count - 1 newline separators) + cursor column.
---@param cell jupyter.Cell
---@param cursor_row integer  0-indexed buffer row
---@param cursor_col integer  0-indexed byte column
---@return integer
local function byte_offset_in_cell(cell, cursor_row, cursor_col)
	local local_row = cursor_row - cell.start_row
	local offset = 0
	for i = 1, local_row do
		offset = offset + #cell.source[i] + 1
	end
	return offset + cursor_col
end

---Return completion items for the cursor position, or nil when no
---kernel is attached or the cursor is outside any cell.
---@param bufnr integer
---@param winid integer
---@return jupyter.CompletionItem[]?, jupyter.Cell?
function M.complete_at_cursor(bufnr, winid)
	---@type jupyter_core.Kernel?
	local kernel = vim.b[bufnr].jupyter_kernel
	if kernel == nil then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local row = cursor[1] - 1
	local col = cursor[2]

	local cell = cell_mod.get_cell_at(bufnr, row)
	if cell == nil then
		return nil, nil
	end

	local code = table.concat(cell.source, "\n")
	local cursor_pos = byte_offset_in_cell(cell, row, col)

	local result = kernel:complete(code, cursor_pos)

	---@type jupyter.CompletionItem[]
	local items = {}
	local range = { start = result.cursor_start, ["end"] = result.cursor_end }
	for i, match in ipairs(result.matches) do
		items[i] = {
			label = match,
			kind = M._kind_for(match),
			range = range,
		}
	end
	return items, cell
end

return M
