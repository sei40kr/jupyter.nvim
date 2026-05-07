---@diagnostic disable: undefined-field, duplicate-set-field, inject-field
-- Make queries/ discoverable so jupyter.cell can find its Treesitter query.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = require("tests.lua.helpers")

local JUPYTER_MODULES = {
	"jupyter",
	"jupyter.config",
	"jupyter.cell",
	"jupyter.execute",
	"jupyter.display",
	"jupyter.hover",
	"jupyter.lsp",
	"jupyter.registry",
	"jupyter_core",
	"jupyter_core.kernel",
	"jupyter_core.kernel_spec",
}

---@param fn fun(notifications: {msg: string, level: integer}[])
local function with_notify(fn)
	local original = vim.notify
	---@type {msg: string, level: integer}[]
	local notifications = {}
	---@diagnostic disable-next-line: duplicate-set-field
	vim.notify = function(msg, level)
		notifications[#notifications + 1] = { msg = msg, level = level }
	end
	local ok, err = pcall(fn, notifications)
	vim.notify = original
	if not ok then
		error(err, 0)
	end
end

---Reset modules and stub jupyter_core + sibling editor modules so the
---spec exercises only the public Lua API surface.
---@return table  -- the freshly reloaded jupyter module
local function reload_with_stubs(stubs)
	for _, name in ipairs(JUPYTER_MODULES) do
		package.loaded[name] = nil
	end
	-- Provide stub jupyter_core before jupyter.init requires it.
	package.loaded["jupyter_core"] = stubs.jupyter_core
	package.loaded["jupyter.execute"] = stubs.execute
	package.loaded["jupyter.display"] = stubs.display
	package.loaded["jupyter.hover"] = stubs.hover
	package.loaded["jupyter.lsp"] = stubs.lsp
	-- Real cell module is fine: it has no side effects on require.
	return require("jupyter")
end

local function make_stubs()
	---@type {start_calls: {spec_name: string}[], list_calls: integer, stop_calls: integer, restart_calls: integer}
	local kernel_state = {
		start_calls = {},
		list_calls = 0,
		stop_calls = 0,
		restart_calls = 0,
	}

	local Kernel = {}
	function Kernel.start(spec_name)
		table.insert(kernel_state.start_calls, { spec_name = spec_name })
		-- vim.b[bufnr] round-trips tables by copy and drops methods, so
		-- mutations to `self` from inside `stop`/`restart` don't survive.
		-- Track calls in the closure-captured `kernel_state` instead.
		local kernel = {
			id = "test-kernel",
			spec_name = spec_name,
			state = "idle",
		}
		function kernel.stop()
			kernel_state.stop_calls = kernel_state.stop_calls + 1
		end
		function kernel.restart()
			kernel_state.restart_calls = kernel_state.restart_calls + 1
		end
		return kernel
	end

	local KernelSpec = {}
	function KernelSpec.list()
		kernel_state.list_calls = kernel_state.list_calls + 1
		return {
			{ name = "python3", display_name = "Python 3", language = "python" },
		}
	end

	---@type any[]
	local execute_calls = {}
	local execute = {
		execute_cell = function(bufnr, row)
			execute_calls[#execute_calls + 1] = { fn = "execute_cell", bufnr = bufnr, row = row }
		end,
		execute_all = function(bufnr)
			execute_calls[#execute_calls + 1] = { fn = "execute_all", bufnr = bufnr }
		end,
		clear_cell = function(bufnr, row)
			execute_calls[#execute_calls + 1] = { fn = "clear_cell", bufnr = bufnr, row = row }
		end,
	}

	---@type any[]
	local display_calls = {}
	local display = {
		setup = function(cfg)
			display_calls[#display_calls + 1] = { fn = "setup", cfg = cfg }
		end,
		clear_all = function(bufnr)
			display_calls[#display_calls + 1] = { fn = "clear_all", bufnr = bufnr }
		end,
	}

	---@type any[]
	local hover_calls = {}
	local hover = {
		hover = function(bufnr)
			hover_calls[#hover_calls + 1] = { bufnr = bufnr }
		end,
	}

	---@type {fn: string, bufnr: integer}[]
	local lsp_calls = {}
	local lsp = {
		attach = function(bufnr)
			lsp_calls[#lsp_calls + 1] = { fn = "attach", bufnr = bufnr }
		end,
		detach = function(bufnr)
			lsp_calls[#lsp_calls + 1] = { fn = "detach", bufnr = bufnr }
		end,
		stop_all = function()
			lsp_calls[#lsp_calls + 1] = { fn = "stop_all", bufnr = -1 }
		end,
	}

	return {
		jupyter_core = { Kernel = Kernel, KernelSpec = KernelSpec },
		kernel_state = kernel_state,
		execute = execute,
		execute_calls = execute_calls,
		display = display,
		display_calls = display_calls,
		hover = hover,
		hover_calls = hover_calls,
		lsp = lsp,
		lsp_calls = lsp_calls,
	}
end

describe("jupyter.init", function()
	local stubs
	local jupyter
	local registry

	before_each(function()
		stubs = make_stubs()
		jupyter = reload_with_stubs(stubs)
		registry = require("jupyter.registry")
	end)

	after_each(function()
		pcall(vim.api.nvim_del_augroup_by_name, "jupyter.default_keymaps")
		if registry ~= nil then
			for _, b in ipairs(registry.bufnrs()) do
				registry.clear(b)
			end
		end
		for _, name in ipairs(JUPYTER_MODULES) do
			package.loaded[name] = nil
		end
	end)

	describe("setup", function()
		it("merges defaults with user options", function()
			with_notify(function()
				jupyter.setup({ default_kernel = "python3" })
			end)
			assert.equals("python3", jupyter._cfg.default_kernel)
			assert.equals(false, jupyter._cfg.create_default_keymaps)
		end)

		it("warns on unknown keys but still applies known ones", function()
			with_notify(function(notifications)
				jupyter.setup({ default_kernel = "python3", bogus = 42 })
				local found
				for _, n in ipairs(notifications) do
					if n.msg:match("bogus") then
						found = n
					end
				end
				assert.is_truthy(found)
				assert.equals(vim.log.levels.WARN, found.level)
			end)
			assert.equals("python3", jupyter._cfg.default_kernel)
		end)

		it("forwards display options to display.setup", function()
			with_notify(function()
				jupyter.setup({ display = { max_lines = 7 } })
			end)
			local found
			for _, c in ipairs(stubs.display_calls) do
				if c.fn == "setup" then
					found = c
				end
			end
			assert.is_truthy(found)
			assert.equals(7, found.cfg.max_lines)
		end)
	end)

	describe("start_kernel", function()
		it("calls Kernel.start with the explicit spec name", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			vim.api.nvim_set_current_buf(bufnr)
			with_notify(function()
				jupyter.setup({})
				jupyter.start_kernel("python3")
			end)
			assert.equals(1, #stubs.kernel_state.start_calls)
			assert.equals("python3", stubs.kernel_state.start_calls[1].spec_name)
			local stored = registry.get(bufnr)
			assert.is_truthy(stored)
			assert.equals("python3", stored.spec_name)
		end)

		it("uses config.default_kernel when called without arg", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			vim.api.nvim_set_current_buf(bufnr)
			with_notify(function()
				jupyter.setup({ default_kernel = "python3" })
				jupyter.start_kernel(nil)
			end)
			assert.equals(1, #stubs.kernel_state.start_calls)
			assert.equals("python3", stubs.kernel_state.start_calls[1].spec_name)
		end)
	end)

	describe("stop_kernel", function()
		it("calls kernel:stop, clears the buffer var, and clear_all", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			vim.api.nvim_set_current_buf(bufnr)
			with_notify(function()
				jupyter.setup({})
				jupyter.start_kernel("python3")
				jupyter.stop_kernel()
			end)
			assert.equals(1, stubs.kernel_state.stop_calls)
			assert.is_nil(registry.get(bufnr))

			local found
			for _, c in ipairs(stubs.display_calls) do
				if c.fn == "clear_all" and c.bufnr == bufnr then
					found = c
				end
			end
			assert.is_truthy(found)
		end)

		it("warns when there's no kernel attached", function()
			local bufnr = helpers.scratch_buf({})
			vim.api.nvim_set_current_buf(bufnr)
			with_notify(function(notifications)
				jupyter.setup({})
				jupyter.stop_kernel()
				assert.equals(1, #notifications)
				assert.equals(vim.log.levels.WARN, notifications[1].level)
			end)
		end)
	end)

	describe("execute_cell", function()
		it("delegates to execute.execute_cell with the current buffer and row=nil", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			vim.api.nvim_set_current_buf(bufnr)
			with_notify(function()
				jupyter.setup({})
				jupyter.execute_cell()
			end)
			assert.equals(1, #stubs.execute_calls)
			assert.equals("execute_cell", stubs.execute_calls[1].fn)
			assert.equals(bufnr, stubs.execute_calls[1].bufnr)
			assert.is_nil(stubs.execute_calls[1].row)
		end)
	end)

	describe("hover", function()
		it("delegates to hover.hover with the current buffer", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			vim.api.nvim_set_current_buf(bufnr)
			with_notify(function()
				jupyter.setup({})
				jupyter.hover()
			end)
			assert.equals(1, #stubs.hover_calls)
			assert.equals(bufnr, stubs.hover_calls[1].bufnr)
		end)
	end)
end)
