---blink.cmp provider backed by the Jupyter kernel's complete_request.
---
---Translates ``ctx.cursor`` into a kernel completion via the shared
---``jupyter.completion.complete_at_cursor`` helper and feeds the
---matches back to blink.cmp as ``textEdit`` items so the byte ranges
---from the kernel are honoured verbatim.

local completion = require("jupyter.completion")
local registry = require("jupyter.registry")

local M = {}

---@class jupyter.completion.blink.Provider
local Provider = {}
Provider.__index = Provider

---@param _opts table?
---@return jupyter.completion.blink.Provider
---@diagnostic disable-next-line: unused-local
function M.new(_opts)
	return setmetatable({}, Provider)
end

---blink.cmp checks this before each completion request. We are only
---available when the buffer has a live kernel attached.
---@param ctx table?  blink context (may be nil during early checks)
---@return boolean
function Provider:enabled(ctx)
	local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
	return registry.get(bufnr) ~= nil
end

---@return string[]
function Provider:get_trigger_characters()
	return { ".", "[" }
end

---@class jupyter.completion.blink.Response
---@field items table[]
---@field is_incomplete_forward boolean
---@field is_incomplete_backward boolean

---blink.cmp completion entry point.
---@param ctx table  blink context with at least ``bufnr`` and ``cursor`` ({row, col})
---@param callback fun(response: jupyter.completion.blink.Response)
function Provider:get_completions(ctx, callback)
	local empty = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }

	local ok, items_or_err = pcall(function()
		local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
		local winid = vim.api.nvim_get_current_win()

		local items, _ = completion.complete_at_cursor(bufnr, winid)
		if items == nil then
			return nil
		end

		local line = ctx.cursor[1] - 1
		---@type table[]
		local blink_items = {}
		for i, item in ipairs(items) do
			blink_items[i] = {
				label = item.label,
				kind = item.kind,
				insertText = item.label,
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
		return blink_items
	end)

	if not ok or items_or_err == nil then
		callback(empty)
		return
	end

	callback({
		items = items_or_err,
		is_incomplete_forward = false,
		is_incomplete_backward = false,
	})
end

---Convenience: register this provider with blink.cmp.
---No-op when blink.cmp is not installed so users can require this
---module unconditionally during plugin setup.
function M.register()
	local ok, blink = pcall(require, "blink.cmp")
	if not ok then
		return
	end
	-- blink.cmp's preferred registration is via ``sources.providers`` in
	-- ``setup``; ``register_source`` is offered as a runtime convenience.
	if type(blink.register_source) == "function" then
		blink.register_source("jupyter", Provider)
	end
end

M.Provider = Provider

return M
