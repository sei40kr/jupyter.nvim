---@diagnostic disable: undefined-field
local Kernel = require("jupyter_core.kernel")

local STUBBED_FUNCTIONS = {
	"JupyterStartKernel",
	"JupyterStopKernel",
	"JupyterRestartKernel",
	"JupyterExecuteCode",
	"JupyterComplete",
	"JupyterInspect",
	"JupyterListKernelspecs",
}

local function install_stubs(handlers)
	local calls = {}
	for _, name in ipairs(STUBBED_FUNCTIONS) do
		vim.fn[name] = function(...)
			local args = { ... }
			table.insert(calls, { name = name, args = args })
			local handler = handlers[name]
			if handler then
				return handler(unpack(args))
			end
			return nil
		end
	end
	return calls
end

describe("jupyter_core.Kernel.start", function()
	it("calls JupyterStartKernel with the generated id and spec name", function()
		local calls = install_stubs({})
		local kernel = Kernel.start("python3")

		assert.is_string(kernel.id)
		assert.is_true(#kernel.id > 0)
		assert.equals("python3", kernel.spec_name)
		assert.equals("idle", kernel.state)

		assert.equals(1, #calls)
		assert.equals("JupyterStartKernel", calls[1].name)
		assert.equals(kernel.id, calls[1].args[1])
		assert.equals("python3", calls[1].args[2])
	end)

	it("generates unique ids for separate kernels", function()
		install_stubs({})
		local k1 = Kernel.start("python3")
		local k2 = Kernel.start("python3")
		assert.are_not.equals(k1.id, k2.id)
	end)
end)

describe("jupyter_core.Kernel:stop", function()
	it("calls JupyterStopKernel and marks the kernel dead", function()
		local calls = install_stubs({})
		local kernel = Kernel.start("python3")
		kernel:stop()

		assert.equals("dead", kernel.state)
		assert.equals("JupyterStopKernel", calls[#calls].name)
		assert.equals(kernel.id, calls[#calls].args[1])
	end)
end)

describe("jupyter_core.Kernel:restart", function()
	it("calls JupyterRestartKernel", function()
		local calls = install_stubs({})
		local kernel = Kernel.start("python3")
		kernel:restart()

		assert.equals("idle", kernel.state)
		assert.equals("JupyterRestartKernel", calls[#calls].name)
	end)
end)

describe("jupyter_core.Kernel:execute", function()
	it("returns Output values built from raw RPC dicts", function()
		-- Mirror the rplugin contract: every output carries the MIME bundle
		-- in `data` and the text/plain fallback pre-split in `text`.
		install_stubs({
			JupyterExecuteCode = function()
				return {
					{
						output_type = "execute_result",
						data = {
							["text/plain"] = "42",
							["text/html"] = "<b>42</b>",
						},
						text = { "42" },
					},
					{
						output_type = "stream",
						data = { ["text/plain"] = "line1\nline2" },
						text = { "line1", "line2" },
					},
				}
			end,
		})

		local kernel = Kernel.start("python3")
		local outputs = kernel:execute("print(1+1)")

		assert.equals(2, #outputs)

		assert.equals("execute_result", outputs[1].output_type)
		assert.equals("42", outputs[1].data["text/plain"])
		assert.equals("<b>42</b>", outputs[1].data["text/html"])
		assert.same({ "42" }, outputs[1].text)

		assert.equals("stream", outputs[2].output_type)
		assert.same({ "line1", "line2" }, outputs[2].text)
	end)

	it("returns an empty list when the kernel produces no outputs", function()
		install_stubs({
			JupyterExecuteCode = function()
				return {}
			end,
		})
		local kernel = Kernel.start("python3")
		assert.same({}, kernel:execute("pass"))
	end)
end)

describe("jupyter_core.Kernel:complete", function()
	it("returns a typed CompletionResult", function()
		install_stubs({
			JupyterComplete = function(_, code, cursor_pos)
				assert.equals("import o", code)
				assert.equals(8, cursor_pos)
				return {
					matches = { "os", "operator" },
					cursor_start = 7,
					cursor_end = 8,
				}
			end,
		})

		local kernel = Kernel.start("python3")
		local result = kernel:complete("import o", 8)
		assert.same({ "os", "operator" }, result.matches)
		assert.equals(7, result.cursor_start)
		assert.equals(8, result.cursor_end)
	end)
end)

describe("jupyter_core.Kernel:inspect", function()
	it("returns a typed InspectResult when the symbol is found", function()
		install_stubs({
			JupyterInspect = function()
				return {
					found = true,
					data = { ["text/plain"] = "Help on built-in function len" },
				}
			end,
		})

		local kernel = Kernel.start("python3")
		local result = kernel:inspect("len(", 4)
		assert.is_true(result.found)
		assert.equals("Help on built-in function len", result.data["text/plain"])
	end)

	it("returns found=false with empty data when the symbol is not found", function()
		install_stubs({
			JupyterInspect = function()
				return { found = false }
			end,
		})
		local kernel = Kernel.start("python3")
		local result = kernel:inspect("xyznotreal", 10)
		assert.is_false(result.found)
		assert.same({}, result.data)
	end)
end)
