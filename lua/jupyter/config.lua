---User-facing configuration for the editor module.
---
---Phase 1 keeps options minimal. Unknown keys are tolerated with a
---warning so that older versions of the plugin keep loading when a
---newer config travels in a user's dotfiles.

local M = {}

---@class jupyter.Config
---@field default_kernel string?            spec_name to use if start_kernel called w/o arg
---@field display jupyter.display.Config?
---@field virtual_lsp boolean               auto-attach the in-process LSP when a kernel starts (default true)

---@type jupyter.Config
M.defaults = {
	default_kernel = nil,
	display = nil,
	virtual_lsp = true,
}

---@type table<string, type|type[]>
local TYPE_CHECKS = {
	default_kernel = "string",
	display = "table",
	virtual_lsp = "boolean",
}

---@param key string
---@param value any
---@param expected type|type[]
---@return boolean
local function check_type(key, value, expected)
	if value == nil then
		return true
	end
	local actual = type(value)
	if type(expected) == "string" then
		if actual ~= expected then
			vim.notify(("jupyter.config: %q must be %s, got %s"):format(key, expected, actual), vim.log.levels.WARN)
			return false
		end
		return true
	end
	---@cast expected type[]
	for _, t in ipairs(expected) do
		if actual == t then
			return true
		end
	end
	vim.notify(("jupyter.config: %q has unexpected type %s"):format(key, actual), vim.log.levels.WARN)
	return false
end

---Deep-merge `opts` into the defaults. Unknown keys produce a WARN
---(forward compat); type-mismatched values are dropped with a WARN.
---@param opts jupyter.Config?
---@return jupyter.Config
function M.merge(opts)
	---@type jupyter.Config
	local result = vim.deepcopy(M.defaults)
	if opts == nil then
		return result
	end
	if type(opts) ~= "table" then
		vim.notify(("jupyter.config: setup() expects a table, got %s"):format(type(opts)), vim.log.levels.WARN)
		return result
	end

	for key, value in pairs(opts) do
		local expected = TYPE_CHECKS[key]
		if expected == nil then
			vim.notify(("jupyter.config: unknown option %q"):format(tostring(key)), vim.log.levels.WARN)
		elseif check_type(tostring(key), value, expected) then
			if type(value) == "table" and type(result[key]) == "table" then
				result[key] = vim.tbl_deep_extend("force", result[key], value)
			else
				result[key] = value
			end
		end
	end

	return result
end

return M
