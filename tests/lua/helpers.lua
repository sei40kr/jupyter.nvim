---Shared utilities for vusted specs.
---
---Provides small primitives that several tests need: hidden scratch
---buffers and scoped overrides for ``vim.fn.Jupyter*`` RPC stubs.
local M = {}

---@param lines string[]|nil    -- defaults to an empty buffer
---@param filetype string|nil   -- defaults to "python" (cell detection requires a supported filetype)
---@return integer  -- bufnr of the new hidden scratch buffer
function M.scratch_buf(lines, filetype)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = filetype or "python"
	if lines and #lines > 0 then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	end
	return bufnr
end

---Run ``fn`` with the given ``vim.fn`` overrides installed, then restore
---the original entries even if ``fn`` raises.
---
---Used by ``jupyter_core`` specs to mock ``Jupyter*`` RPC functions
---without polluting other tests.
---
---@param overrides table<string, function>
---@param fn fun()
function M.with_vim_fn(overrides, fn)
	local saved = {}
	for name, _ in pairs(overrides) do
		saved[name] = vim.fn[name]
	end
	for name, override in pairs(overrides) do
		vim.fn[name] = override
	end
	local ok, err = pcall(fn)
	for name, _ in pairs(overrides) do
		vim.fn[name] = saved[name]
	end
	if not ok then
		error(err, 0)
	end
end

---@class tests.CapturedAutocmd
---@field pattern string
---@field data any

---Capture every ``User`` autocmd matching one of ``patterns`` into the
---returned list (each entry is ``{pattern, data}`` in arrival order).
---The autogroup created here is returned alongside so callers can clean
---up with ``vim.api.nvim_del_augroup_by_id`` (typically inside
---``finally``).
---@param patterns string[]
---@return tests.CapturedAutocmd[] events, integer group_id
function M.capture_user_autocmds(patterns)
	local events = {}
	local group = vim.api.nvim_create_augroup("jupyter-test-capture", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = patterns,
		callback = function(ev)
			events[#events + 1] = { pattern = ev.match, data = ev.data }
		end,
	})
	return events, group
end

return M
