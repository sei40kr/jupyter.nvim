---@diagnostic disable: undefined-field
local KernelSpec = require("jupyter_core.kernel_spec")

local function stub_list(result)
	vim.fn.JupyterListKernelspecs = function()
		return result
	end
end

describe("jupyter_core.KernelSpec.list", function()
	it("maps raw RPC dicts to typed KernelSpec values", function()
		stub_list({
			{ name = "python3", display_name = "Python 3", language = "python" },
			{ name = "ir", display_name = "R", language = "R" },
		})

		local specs = KernelSpec.list()
		assert.equals(2, #specs)
		assert.equals("python3", specs[1].name)
		assert.equals("Python 3", specs[1].display_name)
		assert.equals("python", specs[1].language)
		assert.equals("ir", specs[2].name)
		assert.equals("R", specs[2].display_name)
		assert.equals("R", specs[2].language)
	end)

	it("returns an empty list when no kernelspecs are available", function()
		stub_list({})
		assert.same({}, KernelSpec.list())
	end)
end)
