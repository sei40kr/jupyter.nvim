---@diagnostic disable: undefined-field
-- Make the workspace's queries/ directory discoverable so the cell
-- module can resolve queries/python/jupyter.scm via runtimepath.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local cell = require("jupyter.cell")

---@param lines string[]
---@return integer
local function make_buf(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return bufnr
end

---@param bufnr integer
---@return string[]
local function buf_lines(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---Set up a buffer in the current window with the cursor placed at
---the given 0-indexed row.
---@param lines string[]
---@param row integer
---@return integer bufnr, integer winid
local function setup_window(lines, row)
	local bufnr = make_buf(lines)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	vim.api.nvim_win_set_cursor(winid, { row + 1, 0 })
	return bufnr, winid
end

---@param winid integer
---@return integer
local function cursor_row(winid)
	return vim.api.nvim_win_get_cursor(winid)[1] - 1
end

describe("jupyter.cell manipulation", function()
	describe("next_cell", function()
		it("moves from inside a cell to the next cell's body", function()
			local _, win = setup_window({
				"# %%", -- 0
				"x = 1", -- 1
				"# %%", -- 2
				"y = 2", -- 3
			}, 1)
			assert.is_true(cell.next_cell(vim.api.nvim_win_get_buf(win), win))
			assert.equals(3, cursor_row(win))
		end)

		it("moves to the cell after the marker the cursor is on", function()
			local _, win = setup_window({
				"# %%", -- 0
				"x = 1", -- 1
				"# %%", -- 2
				"y = 2", -- 3
			}, 0)
			assert.is_true(cell.next_cell(vim.api.nvim_win_get_buf(win), win))
			assert.equals(3, cursor_row(win))
		end)

		it("returns false at the bottom of the buffer", function()
			local _, win = setup_window({
				"# %%",
				"x = 1",
			}, 1)
			assert.is_false(cell.next_cell(vim.api.nvim_win_get_buf(win), win))
			assert.equals(1, cursor_row(win))
		end)

		it("skips leading blank lines inside the next cell", function()
			local _, win = setup_window({
				"# %%", -- 0
				"x = 1", -- 1
				"# %%", -- 2
				"", -- 3
				"y = 2", -- 4
			}, 1)
			assert.is_true(cell.next_cell(vim.api.nvim_win_get_buf(win), win))
			assert.equals(4, cursor_row(win))
		end)
	end)

	describe("prev_cell", function()
		it("moves from inside a cell to the previous cell's body", function()
			local _, win = setup_window({
				"# %%", -- 0
				"x = 1", -- 1
				"# %%", -- 2
				"y = 2", -- 3
			}, 3)
			assert.is_true(cell.prev_cell(vim.api.nvim_win_get_buf(win), win))
			assert.equals(1, cursor_row(win))
		end)

		it("moves from a marker to the previous cell", function()
			local _, win = setup_window({
				"# %%", -- 0
				"x = 1", -- 1
				"# %%", -- 2
				"y = 2", -- 3
			}, 2)
			assert.is_true(cell.prev_cell(vim.api.nvim_win_get_buf(win), win))
			assert.equals(1, cursor_row(win))
		end)

		it("returns false at the top of the buffer", function()
			local _, win = setup_window({
				"# %%",
				"x = 1",
			}, 0)
			assert.is_false(cell.prev_cell(vim.api.nvim_win_get_buf(win), win))
			assert.equals(0, cursor_row(win))
		end)
	end)

	describe("insert_cell", function()
		it("inserts a code cell below the current one", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"# %% B",
				"content_b",
			})
			local content_row = cell.insert_cell(buf, 1, "below", "code")
			assert.same({
				"# %% A",
				"content_a",
				"",
				"# %%",
				"",
				"# %% B",
				"content_b",
			}, buf_lines(buf))
			assert.equals(4, content_row)
		end)

		it("inserts a code cell above the current one", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"# %% B",
				"content_b",
			})
			local content_row = cell.insert_cell(buf, 2, "above", "code")
			assert.same({
				"# %% A",
				"content_a",
				"",
				"# %%",
				"",
				"# %% B",
				"content_b",
			}, buf_lines(buf))
			assert.equals(4, content_row)
		end)

		it("does not duplicate an existing blank separator", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"",
				"# %% B",
				"content_b",
			})
			cell.insert_cell(buf, 0, "below", "code")
			assert.same({
				"# %% A",
				"content_a",
				"",
				"# %%",
				"",
				"# %% B",
				"content_b",
			}, buf_lines(buf))
		end)

		it("omits the leading blank when inserting at the top of the buffer", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
			})
			local content_row = cell.insert_cell(buf, 0, "above", "code")
			assert.same({
				"# %%",
				"",
				"# %% A",
				"content_a",
			}, buf_lines(buf))
			assert.equals(1, content_row)
		end)

		it("inserts a markdown marker when cell_type is markdown", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
			})
			cell.insert_cell(buf, 0, "below", "markdown")
			assert.same({
				"# %% A",
				"content_a",
				"",
				"# %% [markdown]",
				"",
			}, buf_lines(buf))
		end)
	end)

	describe("delete_cell", function()
		it("removes a middle cell", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"# %% B",
				"content_b",
				"# %% C",
				"content_c",
			})
			cell.delete_cell(buf, 2)
			assert.same({
				"# %% A",
				"content_a",
				"# %% C",
				"content_c",
			}, buf_lines(buf))
		end)

		it("removes the first cell", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"# %% B",
				"content_b",
			})
			cell.delete_cell(buf, 0)
			assert.same({
				"# %% B",
				"content_b",
			}, buf_lines(buf))
		end)

		it("removes the last cell", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"# %% B",
				"content_b",
			})
			cell.delete_cell(buf, 2)
			assert.same({
				"# %% A",
				"content_a",
			}, buf_lines(buf))
		end)

		it("removes the only cell, leaving an empty buffer", function()
			local buf = make_buf({
				"# %%",
				"x = 1",
			})
			cell.delete_cell(buf, 0)
			assert.same({ "" }, buf_lines(buf))
		end)

		it("collapses adjacent blank lines around the deletion site", function()
			local buf = make_buf({
				"preamble",
				"",
				"",
				"# %% A",
				"content_a",
				"# %% B",
				"content_b",
			})
			cell.delete_cell(buf, 3)
			assert.same({
				"preamble",
				"",
				"# %% B",
				"content_b",
			}, buf_lines(buf))
		end)
	end)

	describe("merge_with_prev", function()
		it("merges two same-type cells, dropping the second marker", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"# %% B",
				"content_b",
			})
			cell.merge_with_prev(buf, 2)
			assert.same({
				"# %% A",
				"content_a",
				"content_b",
			}, buf_lines(buf))
		end)

		it("raises when cell types differ", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
				"# %% [markdown]",
				"# heading",
			})
			assert.has_error(function()
				cell.merge_with_prev(buf, 2)
			end)
		end)

		it("raises when the cell has no previous cell", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
			})
			assert.has_error(function()
				cell.merge_with_prev(buf, 0)
			end)
		end)
	end)

	describe("split_at", function()
		it("splits a code cell at the given row", function()
			local buf = make_buf({
				"# %% A",
				"line_1",
				"line_2",
				"line_3",
			})
			cell.split_at(buf, 2)
			assert.same({
				"# %% A",
				"line_1",
				"# %%",
				"line_2",
				"line_3",
			}, buf_lines(buf))
		end)

		it("preserves cell type when splitting a markdown cell", function()
			local buf = make_buf({
				"# %% [markdown]",
				"# heading",
				"body line",
			})
			cell.split_at(buf, 2)
			assert.same({
				"# %% [markdown]",
				"# heading",
				"# %% [markdown]",
				"body line",
			}, buf_lines(buf))
		end)

		it("raises when the split row is the cell's marker", function()
			local buf = make_buf({
				"# %% A",
				"content_a",
			})
			assert.has_error(function()
				cell.split_at(buf, 0)
			end)
		end)
	end)

	describe("cell_range", function()
		it("returns the marker plus body for outer scope", function()
			local buf = make_buf({
				"# %% A", -- 0
				"line_1", -- 1
				"line_2", -- 2
				"# %% B", -- 3
				"line_3", -- 4
			})
			local s, e = cell.cell_range(buf, 1, "outer")
			assert.equals(0, s)
			assert.equals(2, e)
		end)

		it("excludes the marker for inner scope", function()
			local buf = make_buf({
				"# %% A", -- 0
				"line_1", -- 1
				"line_2", -- 2
				"# %% B", -- 3
				"line_3", -- 4
			})
			local s, e = cell.cell_range(buf, 1, "inner")
			assert.equals(1, s)
			assert.equals(2, e)
		end)
	end)
end)
