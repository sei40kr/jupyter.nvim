---LSP-equivalent hover backed by the kernel's inspect_request.
---
---Resolves (code, cursor_pos) from the *current cell* — never the whole
---buffer — so symbols defined in earlier or later cells don't leak in.
---The kernel often returns ANSI-coloured plain text; we strip the
---escapes before handing the contents to Neovim's standard hover float.

local cell = require("jupyter.cell")
local registry = require("jupyter.registry")

local M = {}

---Strip ANSI CSI escape sequences (e.g. color codes) from `s`.
---@param s string
---@return string
local function strip_ansi(s)
	return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---Byte offset of (cursor_row, cursor_col) inside
---``table.concat(source, "\n")``. Lua's ``#`` returns byte length, so
---summing it across preceding lines is multibyte-safe; the cursor
---column is already a byte column (``nvim_win_get_cursor`` contract)
---and is clamped to the line length defensively.
---@param source string[]
---@param start_row integer    cell's first buffer row (0-indexed)
---@param cursor_row integer   buffer row (0-indexed)
---@param cursor_col integer   byte column (0-indexed)
---@return integer
local function byte_offset(source, start_row, cursor_row, cursor_col)
	local relative = cursor_row - start_row
	local offset = 0
	for i = 1, relative do
		offset = offset + #(source[i] or "") + 1
	end
	local cur_line = source[relative + 1] or ""
	local col = cursor_col
	if col > #cur_line then
		col = #cur_line
	end
	return offset + col
end

---Pick the best representation from an inspect_reply data bundle.
---Prefers ``text/markdown`` when present, otherwise ``text/plain``.
---@param data table<string, string>
---@return string body, string filetype
local function pick_representation(data)
	local md = data["text/markdown"]
	if type(md) == "string" and md ~= "" then
		return md, "markdown"
	end
	local plain = data["text/plain"]
	if type(plain) == "string" and plain ~= "" then
		return plain, "plaintext"
	end
	return "", "plaintext"
end

---Hover on the symbol under the cursor: ask the buffer-local kernel
---and render the response in Neovim's standard hover floating window.
---No-op (with a notify) when there is no kernel, no cell at the cursor,
---or the kernel reports no information.
---@param bufnr integer?  defaults to the current buffer
function M.hover(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local kernel = registry.get(bufnr)
	if kernel == nil then
		vim.notify("jupyter: no kernel attached to this buffer", vim.log.levels.WARN)
		return
	end

	local cur = vim.api.nvim_win_get_cursor(0)
	local cursor_row = cur[1] - 1
	local cursor_col = cur[2]

	local cur_cell = cell.get_cell_at(bufnr, cursor_row)
	if cur_cell == nil then
		vim.notify("jupyter: cursor is not inside a Jupyter cell", vim.log.levels.INFO)
		return
	end

	local code = table.concat(cur_cell.source, "\n")
	local cursor_pos = byte_offset(cur_cell.source, cur_cell.start_row, cursor_row, cursor_col)

	kernel:inspect_async(code, cursor_pos, function(err, result)
		if err ~= nil then
			vim.notify(("jupyter: inspect failed: %s"):format(err), vim.log.levels.WARN)
			return
		end
		if result == nil or not result.found then
			vim.notify("jupyter: no information available", vim.log.levels.INFO)
			return
		end

		local body, filetype = pick_representation(result.data)
		if body == "" then
			vim.notify("jupyter: no information available", vim.log.levels.INFO)
			return
		end

		local stripped = strip_ansi(body)
		local lines = vim.split(stripped, "\n", { plain = true })
		vim.lsp.util.open_floating_preview(lines, filetype, { border = "rounded" })
	end)
end

return M
