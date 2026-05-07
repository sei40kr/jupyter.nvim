---@diagnostic disable: undefined-field, duplicate-set-field
-- Make queries/ discoverable so jupyter.cell can resolve its Treesitter query.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = require("tests.lua.helpers")

---@class jupyter.test.MockKernel
---@field state jupyter_core.KernelState
---@field calls { type: string, args: any[] }[]

---vim.b[bufnr] copies tables on round-trip, so the kernel's `:execute`
---can't reliably mutate fields on `self`. The mock instead records into
---a closure-captured `calls` table that the test holds a reference to.
---@param state jupyter_core.KernelState
---@param results jupyter_core.Output[][]?
---@return jupyter.test.MockKernel
local function make_kernel(state, results)
	results = results or {}
	---@type { type: string, args: any[] }[]
	local calls = {}
	local k = {
		state = state,
		calls = calls,
	}
	---@diagnostic disable-next-line: inject-field
	function k.execute(_, code)
		table.insert(calls, { type = "execute", args = { code } })
		return results[#calls] or {}
	end
	return k
end

---@param events table
---@return table
local function install_display_stubs(events)
	local display = require("jupyter.display")
	local saved = {
		set_status = display.set_status,
		show_output = display.show_output,
		clear_output = display.clear_output,
	}
	display.set_status = function(bufnr, cell, status)
		table.insert(events, { fn = "set_status", bufnr = bufnr, cell = cell, status = status })
	end
	display.show_output = function(bufnr, cell, outputs)
		table.insert(events, { fn = "show_output", bufnr = bufnr, cell = cell, outputs = outputs })
	end
	display.clear_output = function(bufnr, cell)
		table.insert(events, { fn = "clear_output", bufnr = bufnr, cell = cell })
	end
	return saved
end

---@param saved table
local function restore_display(saved)
	local display = require("jupyter.display")
	display.set_status = saved.set_status
	display.show_output = saved.show_output
	display.clear_output = saved.clear_output
end

---Run `fn` with `vim.notify` capturing into `notifications`.
---@param notifications { msg: string, level: integer }[]
---@param fn fun()
local function with_notify(notifications, fn)
	local original = vim.notify
	---@diagnostic disable-next-line: duplicate-set-field
	vim.notify = function(msg, level)
		table.insert(notifications, { msg = msg, level = level })
	end
	local ok, err = pcall(fn)
	vim.notify = original
	if not ok then
		error(err, 0)
	end
end

---@param output_type jupyter_core.OutputType
---@param text string[]?
---@return jupyter_core.Output
local function make_output(output_type, text)
	return { output_type = output_type, data = {}, text = text or {} }
end

describe("jupyter.execute", function()
	local execute
	local registry
	local display_saved

	before_each(function()
		package.loaded["jupyter.execute"] = nil
		package.loaded["jupyter.display"] = nil
		package.loaded["jupyter.cell"] = nil
		package.loaded["jupyter.registry"] = nil
		execute = require("jupyter.execute")
		registry = require("jupyter.registry")
		display_saved = nil
	end)

	after_each(function()
		if display_saved ~= nil then
			restore_display(display_saved)
			display_saved = nil
		end
		for _, b in ipairs(registry.bufnrs()) do
			registry.clear(b)
		end
	end)

	describe("execute_cell", function()
		it("notifies WARN and renders nothing when no kernel is set", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			registry.clear(bufnr)

			local events = {}
			display_saved = install_display_stubs(events)

			local notifications = {}
			with_notify(notifications, function()
				execute.execute_cell(bufnr, 1)
			end)

			assert.equals(1, #notifications)
			assert.equals(vim.log.levels.WARN, notifications[1].level)
			assert.is_truthy(notifications[1].msg:match(":JupyterStart"))
			assert.equals(0, #events)
		end)

		it("notifies ERROR when the kernel is dead", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			registry.set(bufnr, make_kernel("dead"))

			local events = {}
			display_saved = install_display_stubs(events)

			local notifications = {}
			with_notify(notifications, function()
				execute.execute_cell(bufnr, 1)
			end)

			assert.equals(1, #notifications)
			assert.equals(vim.log.levels.ERROR, notifications[1].level)
			assert.equals(0, #events)
		end)

		it("happy path orders set_status busy → execute → show_output → set_status idle", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1", "y = 2" })
			local kernel = make_kernel("idle", { { make_output("stream", { "ok" }) } })
			registry.set(bufnr, kernel)

			local events = {}
			display_saved = install_display_stubs(events)

			execute.execute_cell(bufnr, 1)

			-- The single execute call received the joined source.
			assert.equals(1, #kernel.calls)
			assert.equals("execute", kernel.calls[1].type)
			assert.equals("# %%\nx = 1\ny = 2", kernel.calls[1].args[1])

			-- The display events fired in the documented order.
			assert.equals(3, #events)
			assert.equals("set_status", events[1].fn)
			assert.equals("busy", events[1].status)
			assert.equals("show_output", events[2].fn)
			assert.equals("set_status", events[3].fn)
			assert.equals("idle", events[3].status)
		end)

		it("on error output: set_status error with show_output still called", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			local err_output = make_output("error", { "Traceback", "ValueError: boom" })
			local kernel = make_kernel("idle", { { err_output } })
			registry.set(bufnr, kernel)

			local events = {}
			display_saved = install_display_stubs(events)

			execute.execute_cell(bufnr, 1)

			assert.equals(3, #events)
			assert.equals("set_status", events[1].fn)
			assert.equals("busy", events[1].status)
			assert.equals("show_output", events[2].fn)
			-- show_output received the error output payload.
			assert.equals("error", events[2].outputs[1].output_type)
			assert.equals("set_status", events[3].fn)
			assert.equals("error", events[3].status)
		end)

		it("uses the cursor row when row is omitted", function()
			local bufnr = helpers.scratch_buf({
				"# %%", -- 0
				"x = 1", -- 1
				"# %%", -- 2
				"y = 2", -- 3
			})
			local kernel = make_kernel("idle", {
				{ make_output("stream", { "first" }) },
				{ make_output("stream", { "second" }) },
			})
			registry.set(bufnr, kernel)

			local winid = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(winid, bufnr)
			vim.api.nvim_win_set_cursor(winid, { 4, 0 }) -- 0-indexed row 3

			local events = {}
			display_saved = install_display_stubs(events)

			execute.execute_cell(bufnr)

			assert.equals(1, #kernel.calls)
			assert.equals("# %%\ny = 2", kernel.calls[1].args[1])
		end)
	end)

	describe("execute_all", function()
		it("walks every code cell when none error", function()
			local bufnr = helpers.scratch_buf({
				"# %%", -- 0
				"a = 1", -- 1
				"# %%", -- 2
				"b = 2", -- 3
			})
			local kernel = make_kernel("idle", {
				{ make_output("stream", { "ok1" }) },
				{ make_output("stream", { "ok2" }) },
			})
			registry.set(bufnr, kernel)

			local events = {}
			display_saved = install_display_stubs(events)

			local notifications = {}
			with_notify(notifications, function()
				execute.execute_all(bufnr)
			end)

			assert.equals(2, #kernel.calls)
			assert.equals("# %%\na = 1", kernel.calls[1].args[1])
			assert.equals("# %%\nb = 2", kernel.calls[2].args[1])

			-- Two cells × {busy, show_output, idle} = 6 events.
			assert.equals(6, #events)
			assert.equals(0, #notifications)
		end)

		it("halts on the first error cell and notifies INFO with the row", function()
			local bufnr = helpers.scratch_buf({
				"# %%", -- 0
				"a = 1", -- 1
				"# %%", -- 2
				"raise", -- 3
				"# %%", -- 4
				"never", -- 5
			})
			local kernel = make_kernel("idle", {
				{ make_output("stream", { "ok" }) },
				{ make_output("error", { "boom" }) },
				{ make_output("stream", { "unreached" }) },
			})
			registry.set(bufnr, kernel)

			local events = {}
			display_saved = install_display_stubs(events)

			local notifications = {}
			with_notify(notifications, function()
				execute.execute_all(bufnr)
			end)

			-- Only the first two cells were sent to the kernel.
			assert.equals(2, #kernel.calls)

			-- An INFO notification mentions the row of the failing cell (row 2).
			assert.equals(1, #notifications)
			assert.equals(vim.log.levels.INFO, notifications[1].level)
			assert.is_truthy(notifications[1].msg:match("2"))

			-- The second cell received an error status.
			local last_status
			for _, ev in ipairs(events) do
				if ev.fn == "set_status" then
					last_status = ev.status
				end
			end
			assert.equals("error", last_status)
		end)

		it("notifies WARN and runs nothing when no kernel is set", function()
			local bufnr = helpers.scratch_buf({ "# %%", "x = 1" })
			registry.clear(bufnr)

			local events = {}
			display_saved = install_display_stubs(events)

			local notifications = {}
			with_notify(notifications, function()
				execute.execute_all(bufnr)
			end)

			assert.equals(1, #notifications)
			assert.equals(vim.log.levels.WARN, notifications[1].level)
			assert.equals(0, #events)
		end)
	end)

	describe("clear_cell", function()
		it("delegates to display.clear_output for the cell at the row", function()
			local bufnr = helpers.scratch_buf({
				"# %%", -- 0
				"x = 1", -- 1
				"# %%", -- 2
				"y = 2", -- 3
			})

			local events = {}
			display_saved = install_display_stubs(events)

			execute.clear_cell(bufnr, 3)

			assert.equals(1, #events)
			assert.equals("clear_output", events[1].fn)
			assert.equals(2, events[1].cell.start_row)
			assert.equals(4, events[1].cell.end_row)
		end)

		it("is a no-op when no cell exists at the row (preamble)", function()
			local bufnr = helpers.scratch_buf({
				"preamble", -- 0
				"# %%", -- 1
				"x = 1", -- 2
			})

			local events = {}
			display_saved = install_display_stubs(events)

			execute.clear_cell(bufnr, 0)

			assert.equals(0, #events)
		end)
	end)
end)
