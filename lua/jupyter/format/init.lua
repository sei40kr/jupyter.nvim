---``BufReadCmd`` / ``BufWriteCmd`` glue for ``.ipynb`` files.
---
---On read: parse the JSON, expand cells into percent format, set the
---buffer's filetype from the document's kernel language, and stash the
---original document on a buffer-local var so that outputs and metadata
---survive subsequent saves.
---
---On write: read the buffer back through ``jupyter.cell``, decode each
---cell into source-only form, merge with the stashed original, and
---re-serialise to JSON. New buffers (no file on disk yet) start from an
---empty document skeleton.

local cell = require("jupyter.cell")
local ipynb = require("jupyter.format.ipynb")
local percent = require("jupyter.format.percent")

local M = {}

local AUGROUP_NAME = "jupyter.format"
local STATE_VAR = "jupyter_ipynb"
local DEFAULT_FILETYPE = "python"

---Empty ipynb skeleton used for buffers whose file does not exist yet.
---@return jupyter.format.IpynbDoc
local function empty_doc()
	return {
		nbformat = 4,
		nbformat_minor = 5,
		metadata = {},
		cells = {},
	}
end

---@param bufnr integer
---@param doc jupyter.format.IpynbDoc
local function set_state(bufnr, doc)
	vim.b[bufnr][STATE_VAR] = doc
end

---@param bufnr integer
---@return jupyter.format.IpynbDoc?
local function get_state(bufnr)
	return vim.b[bufnr][STATE_VAR]
end

---@param bufnr integer
---@param path string
local function read_ipynb(bufnr, path)
	if path == "" or vim.fn.filereadable(path) == 0 then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
		set_state(bufnr, empty_doc())
		if vim.bo[bufnr].filetype == "" then
			vim.bo[bufnr].filetype = DEFAULT_FILETYPE
		end
		vim.bo[bufnr].modified = false
		return
	end

	local doc = ipynb.read(path)
	local lines = ipynb.to_percent_lines(doc)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].filetype = ipynb.detect_filetype(doc) or DEFAULT_FILETYPE
	set_state(bufnr, doc)
	vim.bo[bufnr].modified = false
end

---@param bufnr integer
---@param path string
local function write_ipynb(bufnr, path)
	if path == "" then
		error("jupyter.format: cannot write — buffer has no associated path")
	end
	local original = get_state(bufnr) or empty_doc()

	---@type jupyter.format.SourceCell[]
	local source_cells = {}
	for _, c in ipairs(cell.get_all_cells(bufnr)) do
		source_cells[#source_cells + 1] = percent.from_cell(c)
	end

	local merged = ipynb.merge(original, source_cells)
	ipynb.write(merged, path)
	set_state(bufnr, merged)
	vim.bo[bufnr].modified = false
end

---Register the BufReadCmd / BufWriteCmd autocmds. Idempotent — the
---augroup is cleared on every call so re-running ``setup`` does not
---stack handlers.
function M.setup()
	local group = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = group,
		pattern = "*.ipynb",
		callback = function(args)
			read_ipynb(args.buf, vim.api.nvim_buf_get_name(args.buf))
		end,
	})
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		pattern = "*.ipynb",
		callback = function(args)
			write_ipynb(args.buf, vim.api.nvim_buf_get_name(args.buf))
		end,
	})
end

return M
