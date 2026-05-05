---@diagnostic disable: undefined-field
-- Make queries/python/jupyter.scm reachable through runtimepath so
-- jupyter.cell can resolve its Treesitter query.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

package.loaded["jupyter.completion"] = nil
local completion = require("jupyter.completion")

---@param lines string[]
---@return integer
local function make_buf(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return bufnr
end

---@param lines string[]
---@param row integer
---@param col integer
---@return integer bufnr, integer winid
local function setup_window(lines, row, col)
	local bufnr = make_buf(lines)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.api.nvim_win_set_cursor(winid, { row + 1, col })
	return bufnr, winid
end

---Build a fake kernel that records the most recent ``complete`` call
---and returns a configurable response. ``vim.b[bufnr]`` round-trips
---tables through Vim variables (each read returns a copy), so the
---log is captured via a closure variable rather than on the kernel
---table itself.
---@class jupyter.completion.test.Log
---@field last {code: string, cursor_pos: integer}?

---@param response jupyter_core.CompletionResult
---@return table, jupyter.completion.test.Log
local function fake_kernel(response)
	---@type jupyter.completion.test.Log
	local log = { last = nil }
	local kernel = {
		complete = function(_, code, cursor_pos)
			log.last = { code = code, cursor_pos = cursor_pos }
			return response
		end,
	}
	return kernel, log
end

describe("jupyter.completion._kind_for", function()
	it("classifies callables ending with '(' as Function", function()
		assert.equals(CompletionItemKind.Function, completion._kind_for("foo("))
	end)

	it("classifies all-uppercase names as Constant", function()
		assert.equals(CompletionItemKind.Constant, completion._kind_for("MAX_SIZE"))
		assert.equals(CompletionItemKind.Constant, completion._kind_for("X"))
	end)

	it("falls back to Variable for ordinary identifiers", function()
		assert.equals(CompletionItemKind.Variable, completion._kind_for("foo"))
		assert.equals(CompletionItemKind.Variable, completion._kind_for("DataFrame"))
	end)
end)

describe("jupyter.completion.complete_at_cursor", function()
	it("returns nil when the buffer has no kernel", function()
		local bufnr, winid = setup_window({ "# %%", "x = 1" }, 1, 1)
		vim.b[bufnr].jupyter_kernel = nil

		local items, cell = completion.complete_at_cursor(bufnr, winid)
		assert.is_nil(items)
		assert.is_nil(cell)
	end)

	it("returns nil when the cursor falls in the preamble (no cell)", function()
		local bufnr, winid = setup_window({ "preamble", "# %%", "x = 1" }, 0, 0)
		local kernel = fake_kernel({ matches = {}, cursor_start = 0, cursor_end = 0 })
		vim.b[bufnr].jupyter_kernel = kernel

		local items, cell = completion.complete_at_cursor(bufnr, winid)
		assert.is_nil(items)
		assert.is_nil(cell)
	end)

	it("maps kernel matches into items sharing one byte range", function()
		local bufnr, winid = setup_window({ "# %%", "x = 1" }, 1, 1)
		local kernel = fake_kernel({
			matches = { "x", "xrange", "MAX(", "PI" },
			cursor_start = 0,
			cursor_end = 1,
		})
		vim.b[bufnr].jupyter_kernel = kernel

		local items, cell = completion.complete_at_cursor(bufnr, winid)
		assert.is_not_nil(items)
		---@cast items jupyter.CompletionItem[]
		assert.equals(4, #items)

		assert.equals("x", items[1].label)
		assert.equals(CompletionItemKind.Variable, items[1].kind)
		assert.same({ start = 0, ["end"] = 1 }, items[1].range)

		assert.equals(CompletionItemKind.Variable, items[2].kind)
		assert.equals(CompletionItemKind.Function, items[3].kind)
		assert.equals(CompletionItemKind.Constant, items[4].kind)

		-- All items share the same range object reference / value.
		for _, item in ipairs(items) do
			assert.same({ start = 0, ["end"] = 1 }, item.range)
		end

		assert.is_not_nil(cell)
		---@cast cell jupyter.Cell
		assert.equals(0, cell.start_row)
	end)

	it("passes the joined cell source and cursor byte offset to the kernel", function()
		local bufnr, winid = setup_window({
			"# %%", -- 0
			"x = 1", -- 1
			"y = 2", -- 2
		}, 2, 1)
		local kernel, log = fake_kernel({ matches = {}, cursor_start = 0, cursor_end = 0 })
		vim.b[bufnr].jupyter_kernel = kernel

		completion.complete_at_cursor(bufnr, winid)

		assert.is_not_nil(log.last)
		assert.equals("# %%\nx = 1\ny = 2", log.last.code)
		-- "# %%" (4) + "\n" (1) + "x = 1" (5) + "\n" (1) + col 1 = 12
		assert.equals(12, log.last.cursor_pos)
	end)

	it("computes a byte-correct cursor offset across multibyte lines", function()
		-- "あ" is 3 bytes in UTF-8.
		local bufnr, winid = setup_window({
			"# %%", -- 0   "# %%"            (4 bytes)
			"あ = 1", -- 1  "あ = 1"          (3 + 4 = 7 bytes)
			"y = 2", -- 2   "y = 2"           (5 bytes)
		}, 2, 1)
		local kernel, log = fake_kernel({ matches = {}, cursor_start = 0, cursor_end = 0 })
		vim.b[bufnr].jupyter_kernel = kernel

		completion.complete_at_cursor(bufnr, winid)

		-- Offsets: "# %%"(4) + "\n"(1) + "あ = 1"(7) + "\n"(1) + col 1 = 14
		assert.equals(14, log.last.cursor_pos)
	end)
end)
