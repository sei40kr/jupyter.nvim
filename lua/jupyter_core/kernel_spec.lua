local rpc = require("jupyter_core.rpc")

---@class jupyter_core.KernelSpec
---@field name string
---@field display_name string
---@field language string

local M = {}

---@return jupyter_core.KernelSpec[]
function M.list()
	local raw = rpc.list_kernelspecs()
	---@type jupyter_core.KernelSpec[]
	local specs = {}
	for i, item in ipairs(raw) do
		specs[i] = {
			name = item.name,
			display_name = item.display_name,
			language = item.language,
		}
	end
	return specs
end

return M
