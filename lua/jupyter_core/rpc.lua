---@class jupyter_core.rpc.RawOutput
---@field output_type string
---@field data table<string, string>?
---@field text string[]?

---@class jupyter_core.rpc.RawCompletion
---@field matches string[]
---@field cursor_start integer
---@field cursor_end integer

---@class jupyter_core.rpc.RawInspect
---@field found boolean
---@field data table<string, string>?

---@class jupyter_core.rpc.RawKernelSpec
---@field name string
---@field display_name string
---@field language string

local async = require("jupyter_core.async")

local M = {}

---@param kernel_id string
---@param spec_name string
function M.start_kernel(kernel_id, spec_name)
	vim.fn.JupyterStartKernel(kernel_id, spec_name)
end

---@param kernel_id string
function M.stop_kernel(kernel_id)
	vim.fn.JupyterStopKernel(kernel_id)
end

---@param kernel_id string
function M.restart_kernel(kernel_id)
	vim.fn.JupyterRestartKernel(kernel_id)
end

---@param kernel_id string
---@param code string
---@return jupyter_core.rpc.RawOutput[]
function M.execute_code(kernel_id, code)
	return vim.fn.JupyterExecuteCode(kernel_id, code)
end

---Dispatch an async ``complete_request``. The reply is delivered via
---``jupyter_core.async`` to ``callback(err, raw)``.
---@param kernel_id string
---@param code string
---@param cursor_pos integer
---@param callback fun(err: string?, result: jupyter_core.rpc.RawCompletion?)
function M.complete_async(kernel_id, code, cursor_pos, callback)
	local req_id = async.register(callback)
	vim.fn.JupyterCompleteAsync(req_id, kernel_id, code, cursor_pos)
end

---Dispatch an async ``inspect_request``. See ``complete_async``.
---@param kernel_id string
---@param code string
---@param cursor_pos integer
---@param callback fun(err: string?, result: jupyter_core.rpc.RawInspect?)
function M.inspect_async(kernel_id, code, cursor_pos, callback)
	local req_id = async.register(callback)
	vim.fn.JupyterInspectAsync(req_id, kernel_id, code, cursor_pos)
end

---@return jupyter_core.rpc.RawKernelSpec[]
function M.list_kernelspecs()
	return vim.fn.JupyterListKernelspecs()
end

return M
