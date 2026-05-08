---@diagnostic disable: undefined-field
package.loaded["jupyter.display"] = nil
local display = require("jupyter.display")

local NS = vim.api.nvim_create_namespace("jupyter.display")

---@param lines string[]
---@return integer
local function make_buf(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return bufnr
end

---@param start_row integer
---@param end_row integer
---@param cell_type? "code"|"markdown"
---@return jupyter.Cell
local function make_cell(start_row, end_row, cell_type)
	return {
		cell_type = cell_type or "code",
		start_row = start_row,
		end_row = end_row,
		source = {},
	}
end

---@param output_type jupyter_core.OutputType
---@param text string[]
---@param data? table<string, string>
---@return jupyter_core.Output
local function make_output(output_type, text, data)
	return { output_type = output_type, data = data or {}, text = text }
end

---@param bufnr integer
---@return table[]
local function get_marks(bufnr)
	return vim.api.nvim_buf_get_extmarks(bufnr, NS, { 0, 0 }, { -1, -1 }, { details = true })
end

---@param bufnr integer
---@return table[]
local function get_virt_lines_marks(bufnr)
	---@type table[]
	local out = {}
	for _, mark in ipairs(get_marks(bufnr)) do
		if mark[4] and mark[4].virt_lines ~= nil then
			out[#out + 1] = mark
		end
	end
	return out
end

---@param bufnr integer
---@return table[]
local function get_virt_text_marks(bufnr)
	---@type table[]
	local out = {}
	for _, mark in ipairs(get_marks(bufnr)) do
		if mark[4] and mark[4].virt_text ~= nil then
			out[#out + 1] = mark
		end
	end
	return out
end

describe("jupyter.display", function()
	before_each(function()
		-- Reset module state between tests by re-loading.
		package.loaded["jupyter.display"] = nil
		display = require("jupyter.display")
	end)

	describe("show_output", function()
		it("places a virt_lines extmark anchored at the cell's last line", function()
			local buf = make_buf({ "# %%", "x = 1", "y = 2" })
			local cell = make_cell(0, 3)
			display.show_output(buf, cell, { make_output("stream", { "hello" }) })

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			-- mark = {id, row, col, details}
			assert.equals(2, marks[1][2]) -- end_row - 1
			assert.same({ { { "hello", "Comment" } } }, marks[1][4].virt_lines)
		end)

		it("renders multi-line text as one virt_lines mark with multiple chunks", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("stream", { "a", "b", "c" }) })

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({
				{ { "a", "Comment" } },
				{ { "b", "Comment" } },
				{ { "c", "Comment" } },
			}, marks[1][4].virt_lines)
		end)

		it("re-rendering for the same cell replaces (does not duplicate)", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("stream", { "first" }) })
			display.show_output(buf, cell, { make_output("stream", { "second" }) })

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({ { { "second", "Comment" } } }, marks[1][4].virt_lines)
		end)

		it("falls back to data['text/plain'] when text is empty", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, {
				make_output("execute_result", {}, { ["text/plain"] = "fallback\nlines" }),
			})

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({
				{ { "fallback", "Comment" } },
				{ { "lines", "Comment" } },
			}, marks[1][4].virt_lines)
		end)

		it("strips ANSI escape sequences from rendered text", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			local colored = "\27[31mred\27[0m text"
			display.show_output(buf, cell, { make_output("stream", { colored }) })

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({ { { "red text", "Comment" } } }, marks[1][4].virt_lines)
		end)

		it("truncates output past max_lines and shows the configured hint", function()
			display.setup({ max_lines = 3, truncation_hint = "(+%d hidden)" })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, {
				make_output("stream", { "1", "2", "3", "4", "5" }),
			})

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({
				{ { "1", "Comment" } },
				{ { "2", "Comment" } },
				{ { "3", "Comment" } },
				{ { "(+2 hidden)", "Comment" } },
			}, marks[1][4].virt_lines)
		end)

		it("includes traceback content for error outputs", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, {
				make_output("error", {
					"Traceback (most recent call last):",
					"  File ...",
					"ValueError: boom",
				}),
			})

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({
				{ { "Traceback (most recent call last):", "Comment" } },
				{ { "  File ...", "Comment" } },
				{ { "ValueError: boom", "Comment" } },
			}, marks[1][4].virt_lines)
		end)

		it("appends extra traceback strings carried on data", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, {
				make_output("error", { "header" }, { traceback = "frame1\nframe2" }),
			})

			local marks = get_virt_lines_marks(buf)
			assert.same({
				{ { "header", "Comment" } },
				{ { "frame1", "Comment" } },
				{ { "frame2", "Comment" } },
			}, marks[1][4].virt_lines)
		end)

		it("does not place a mark when there is no renderable content", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/png"] = "..." }) })
			assert.equals(0, #get_virt_lines_marks(buf))
		end)
	end)

	describe("clear_output", function()
		it("removes only the output marks for a cell", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("stream", { "hello" }) })
			display.set_status(buf, cell, "busy")

			display.clear_output(buf, cell)

			assert.equals(0, #get_virt_lines_marks(buf))
			assert.equals(1, #get_virt_text_marks(buf))
		end)

		it("is a no-op when there is nothing to clear", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.clear_output(buf, cell)
			assert.equals(0, #get_marks(buf))
		end)
	end)

	describe("clear_all", function()
		it("removes every mark across cells", function()
			local buf = make_buf({ "# %%", "a = 1", "# %%", "b = 2" })
			local c1 = make_cell(0, 2)
			local c2 = make_cell(2, 4)
			display.show_output(buf, c1, { make_output("stream", { "x" }) })
			display.show_output(buf, c2, { make_output("stream", { "y" }) })
			display.set_status(buf, c1, "busy")

			display.clear_all(buf)

			assert.equals(0, #get_marks(buf))
		end)
	end)

	describe("show_output with image renderer", function()
		---@type table[]
		local placement_calls = {}
		---@type table[]
		local placement_instances = {}

		---Install a fake snacks.image module. Records every placement.new
		---call and exposes a :close() spy on each placement instance.
		---@param opts? { supports_terminal?: boolean, fail_new?: boolean }
		local function install_snacks(opts)
			opts = opts or {}
			local supports = opts.supports_terminal
			if supports == nil then
				supports = true
			end
			placement_calls = {}
			placement_instances = {}
			package.loaded["snacks.image"] = {
				supports_terminal = function()
					return supports
				end,
				placement = {
					new = function(bufnr, src, place_opts)
						placement_calls[#placement_calls + 1] = {
							bufnr = bufnr,
							src = src,
							opts = place_opts,
						}
						if opts.fail_new then
							error("snacks new failed")
						end
						local instance = { closed = 0, src = src }
						function instance:close()
							self.closed = self.closed + 1
						end
						placement_instances[#placement_instances + 1] = instance
						return instance
					end,
				},
			}
		end

		local function uninstall_snacks()
			package.loaded["snacks.image"] = nil
		end

		-- A 1x1 transparent PNG, base64-encoded.
		local PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

		after_each(function()
			uninstall_snacks()
		end)

		it("default config (image.renderer = nil) does not place a mark for image-only output", function()
			-- Re-asserts the existing contract: without opting in, image
			-- payloads are dropped silently. install_snacks NOT called.
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })
			assert.equals(0, #get_virt_lines_marks(buf))
		end)

		it("places an image via snacks when image.renderer = 'snacks'", function()
			install_snacks()
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "x = 1", "y = 2" })
			local cell = make_cell(0, 3)
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })

			assert.equals(1, #placement_calls)
			assert.equals(buf, placement_calls[1].bufnr)
			-- pos is 1-indexed, anchored at end_row - 1 = 2 → pos.row = 3
			assert.same({ 3, 0 }, placement_calls[1].opts.pos)
			assert.is_true(placement_calls[1].opts.inline)
			assert.equals(60, placement_calls[1].opts.max_width)
			assert.equals(20, placement_calls[1].opts.max_height)
			-- No virt_lines for an image-only output.
			assert.equals(0, #get_virt_lines_marks(buf))
		end)

		it("honors max_width / max_height overrides", function()
			install_snacks()
			display.setup({ image = { renderer = "snacks", max_width = 70, max_height = 30 } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })

			assert.equals(70, placement_calls[1].opts.max_width)
			assert.equals(30, placement_calls[1].opts.max_height)
		end)

		it("renders image/jpeg via the same path", function()
			install_snacks()
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/jpeg"] = PNG_B64 }) })

			assert.equals(1, #placement_calls)
			assert.matches("%.jpg$", placement_calls[1].src)
		end)

		it("falls back to text/plain when snacks is not installed", function()
			-- image.renderer set but snacks.image not in package.loaded.
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, {
				make_output("display_data", {}, {
					["image/png"] = PNG_B64,
					["text/plain"] = "<Figure size 640x480>",
				}),
			})

			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({ { { "<Figure size 640x480>", "Comment" } } }, marks[1][4].virt_lines)
		end)

		it("falls back to text/plain when supports_terminal returns false", function()
			install_snacks({ supports_terminal = false })
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, {
				make_output("display_data", {}, {
					["image/png"] = PNG_B64,
					["text/plain"] = "<Figure>",
				}),
			})

			assert.equals(0, #placement_calls)
			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
		end)

		it("renders text and image side-by-side as one virt_lines + one placement", function()
			install_snacks()
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, {
				make_output("stream", { "log line" }),
				make_output("display_data", {}, { ["image/png"] = PNG_B64 }),
			})

			assert.equals(1, #placement_calls)
			local marks = get_virt_lines_marks(buf)
			assert.equals(1, #marks)
			assert.same({ { { "log line", "Comment" } } }, marks[1][4].virt_lines)
		end)

		it("re-running show_output closes the prior image placements", function()
			install_snacks()
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })

			assert.equals(2, #placement_instances)
			assert.equals(1, placement_instances[1].closed)
			assert.equals(0, placement_instances[2].closed)
		end)

		it("clear_output closes image placements", function()
			install_snacks()
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.show_output(buf, cell, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })

			display.clear_output(buf, cell)

			assert.equals(1, placement_instances[1].closed)
		end)

		it("clear_all closes image placements across cells", function()
			install_snacks()
			display.setup({ image = { renderer = "snacks" } })
			local buf = make_buf({ "# %%", "a = 1", "# %%", "b = 2" })
			local c1 = make_cell(0, 2)
			local c2 = make_cell(2, 4)
			display.show_output(buf, c1, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })
			display.show_output(buf, c2, { make_output("display_data", {}, { ["image/png"] = PNG_B64 }) })

			display.clear_all(buf)

			assert.equals(1, placement_instances[1].closed)
			assert.equals(1, placement_instances[2].closed)
		end)
	end)

	describe("set_status", function()
		it("places an eol virt_text on the marker line", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.set_status(buf, cell, "busy")

			local marks = get_virt_text_marks(buf)
			assert.equals(1, #marks)
			-- start_row of the cell = marker line
			assert.equals(0, marks[1][2])
			assert.equals("eol", marks[1][4].virt_text_pos)
			assert.same({ { "[busy]", "DiagnosticInfo" } }, marks[1][4].virt_text)
		end)

		it("replaces a prior status with the new one", function()
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.set_status(buf, cell, "busy")
			display.set_status(buf, cell, "error")

			local marks = get_virt_text_marks(buf)
			assert.equals(1, #marks)
			assert.same({ { "[error]", "DiagnosticError" } }, marks[1][4].virt_text)
		end)

		it("uses the configured highlight for each state", function()
			display.setup({ status_hl = { idle = "Special" } })
			local buf = make_buf({ "# %%", "x = 1" })
			local cell = make_cell(0, 2)
			display.set_status(buf, cell, "idle")

			local marks = get_virt_text_marks(buf)
			assert.same({ { "[idle]", "Special" } }, marks[1][4].virt_text)
		end)
	end)
end)
