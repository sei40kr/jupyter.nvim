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

describe("jupyter.cell", function()
	describe("get_all_cells", function()
		it("returns one implicit code cell when there are no markers", function()
			local buf = make_buf({
				"import sys",
				"x = 1",
			})
			local cells = cell.get_all_cells(buf)
			assert.equals(1, #cells)
			assert.equals("code", cells[1].cell_type)
			assert.equals(0, cells[1].start_row)
			assert.equals(2, cells[1].end_row)
			assert.same({ "import sys", "x = 1" }, cells[1].source)
		end)

		it("splits the buffer at every # %% marker", function()
			local buf = make_buf({
				"preamble",
				"# %%",
				"x = 1",
				"y = 2",
				"# %%",
				"z = 3",
			})
			local cells = cell.get_all_cells(buf)
			assert.equals(2, #cells)

			assert.equals("code", cells[1].cell_type)
			assert.equals(1, cells[1].start_row)
			assert.equals(4, cells[1].end_row)
			assert.same({ "# %%", "x = 1", "y = 2" }, cells[1].source)

			assert.equals("code", cells[2].cell_type)
			assert.equals(4, cells[2].start_row)
			assert.equals(6, cells[2].end_row)
			assert.same({ "# %%", "z = 3" }, cells[2].source)
		end)

		it("treats # %% [markdown] as a markdown cell", function()
			local buf = make_buf({
				"# %% [markdown]",
				"# Heading",
				"# %%",
				"x = 1",
			})
			local cells = cell.get_all_cells(buf)
			assert.equals(2, #cells)
			assert.equals("markdown", cells[1].cell_type)
			assert.equals("code", cells[2].cell_type)
		end)

		it("produces a cell when the buffer contains only a markdown marker", function()
			local buf = make_buf({
				"# %% [markdown]",
				"# Title",
				"# Body",
			})
			local cells = cell.get_all_cells(buf)
			assert.equals(1, #cells)
			assert.equals("markdown", cells[1].cell_type)
			assert.equals(0, cells[1].start_row)
			assert.equals(3, cells[1].end_row)
		end)

		it("keeps trailing blank lines inside the last cell", function()
			local buf = make_buf({
				"# %%",
				"x = 1",
				"",
				"",
			})
			local cells = cell.get_all_cells(buf)
			assert.equals(1, #cells)
			assert.equals(0, cells[1].start_row)
			assert.equals(4, cells[1].end_row)
			assert.same({ "# %%", "x = 1", "", "" }, cells[1].source)
		end)

		it("recognises a marker with an optional title", function()
			local buf = make_buf({
				"# %% Setup",
				"import sys",
				"# %% [markdown] Section header",
				"# Heading",
			})
			local cells = cell.get_all_cells(buf)
			assert.equals(2, #cells)
			assert.equals("code", cells[1].cell_type)
			assert.equals("markdown", cells[2].cell_type)
		end)
	end)

	describe("get_cell_at", function()
		local buf

		before_each(function()
			buf = make_buf({
				"preamble", -- 0
				"# %%", -- 1
				"x = 1", -- 2
				"# %% [markdown]", -- 3
				"# heading", -- 4
			})
		end)

		it("returns nil for a row in the preamble", function()
			assert.is_nil(cell.get_cell_at(buf, 0))
		end)

		it("returns the cell that contains a row inside it", function()
			local c = cell.get_cell_at(buf, 2)
			assert.is_not_nil(c)
			---@cast c jupyter.Cell
			assert.equals("code", c.cell_type)
			assert.equals(1, c.start_row)
			assert.equals(3, c.end_row)
		end)

		it("treats the marker line itself as the first line of its cell", function()
			local c = cell.get_cell_at(buf, 1)
			assert.is_not_nil(c)
			---@cast c jupyter.Cell
			assert.equals(1, c.start_row)
			assert.equals("code", c.cell_type)
		end)

		it("treats a row on a marker boundary as the start of the next cell", function()
			local c = cell.get_cell_at(buf, 3)
			assert.is_not_nil(c)
			---@cast c jupyter.Cell
			assert.equals("markdown", c.cell_type)
			assert.equals(3, c.start_row)
			assert.equals(5, c.end_row)
		end)
	end)
end)
