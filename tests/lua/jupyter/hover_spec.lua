---@diagnostic disable: undefined-field, unused-local
-- Make queries/ discoverable so jupyter.cell can find its Treesitter query.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

package.loaded["jupyter.hover"] = nil
local hover = require("jupyter.hover")

---@param lines string[]
---@return integer
local function make_buf(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return bufnr
end

---@param bufnr integer
---@param inspect fun(self: table, code: string, pos: integer): jupyter_core.InspectResult
local function set_kernel(bufnr, inspect)
	vim.b[bufnr].jupyter_kernel = { inspect = inspect }
end

---@param bufnr integer
local function clear_kernel(bufnr)
	vim.b[bufnr].jupyter_kernel = nil
end

---Replace ``vim.notify`` and ``vim.lsp.util.open_floating_preview`` with
---spies for the duration of ``fn``.
---@param fn fun(notify_calls: table[], fp_calls: table[])
local function with_spies(fn)
	local saved_notify = vim.notify
	local saved_fp = vim.lsp.util.open_floating_preview
	---@type table[]
	local notify_calls = {}
	---@type table[]
	local fp_calls = {}
	---@diagnostic disable-next-line: duplicate-set-field
	vim.notify = function(msg, level, opts)
		notify_calls[#notify_calls + 1] = { msg = msg, level = level, opts = opts }
	end
	---@diagnostic disable-next-line: duplicate-set-field
	vim.lsp.util.open_floating_preview = function(contents, syntax, opts)
		fp_calls[#fp_calls + 1] = { contents = contents, syntax = syntax, opts = opts }
		return 0, 0
	end
	local ok, err = pcall(fn, notify_calls, fp_calls)
	vim.notify = saved_notify
	vim.lsp.util.open_floating_preview = saved_fp
	if not ok then
		error(err, 0)
	end
end

---@param bufnr integer
---@param row integer  1-indexed
---@param col integer  0-indexed byte col
local function place_cursor(bufnr, row, col)
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { row, col })
end

describe("jupyter.hover", function()
	describe("hover", function()
		it("warns and bails when no kernel is attached", function()
			local buf = make_buf({ "# %%", "x = 1" })
			clear_kernel(buf)
			with_spies(function(notify_calls, fp_calls)
				place_cursor(buf, 2, 0)
				hover.hover(buf)
				assert.equals(0, #fp_calls)
				assert.equals(1, #notify_calls)
				assert.equals(vim.log.levels.WARN, notify_calls[1].level)
			end)
		end)

		it("notifies when the cursor is outside any cell", function()
			local buf = make_buf({ "preamble", "# %%", "x = 1" })
			set_kernel(buf, function(_self, _code, _pos)
				error("kernel:inspect should not be called when cursor has no cell")
			end)
			with_spies(function(notify_calls, fp_calls)
				place_cursor(buf, 1, 0) -- preamble row
				hover.hover(buf)
				assert.equals(0, #fp_calls)
				assert.equals(1, #notify_calls)
				assert.equals(vim.log.levels.INFO, notify_calls[1].level)
			end)
		end)

		it("notifies when the kernel reports no information", function()
			local buf = make_buf({ "# %%", "x = 1" })
			set_kernel(buf, function(_self, _code, _pos)
				return { found = false, data = {} }
			end)
			with_spies(function(notify_calls, fp_calls)
				place_cursor(buf, 2, 0)
				hover.hover(buf)
				assert.equals(0, #fp_calls)
				assert.equals(1, #notify_calls)
				assert.equals(vim.log.levels.INFO, notify_calls[1].level)
			end)
		end)

		it("opens a plaintext float with ANSI sequences stripped", function()
			local buf = make_buf({ "# %%", "x = 1" })
			set_kernel(buf, function(_self, _code, _pos)
				return {
					found = true,
					data = { ["text/plain"] = "\27[31mhello\27[0m world" },
				}
			end)
			with_spies(function(notify_calls, fp_calls)
				place_cursor(buf, 2, 0)
				hover.hover(buf)
				assert.equals(0, #notify_calls)
				assert.equals(1, #fp_calls)
				assert.equals("plaintext", fp_calls[1].syntax)
				assert.same({ "hello world" }, fp_calls[1].contents)
			end)
		end)

		it("opens a markdown float when the kernel returns text/markdown", function()
			local buf = make_buf({ "# %%", "x = 1" })
			set_kernel(buf, function(_self, _code, _pos)
				return {
					found = true,
					data = {
						["text/markdown"] = "# Heading\n\nbody",
						["text/plain"] = "ignored",
					},
				}
			end)
			with_spies(function(notify_calls, fp_calls)
				place_cursor(buf, 2, 0)
				hover.hover(buf)
				assert.equals(0, #notify_calls)
				assert.equals(1, #fp_calls)
				assert.equals("markdown", fp_calls[1].syntax)
				assert.same({ "# Heading", "", "body" }, fp_calls[1].contents)
			end)
		end)

		it("computes byte offset correctly across multibyte earlier lines", function()
			local buf = make_buf({
				"# %%", -- row 0, cell start (4 bytes)
				"x = '日本語'", -- row 1 (15 bytes)
				"y = foo", -- row 2
			})
			---@type integer?
			local got_pos = nil
			---@type string?
			local got_code = nil
			set_kernel(buf, function(_self, code, pos)
				got_code = code
				got_pos = pos
				return { found = false, data = {} }
			end)
			with_spies(function()
				place_cursor(buf, 3, 4) -- byte col 4 in "y = foo"
				hover.hover(buf)
			end)
			-- "# %%"        =  4 bytes + \n  =  5
			-- "x = '日本語'" = 15 bytes + \n  = 16  → cumulative 21
			-- col 4 in "y = foo"             =  4
			-- total                          = 25
			assert.equals("# %%\nx = '日本語'\ny = foo", got_code)
			assert.equals(25, got_pos)
		end)
	end)
end)
