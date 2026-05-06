---Pending-request registry for async RPCs.
---
---The Python rplugin runs ``complete``/``inspect`` on a worker thread,
---then calls back via ``nvim.exec_lua("require('jupyter_core.async')._resolve(...)", ...)``.
---This module owns the per-id callback table and resolves them on the
---main loop. ``vim.schedule`` is used so callers can rely on running
---inside Neovim's API-safe context regardless of which thread the
---resolution arrived on.

local M = {}

---@type table<integer, fun(err: string?, result: any)>
local pending = {}
local next_id = 0

---@return integer
local function alloc_id()
	next_id = next_id + 1
	return next_id
end

---Register ``callback`` against a fresh request id and return the id.
---The callback fires exactly once with ``(err, result)`` — ``err`` is a
---string when the worker raised, otherwise nil.
---@param callback fun(err: string?, result: any)
---@return integer req_id
function M.register(callback)
	local id = alloc_id()
	pending[id] = callback
	return id
end

---Cancel a pending request without invoking its callback.
---@param req_id integer
function M.cancel(req_id)
	pending[req_id] = nil
end

---Called from the rplugin via ``nvim.exec_lua``. Looks up the registered
---callback and dispatches it on the main loop. Silently ignores unknown
---ids so a late reply never crashes Neovim.
---
---``vim.NIL`` is the msgpack-decoded form of Python ``None``; normalize
---to plain Lua ``nil`` so callers can use ordinary ``x == nil`` checks.
---@param req_id integer
---@param err string?
---@param result any
function M._resolve(req_id, err, result)
	local callback = pending[req_id]
	if callback == nil then
		return
	end
	pending[req_id] = nil
	if err == vim.NIL then
		err = nil
	end
	if result == vim.NIL then
		result = nil
	end
	vim.schedule(function()
		callback(err, result)
	end)
end

---Test-only: drop every pending callback (without firing them).
function M._reset()
	pending = {}
	next_id = 0
end

---Test-only: return how many requests are still in flight.
---@return integer
function M._pending_count()
	local count = 0
	for _ in pairs(pending) do
		count = count + 1
	end
	return count
end

return M
