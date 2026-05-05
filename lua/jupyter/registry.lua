---Buffer → kernel registry.
---
---`vim.b` round-trips through msgpack and strips Lua metatables, so
---methods on `jupyter_core.Kernel` instances vanish if stored there.
---Keep kernels in a Lua-only table keyed by bufnr instead.

local M = {}

---@type table<integer, jupyter_core.Kernel>
local kernels = {}

---@param bufnr integer
---@return jupyter_core.Kernel?
function M.get(bufnr)
	return kernels[bufnr]
end

---@param bufnr integer
---@param kernel jupyter_core.Kernel
function M.set(bufnr, kernel)
	kernels[bufnr] = kernel
end

---@param bufnr integer
function M.clear(bufnr)
	kernels[bufnr] = nil
end

---@return integer[]
function M.bufnrs()
	return vim.tbl_keys(kernels)
end

return M
