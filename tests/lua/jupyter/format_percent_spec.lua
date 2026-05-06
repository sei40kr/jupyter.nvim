---@diagnostic disable: undefined-field
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local cell = require("jupyter.cell")
local percent = require("jupyter.format.percent")

---@param filetype string
---@param lines string[]
---@return integer
local function make_buf(filetype, lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = filetype
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	return bufnr
end

describe("jupyter.format.percent", function()
	describe("cells_to_lines", function()
		it("emits a marker followed by source for each code cell", function()
			local lines = percent.cells_to_lines({
				{ cell_type = "code", source = { "x = 1" } },
				{ cell_type = "code", source = { 'print("hi")' } },
			})
			assert.same({
				"# %%",
				"x = 1",
				"",
				"# %%",
				'print("hi")',
			}, lines)
		end)

		it("wraps markdown body lines in the line-comment prefix", function()
			local lines = percent.cells_to_lines({
				{ cell_type = "markdown", source = { "Hello", "", "World" } },
			})
			assert.same({
				"# %% [markdown]",
				"# Hello",
				"#",
				"# World",
			}, lines)
		end)

		it("emits no separator before the first cell", function()
			local lines = percent.cells_to_lines({
				{ cell_type = "code", source = { "x = 1" } },
			})
			assert.same({ "# %%", "x = 1" }, lines)
		end)

		it("returns an empty list for no cells", function()
			assert.same({}, percent.cells_to_lines({}))
		end)
	end)

	describe("from_cell", function()
		it("strips the marker line from a code cell", function()
			local buf = make_buf("python", { "# %%", "x = 1", "y = 2" })
			local result = percent.from_cell(cell.get_all_cells(buf)[1])
			assert.equals("code", result.cell_type)
			assert.same({ "x = 1", "y = 2" }, result.source)
		end)

		it("trims trailing blank lines used as cell separators", function()
			local buf = make_buf("python", { "# %%", "x = 1", "", "" })
			local result = percent.from_cell(cell.get_all_cells(buf)[1])
			assert.same({ "x = 1" }, result.source)
		end)

		it("keeps the first line when the cell has no marker", function()
			local buf = make_buf("python", { "x = 1", "y = 2" })
			local result = percent.from_cell(cell.get_all_cells(buf)[1])
			assert.same({ "x = 1", "y = 2" }, result.source)
		end)

		it("decodes the markdown line-comment prefix", function()
			local buf = make_buf("python", {
				"# %% [markdown]",
				"# Hello",
				"#",
				"# World",
			})
			local result = percent.from_cell(cell.get_all_cells(buf)[1])
			assert.equals("markdown", result.cell_type)
			assert.same({ "Hello", "", "World" }, result.source)
		end)

		it("round-trips ipynb cells through cells_to_lines and back", function()
			local original = {
				{ cell_type = "markdown", source = { "Title", "", "Body" } },
				{ cell_type = "code", source = { "import sys", "x = 1" } },
				{ cell_type = "code", source = { "y = 2" } },
			}
			local lines = percent.cells_to_lines(original)
			local buf = make_buf("python", lines)
			---@type jupyter.format.SourceCell[]
			local roundtripped = {}
			for _, c in ipairs(cell.get_all_cells(buf)) do
				roundtripped[#roundtripped + 1] = percent.from_cell(c)
			end
			assert.same(original, roundtripped)
		end)
	end)
end)
