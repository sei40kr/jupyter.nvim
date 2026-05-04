---@alias jupyter_core.OutputType "execute_result"|"stream"|"display_data"|"error"

---@class jupyter_core.Output
---@field output_type jupyter_core.OutputType
---@field data table<string, string>
---@field text string[]
local Output = {}
Output.__index = Output

---@param raw jupyter_core.rpc.RawOutput
---@return jupyter_core.Output
function Output.from_raw(raw)
	local data = raw.data or {}

	-- The rplugin authoritatively packages the text/plain fallback into
	-- `text` for every output_type (error -> traceback, stream/result/
	-- display -> splitlines on text/plain). Prefer it when present so we
	-- don't disagree with Python's splitlines on edge cases like a trailing
	-- newline, and so error tracebacks survive even though their `data` is
	-- empty. Fall back to splitting text/plain ourselves when the producer
	-- did not pre-split.
	---@type string[]
	local text
	if type(raw.text) == "table" then
		text = raw.text --[[@as string[] ]]
	else
		text = {}
		local plain = data["text/plain"]
		if type(plain) == "string" and plain ~= "" then
			text = vim.split(plain, "\n", { plain = true })
		end
	end

	---@type jupyter_core.Output
	local self = setmetatable({
		output_type = raw.output_type,
		data = data,
		text = text,
	}, Output)
	return self
end

return Output
