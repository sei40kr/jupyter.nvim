---@diagnostic disable: undefined-field, need-check-nil, unused-local
package.loaded["jupyter_core.async"] = nil
package.loaded["jupyter_core.rpc"] = nil
package.loaded["jupyter_core.kernel"] = nil
local Kernel = require("jupyter_core.kernel")
local async = require("jupyter_core.async")

local STUBBED_FUNCTIONS = {
	"JupyterStartKernel",
	"JupyterStopKernel",
	"JupyterRestartKernel",
	"JupyterExecuteCode",
	"JupyterCompleteAsync",
	"JupyterInspectAsync",
	"JupyterListKernelspecs",
}

---Drain ``vim.schedule`` callbacks so async resolutions deliver before
---the assertion runs.
local function flush()
	vim.wait(50, function()
		return false
	end, 5)
end

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

describe("jupyter_core.Kernel:complete_async", function()
	it("returns a typed CompletionResult via the callback", function()
		install_stubs({
			JupyterCompleteAsync = function(req_id, _kernel_id, code, cursor_pos)
				assert.equals("import o", code)
				assert.equals(8, cursor_pos)
				vim.schedule(function()
					async._resolve(req_id, nil, {
						matches = { "os", "operator" },
						cursor_start = 7,
						cursor_end = 8,
					})
				end)
			end,
		})

		local kernel = Kernel.start("python3")
		---@type {err: any, result: any}?
		local got
		kernel:complete_async("import o", 8, function(err, result)
			got = { err = err, result = result }
		end)
		flush()
		flush()

		assert.is_truthy(got)
		assert.is_nil(got.err)
		assert.same({ "os", "operator" }, got.result.matches)
		assert.equals(7, got.result.cursor_start)
		assert.equals(8, got.result.cursor_end)
	end)

	it("propagates worker errors through the err parameter", function()
		install_stubs({
			JupyterCompleteAsync = function(req_id)
				vim.schedule(function()
					async._resolve(req_id, "boom", nil)
				end)
			end,
		})

		local kernel = Kernel.start("python3")
		---@type {err: any, result: any}?
		local got
		kernel:complete_async("x", 1, function(err, result)
			got = { err = err, result = result }
		end)
		flush()
		flush()

		assert.is_truthy(got)
		assert.equals("boom", got.err)
		assert.is_nil(got.result)
	end)
end)

describe("jupyter_core.Kernel:inspect_async", function()
	it("returns a typed InspectResult when the symbol is found", function()
		install_stubs({
			JupyterInspectAsync = function(req_id)
				vim.schedule(function()
					async._resolve(req_id, nil, {
						found = true,
						data = { ["text/plain"] = "Help on built-in function len" },
					})
				end)
			end,
		})

		local kernel = Kernel.start("python3")
		---@type {err: any, result: any}?
		local got
		kernel:inspect_async("len(", 4, function(err, result)
			got = { err = err, result = result }
		end)
		flush()
		flush()

		assert.is_truthy(got)
		assert.is_nil(got.err)
		assert.is_true(got.result.found)
		assert.equals("Help on built-in function len", got.result.data["text/plain"])
	end)

	it("returns found=false with empty data when the symbol is not found", function()
		install_stubs({
			JupyterInspectAsync = function(req_id)
				vim.schedule(function()
					async._resolve(req_id, nil, { found = false })
				end)
			end,
		})

		local kernel = Kernel.start("python3")
		---@type {err: any, result: any}?
		local got
		kernel:inspect_async("xyznotreal", 10, function(err, result)
			got = { err = err, result = result }
		end)
		flush()
		flush()

		assert.is_truthy(got)
		assert.is_nil(got.err)
		assert.is_false(got.result.found)
		assert.same({}, got.result.data)
	end)
end)
