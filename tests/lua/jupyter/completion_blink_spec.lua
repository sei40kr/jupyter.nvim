---@diagnostic disable: undefined-field, duplicate-set-field
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

package.loaded["jupyter.completion.blink"] = nil
package.loaded["jupyter.completion"] = nil
local completion = require("jupyter.completion")
local blink_source = require("jupyter.completion.blink")

local original_complete_at_cursor = completion.complete_at_cursor

---@param items jupyter.CompletionItem[]?
---@param cell jupyter.Cell?
local function stub_complete(items, cell)
	completion.complete_at_cursor = function()
		return items, cell
	end
end

---@param err string
local function stub_complete_throws(err)
	completion.complete_at_cursor = function()
		error(err)
	end
end

---@param lines string[]
---@param row integer
---@param col integer
---@return integer bufnr
local function setup_window(lines, row, col)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.api.nvim_win_set_cursor(winid, { row + 1, col })
	return bufnr
end

---@param bufnr integer
---@param row integer
---@param col integer
local function fake_ctx(bufnr, row, col)
	return {
		bufnr = bufnr,
		cursor = { row + 1, col },
	}
end

describe("jupyter.completion.blink provider", function()
	after_each(function()
		completion.complete_at_cursor = original_complete_at_cursor
	end)

	it("advertises '.' and '[' as trigger characters", function()
		local p = blink_source.new()
		assert.same({ ".", "[" }, p:get_trigger_characters())
	end)

	describe("enabled", function()
		it("returns false when the buffer has no kernel", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = nil

			local p = blink_source.new()
			assert.is_false(p:enabled({ bufnr = bufnr }))
		end)

		it("returns true when a kernel is attached", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = { complete = function() end }

			local p = blink_source.new()
			assert.is_true(p:enabled({ bufnr = bufnr }))
		end)
	end)

	describe("get_completions", function()
		it("invokes the callback with mapped items in the blink shape", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = { complete = function() end }

			stub_complete({
				{ label = "x", kind = CompletionItemKind.Variable, range = { start = 0, ["end"] = 1 } },
				{ label = "MAX(", kind = CompletionItemKind.Function, range = { start = 0, ["end"] = 1 } },
			}, nil)

			local p = blink_source.new()
			local got
			p:get_completions(fake_ctx(bufnr, 1, 1), function(response)
				got = response
			end)

			assert.is_not_nil(got)
			assert.is_false(got.is_incomplete_forward)
			assert.is_false(got.is_incomplete_backward)
			assert.equals(2, #got.items)

			local item1 = got.items[1]
			assert.equals("x", item1.label)
			assert.equals(CompletionItemKind.Variable, item1.kind)
			assert.equals("x", item1.insertText)
			assert.same({
				range = {
					start = { line = 1, character = 0 },
					["end"] = { line = 1, character = 1 },
				},
				newText = "x",
			}, item1.textEdit)

			local item2 = got.items[2]
			assert.equals("MAX(", item2.label)
			assert.equals(CompletionItemKind.Function, item2.kind)
			assert.equals("MAX(", item2.insertText)
			assert.equals("MAX(", item2.textEdit.newText)
		end)

		it("invokes the callback with empty items when shared logic returns nil", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = nil

			stub_complete(nil, nil)

			local p = blink_source.new()
			local got
			p:get_completions(fake_ctx(bufnr, 1, 1), function(response)
				got = response
			end)

			assert.same({
				items = {},
				is_incomplete_forward = false,
				is_incomplete_backward = false,
			}, got)
		end)

		it("invokes the callback with empty items when the shared logic throws", function()
			local bufnr = setup_window({ "# %%", "x = 1" }, 1, 1)
			vim.b[bufnr].jupyter_kernel = { complete = function() end }

			stub_complete_throws("boom")

			local p = blink_source.new()
			local got
			p:get_completions(fake_ctx(bufnr, 1, 1), function(response)
				got = response
			end)

			assert.same({
				items = {},
				is_incomplete_forward = false,
				is_incomplete_backward = false,
			}, got)
		end)
	end)
end)
