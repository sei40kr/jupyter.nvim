---nvim-cmp source backed by the Jupyter kernel's complete_request.
---
---Translates ``params.context.cursor`` into a kernel completion
---and feeds the matches back to nvim-cmp as ``textEdit`` items so
---the byte ranges from the kernel are honoured verbatim.

local completion = require("jupyter.completion")
local registry = require("jupyter.registry")

---@class jupyter.completion.cmp.Source
---@field private _name string
local source = {}
source.__index = source

---@return jupyter.completion.cmp.Source
function source.new()
	return setmetatable({ _name = "jupyter" }, source)
end

---@return string
function source:get_debug_name()
	return self._name
end

---nvim-cmp checks this before each completion request. We are only
---available when the buffer has a live kernel and the cursor sits
---inside a cell.
---@return boolean
function source:is_available()
	local bufnr = vim.api.nvim_get_current_buf()
	if registry.get(bufnr) == nil then
		return false
	end
	local winid = vim.api.nvim_get_current_win()
	local row = vim.api.nvim_win_get_cursor(winid)[1] - 1
	return require("jupyter.cell").get_cell_at(bufnr, row) ~= nil
end

---Python identifiers plus dotted access; ``[`` is a trigger character
---rather than part of the keyword.
---@return string
function source:get_keyword_pattern()
	return [[\%([a-zA-Z_]\w*\.\)*[a-zA-Z_]\w*]]
end

---@return string[]
function source:get_trigger_characters()
	return { ".", "[" }
end

---@class jupyter.completion.cmp.Params
---@field context {cursor: {row: integer, col: integer}, bufnr: integer}

---@param params jupyter.completion.cmp.Params
---@param callback fun(response: {items: table[], isIncomplete: boolean})
function source:complete(params, callback)
	local bufnr = params.context.bufnr or vim.api.nvim_get_current_buf()
	local winid = vim.api.nvim_get_current_win()

	local items, _ = completion.complete_at_cursor(bufnr, winid)
	if items == nil then
		callback({ items = {}, isIncomplete = false })
		return
	end

	local line = params.context.cursor.row - 1
	---@type table[]
	local cmp_items = {}
	for i, item in ipairs(items) do
		cmp_items[i] = {
			label = item.label,
			kind = item.kind,
			detail = item.detail,
			textEdit = {
				range = {
					start = { line = line, character = item.range.start },
					["end"] = { line = line, character = item.range["end"] },
				},
				newText = item.label,
			},
		}
	end
	callback({ items = cmp_items, isIncomplete = false })
end

---Convenience: register this source with nvim-cmp.
---No-op when nvim-cmp is not installed so users can require this
---module unconditionally during plugin setup.
function source.register()
	local ok, cmp = pcall(require, "cmp")
	if not ok then
		return
	end
	cmp.register_source("jupyter", source.new())
end

return source
