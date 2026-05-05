---@diagnostic disable: undefined-field
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

package.loaded["jupyter.completion.cmp"] = nil
package.loaded["jupyter.completion"] = nil
local cmp_source = require("jupyter.completion.cmp")

---@param lines string[]
---@param row integer
---@param col integer
---@return integer bufnr, integer winid
local function setup_window(lines, row, col)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.api.nvim_win_set_cursor(winid, { row + 1, col })
	return bufnr, winid
end

---@param response jupyter_core.CompletionResult
local function fake_kernel(response)
	return {
		complete = function(_, _, _)
			return response
		end,
	}
end

---@param bufnr integer
---@param row integer
---@param col integer
local function fake_params(bufnr, row, col)
	return {
		context = {
			bufnr = bufnr,
			cursor = { row = row + 1, col = col },
		},
	}
end

describe("jupyter.completion.cmp source", function()
	it("get_debug_name returns 'jupyter'", function()
		local s = cmp_source.new()
		assert.equals("jupyter", s:get_debug_name())
	end)

	it("advertises '.' and '[' as trigger characters", function()
		local s = cmp_source.new()
		local triggers = s:get_trigger_characters()
		assert.same({ ".", "[" }, triggers)
	end)

	describe("is_available", function()
		it("returns false when the buffer has no kernel", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = nil

			local s = cmp_source.new()
			assert.is_false(s:is_available())
		end)

		it("returns true when a kernel is attached and cursor is in a cell", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = fake_kernel({ matches = {}, cursor_start = 0, cursor_end = 0 })

			local s = cmp_source.new()
			assert.is_true(s:is_available())
		end)

		it("returns false when the cursor is in the preamble", function()
			local bufnr = setup_window({ "preamble", "# %%", "x = 1" }, 0, 0)
			vim.b[bufnr].jupyter_kernel = fake_kernel({ matches = {}, cursor_start = 0, cursor_end = 0 })

			local s = cmp_source.new()
			assert.is_false(s:is_available())
		end)
	end)

	describe("complete", function()
		it("invokes the callback with mapped items shaped for cmp", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = fake_kernel({
				matches = { "x", "MAX(" },
				cursor_start = 0,
				cursor_end = 1,
			})

			local s = cmp_source.new()
			local got
			s:complete(fake_params(bufnr, 1, 1), function(response)
				got = response
			end)

			assert.is_not_nil(got)
			assert.is_false(got.isIncomplete)
			assert.equals(2, #got.items)

			local item1 = got.items[1]
			assert.equals("x", item1.label)
			assert.equals(CompletionItemKind.Variable, item1.kind)
			assert.same({
				range = {
					start = { line = 1, character = 0 },
					["end"] = { line = 1, character = 1 },
				},
				newText = "x",
			}, item1.textEdit)

			local item2 = got.items[2]
			assert.equals(CompletionItemKind.Function, item2.kind)
			assert.equals("MAX(", item2.textEdit.newText)
		end)

		it("invokes the callback with empty items when no kernel is present", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = nil

			local s = cmp_source.new()
			local got
			s:complete(fake_params(bufnr, 1, 1), function(response)
				got = response
			end)

			assert.same({ items = {}, isIncomplete = false }, got)
		end)

		it("invokes the callback with empty items when cursor is outside any cell", function()
			local bufnr = setup_window({ "preamble", "# %%", "x = 1" }, 0, 0)
			vim.b[bufnr].jupyter_kernel = fake_kernel({ matches = { "x" }, cursor_start = 0, cursor_end = 0 })

			local s = cmp_source.new()
			local got
			s:complete(fake_params(bufnr, 0, 0), function(response)
				got = response
			end)

			assert.same({ items = {}, isIncomplete = false }, got)
		end)
	end)
end)
