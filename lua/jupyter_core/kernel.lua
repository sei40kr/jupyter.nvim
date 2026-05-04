local rpc = require("jupyter_core.rpc")
local Output = require("jupyter_core.output")

---@alias jupyter_core.KernelState "starting"|"idle"|"busy"|"dead"

---@class jupyter_core.CompletionResult
---@field matches string[]
---@field cursor_start integer
---@field cursor_end integer

---@class jupyter_core.InspectResult
---@field found boolean
---@field data table<string, string>

---@class jupyter_core.Kernel
---@field id string
---@field spec_name string
---@field state jupyter_core.KernelState
local Kernel = {}
Kernel.__index = Kernel

local id_counter = 0

---@return string
local function generate_id()
	id_counter = id_counter + 1
	return string.format("jupyter-%d-%d-%d", os.time(), id_counter, math.random(1000000))
end

---@param spec_name string
---@return jupyter_core.Kernel
function Kernel.start(spec_name)
	---@type jupyter_core.Kernel
	local self = setmetatable({
		id = generate_id(),
		spec_name = spec_name,
		state = "starting",
	}, Kernel)
	rpc.start_kernel(self.id, spec_name)
	self.state = "idle"
	return self
end

function Kernel:stop()
	rpc.stop_kernel(self.id)
	self.state = "dead"
end

function Kernel:restart()
	rpc.restart_kernel(self.id)
	self.state = "idle"
end

---@param code string
---@return jupyter_core.Output[]
function Kernel:execute(code)
	local raw_outputs = rpc.execute_code(self.id, code)
	---@type jupyter_core.Output[]
	local outputs = {}
	for i, raw in ipairs(raw_outputs) do
		outputs[i] = Output.from_raw(raw)
	end
	return outputs
end

---@param code string
---@param cursor_pos integer
---@return jupyter_core.CompletionResult
function Kernel:complete(code, cursor_pos)
	local raw = rpc.complete(self.id, code, cursor_pos)
	return {
		matches = raw.matches,
		cursor_start = raw.cursor_start,
		cursor_end = raw.cursor_end,
	}
end

---@param code string
---@param cursor_pos integer
---@return jupyter_core.InspectResult
function Kernel:inspect(code, cursor_pos)
	local raw = rpc.inspect(self.id, code, cursor_pos)
	return {
		found = raw.found,
		data = raw.data or {},
	}
end

return Kernel
