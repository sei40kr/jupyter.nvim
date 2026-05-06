---@diagnostic disable: undefined-field
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local ipynb = require("jupyter.format.ipynb")

---@return jupyter.format.IpynbDoc
local function sample_doc()
	return {
		nbformat = 4,
		nbformat_minor = 5,
		metadata = {
			kernelspec = { name = "python3", display_name = "Python 3", language = "python" },
		},
		cells = {
			{
				cell_type = "markdown",
				source = { "# Title\n", "\n", "Body" },
				id = "abc12345",
				metadata = {},
			},
			{
				cell_type = "code",
				source = { "x = 1\n", "x" },
				id = "code0001",
				metadata = {},
				outputs = {
					{ output_type = "execute_result", data = { ["text/plain"] = "1" }, execution_count = 1 },
				},
				execution_count = 1,
			},
		},
	}
end

describe("jupyter.format.ipynb", function()
	describe("to_percent_lines", function()
		it("renders cells with markdown unwrapping and separators", function()
			local doc = sample_doc()
			assert.same({
				"# %% [markdown]",
				"# # Title",
				"#",
				"# Body",
				"",
				"# %%",
				"x = 1",
				"x",
			}, ipynb.to_percent_lines(doc))
		end)
	end)

	describe("detect_filetype", function()
		it("maps kernelspec.language to a filetype", function()
			assert.equals("python", ipynb.detect_filetype(sample_doc()))
		end)

		it("falls back to language_info.name", function()
			local doc = { metadata = { language_info = { name = "Julia" } }, cells = {} }
			assert.equals("julia", ipynb.detect_filetype(doc --[[@as jupyter.format.IpynbDoc]]))
		end)

		it("returns nil for unknown languages", function()
			local doc = { metadata = { kernelspec = { language = "haskell" } }, cells = {} }
			assert.is_nil(ipynb.detect_filetype(doc --[[@as jupyter.format.IpynbDoc]]))
		end)
	end)

	describe("merge", function()
		it("preserves outputs when source is unchanged", function()
			local doc = sample_doc()
			local merged = ipynb.merge(doc, {
				{ cell_type = "markdown", source = { "# Title", "", "Body" } },
				{ cell_type = "code", source = { "x = 1", "x" } },
			})
			assert.equals("abc12345", merged.cells[1].id)
			assert.equals("code0001", merged.cells[2].id)
			assert.equals(1, merged.cells[2].execution_count)
			assert.equals(1, #merged.cells[2].outputs)
		end)

		it("drops outputs but keeps id when source changes", function()
			local doc = sample_doc()
			local merged = ipynb.merge(doc, {
				{ cell_type = "markdown", source = { "# Title", "", "Body" } },
				{ cell_type = "code", source = { "x = 2" } },
			})
			assert.equals("code0001", merged.cells[2].id)
			assert.is_nil(merged.cells[2].execution_count)
			assert.same({}, merged.cells[2].outputs)
		end)

		it("mints a new id when cell_type changes", function()
			local doc = sample_doc()
			local merged = ipynb.merge(doc, {
				{ cell_type = "code", source = { "code at slot 0" } },
				{ cell_type = "code", source = { "x = 1", "x" } },
			})
			assert.is_not_nil(merged.cells[1].id)
			assert.is_not.equals("abc12345", merged.cells[1].id)
			assert.same({}, merged.cells[1].outputs)
		end)

		it("creates fresh cells past the original tail", function()
			local doc = sample_doc()
			local merged = ipynb.merge(doc, {
				{ cell_type = "markdown", source = { "# Title", "", "Body" } },
				{ cell_type = "code", source = { "x = 1", "x" } },
				{ cell_type = "code", source = { "z = 3" } },
			})
			assert.equals(3, #merged.cells)
			assert.is_not_nil(merged.cells[3].id)
			assert.same({}, merged.cells[3].outputs)
		end)

		it("encodes source as nbformat array form", function()
			local doc = sample_doc()
			local merged = ipynb.merge(doc, {
				{ cell_type = "code", source = { "a", "b", "c" } },
			})
			assert.same({ "a\n", "b\n", "c" }, merged.cells[1].source)
		end)

		it("preserves unknown cell-level fields when source is unchanged", function()
			local doc = sample_doc()
			---@diagnostic disable-next-line: inject-field
			doc.cells[1].attachments = { ["image1.png"] = { ["image/png"] = "base64data" } }
			local merged = ipynb.merge(doc, {
				{ cell_type = "markdown", source = { "# Title", "", "Body" } },
				{ cell_type = "code", source = { "x = 1", "x" } },
			})
			assert.same({ ["image1.png"] = { ["image/png"] = "base64data" } }, merged.cells[1].attachments)
		end)
	end)

	describe("read/write round-trip", function()
		it("writes and reads back the same document content", function()
			local path = vim.fn.tempname() .. ".ipynb"
			local doc = sample_doc()
			ipynb.write(doc, path)
			local roundtripped = ipynb.read(path)
			assert.equals(doc.nbformat, roundtripped.nbformat)
			assert.equals(#doc.cells, #roundtripped.cells)
			assert.equals(doc.cells[1].cell_type, roundtripped.cells[1].cell_type)
			assert.equals(doc.cells[2].cell_type, roundtripped.cells[2].cell_type)
			assert.equals(doc.cells[1].id, roundtripped.cells[1].id)
			assert.equals("python", (roundtripped.metadata.kernelspec or {}).language)
			vim.uv.fs_unlink(path)
		end)

		it("emits empty cell metadata as a JSON object, not an array", function()
			local path = vim.fn.tempname() .. ".ipynb"
			ipynb.write({
				nbformat = 4,
				nbformat_minor = 5,
				metadata = vim.empty_dict(),
				cells = {
					{ cell_type = "code", source = { "x" } },
				},
			} --[[@as jupyter.format.IpynbDoc]], path)
			local fd = assert(vim.uv.fs_open(path, "r", 420))
			local stat = assert(vim.uv.fs_fstat(fd))
			local data = assert(vim.uv.fs_read(fd, stat.size, 0))
			vim.uv.fs_close(fd)
			vim.uv.fs_unlink(path)
			assert.is_truthy(data:match('"metadata":%s*{}'))
			assert.is_truthy(data:sub(-1) == "\n")
		end)
	end)
end)
