---``.ipynb`` ↔ percent-format conversion.
---
---``read``/``write`` deal with the on-disk JSON. ``to_percent_lines``
---turns a parsed document into buffer lines via
---``jupyter.format.percent``. ``merge`` reconciles a percent buffer's
---cells with the original document, preserving outputs, ids, metadata,
---and execution counts on cells whose source has not changed.
---
---Cells are matched by *position* (and by ``cell_type``). Same source at
---the same position keeps everything; same cell_type with different
---source keeps the id but drops outputs; otherwise a fresh id is minted.
---This is simple, predictable, and matches what most ``.ipynb``-aware
---editors do — a smarter, content-based matcher can replace it later
---without changing the public surface.
---
---Known limitation: ``raw`` cells are not surfaced in the percent buffer
---and are dropped on save. nbformat allows them but they are rare in
---practice. A future revision can store them out-of-band on the doc and
---splice them back in during ``merge``.

local percent = require("jupyter.format.percent")

local M = {}

---@class jupyter.format.IpynbCell
---@field cell_type "code"|"markdown"
---@field source string[]               nbformat array form
---@field id string?
---@field metadata table?
---@field outputs table[]?
---@field execution_count integer?

---@class jupyter.format.IpynbDoc
---@field nbformat integer
---@field nbformat_minor integer
---@field metadata table
---@field cells jupyter.format.IpynbCell[]

---Decode nbformat ``source`` (string or string[]) into a flat list of
---lines without trailing newlines. The array form encodes each line with
---a trailing ``\n`` except the last; concatenating then splitting on
---``\n`` yields one synthetic empty entry when the source ends in ``\n``,
---which we drop so the buffer does not gain a spurious blank line.
---@param src string|string[]|nil
---@return string[]
local function source_to_lines(src)
	---@type string
	local s
	if type(src) == "table" then
		s = table.concat(src --[[@as string[] ]])
	elseif type(src) == "string" then
		s = src
	else
		s = ""
	end
	if s == "" then
		return {}
	end
	local lines = vim.split(s, "\n", { plain = true })
	if lines[#lines] == "" then
		lines[#lines] = nil
	end
	return lines
end

---Encode a flat list of body lines as nbformat array-form ``source``.
---@param lines string[]
---@return string[]
local function lines_to_source(lines)
	if #lines == 0 then
		return {}
	end
	---@type string[]
	local result = {}
	for i = 1, #lines - 1 do
		result[i] = lines[i] .. "\n"
	end
	result[#lines] = lines[#lines]
	return result
end

---Generate an opaque 8-character id for a freshly created cell.
---nbformat ``id`` requires only that ids are unique within a notebook;
---a short alphanumeric string is enough.
---@return string
local function new_cell_id()
	local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	---@type string[]
	local out = {}
	for i = 1, 8 do
		local idx = math.random(1, #chars)
		out[i] = chars:sub(idx, idx)
	end
	return table.concat(out)
end

---@param a string[]
---@param b string[]
---@return boolean
local function lines_equal(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

---Normalise a JSON ``source`` field (string, string[], or absent) to
---nbformat array form.
---@param src any
---@return string[]
local function normalise_source(src)
	if type(src) == "table" then
		return src --[[@as string[] ]]
	elseif type(src) == "string" then
		return { src }
	end
	return {}
end

---Read the ``.ipynb`` document at ``path``.
---
---Cells are stored verbatim (with ``source`` normalised to array form)
---so that fields we do not understand — ``attachments`` on markdown
---cells, future nbformat additions, etc. — round-trip unchanged.
---@param path string
---@return jupyter.format.IpynbDoc
function M.read(path)
	local fd, open_err = vim.uv.fs_open(path, "r", tonumber("644", 8))
	if fd == nil then
		error(("jupyter.format.ipynb: cannot open %s: %s"):format(path, open_err or "unknown"))
	end
	local stat = assert(vim.uv.fs_fstat(fd))
	local data = assert(vim.uv.fs_read(fd, stat.size, 0))
	vim.uv.fs_close(fd)

	local ok, decoded = pcall(vim.json.decode, data)
	if not ok then
		error(("jupyter.format.ipynb: %s is not valid JSON: %s"):format(path, decoded))
	end

	---@type jupyter.format.IpynbDoc
	local doc = {
		nbformat = decoded.nbformat or 4,
		nbformat_minor = decoded.nbformat_minor or 5,
		metadata = decoded.metadata or vim.empty_dict(),
		cells = {},
	}
	for _, raw in ipairs(decoded.cells or {}) do
		local cell_type = raw.cell_type
		if cell_type == "code" or cell_type == "markdown" then
			raw.source = normalise_source(raw.source)
			if raw.metadata == nil then
				raw.metadata = vim.empty_dict()
			end
			doc.cells[#doc.cells + 1] = raw
		end
	end
	return doc
end

---Serialise ``doc`` to JSON and write it to ``path``. nbformat-required
---fields are normalised on the way out: code cells gain an empty
---``outputs`` array and ``execution_count = null`` when missing, every
---cell carries ``metadata`` as a JSON object, and the file ends with a
---trailing newline to match the convention used by the Jupyter tooling.
---@param doc jupyter.format.IpynbDoc
---@param path string
function M.write(doc, path)
	---@type table[]
	local cells = {}
	for i, c in ipairs(doc.cells) do
		local out = vim.tbl_extend("force", {}, c)
		out.cell_type = c.cell_type
		out.source = c.source
		if out.metadata == nil then
			out.metadata = vim.empty_dict()
		end
		if c.cell_type == "code" then
			out.outputs = c.outputs or {}
			if c.execution_count == nil then
				out.execution_count = vim.NIL
			end
		end
		cells[i] = out
	end

	local payload = {
		cells = cells,
		metadata = doc.metadata or vim.empty_dict(),
		nbformat = doc.nbformat or 4,
		nbformat_minor = doc.nbformat_minor or 5,
	}
	local encoded = vim.json.encode(payload) .. "\n"

	local fd, err = vim.uv.fs_open(path, "w", tonumber("644", 8))
	if fd == nil then
		error(("jupyter.format.ipynb: cannot open %s for writing: %s"):format(path, err or "unknown"))
	end
	assert(vim.uv.fs_write(fd, encoded, 0))
	vim.uv.fs_close(fd)
end

---Convert ``doc``'s cells into percent-format buffer lines.
---@param doc jupyter.format.IpynbDoc
---@return string[]
function M.to_percent_lines(doc)
	---@type jupyter.format.SourceCell[]
	local cells = {}
	for _, c in ipairs(doc.cells) do
		cells[#cells + 1] = {
			cell_type = c.cell_type,
			source = source_to_lines(c.source),
		}
	end
	return percent.cells_to_lines(cells)
end

---Reconcile ``percent_cells`` with the cells of ``original``, returning a
---new document that re-uses outputs / ids / metadata for cells whose
---source is unchanged. Reused cells start as a shallow copy of the
---original so unknown fields (e.g. ``attachments``) round-trip intact.
---@param original jupyter.format.IpynbDoc
---@param percent_cells jupyter.format.SourceCell[]
---@return jupyter.format.IpynbDoc
function M.merge(original, percent_cells)
	---@type jupyter.format.IpynbCell[]
	local cells = {}
	for i, pc in ipairs(percent_cells) do
		local orig = original.cells[i]
		local new_source = lines_to_source(pc.source)
		local same_source = orig ~= nil and lines_equal(source_to_lines(orig.source), pc.source)
		local same_kind = orig ~= nil and orig.cell_type == pc.cell_type

		if same_kind and same_source then
			local merged = vim.tbl_extend("force", {}, orig)
			merged.source = new_source
			cells[i] = merged
		elseif same_kind then
			local merged = vim.tbl_extend("force", {}, orig)
			merged.source = new_source
			if pc.cell_type == "code" then
				merged.outputs = {}
				merged.execution_count = nil
			end
			cells[i] = merged
		else
			cells[i] = {
				cell_type = pc.cell_type,
				source = new_source,
				id = new_cell_id(),
				metadata = vim.empty_dict(),
				outputs = pc.cell_type == "code" and {} or nil,
				execution_count = nil,
			}
		end
	end
	return {
		nbformat = original.nbformat or 4,
		nbformat_minor = original.nbformat_minor or 5,
		metadata = original.metadata or vim.empty_dict(),
		cells = cells,
	}
end

---@type table<string, string>
local LANG_TO_FILETYPE = {
	python = "python",
	julia = "julia",
	r = "r",
}

---Best-effort mapping of an ``.ipynb`` document's kernel language to a
---Neovim filetype. Falls back to ``nil`` when the language is unknown so
---the caller can decide on a default.
---@param doc jupyter.format.IpynbDoc
---@return string?
function M.detect_filetype(doc)
	local meta = doc.metadata or {}
	local kernelspec = meta.kernelspec or {}
	local lang = kernelspec.language
	if type(lang) == "string" then
		local ft = LANG_TO_FILETYPE[lang:lower()]
		if ft ~= nil then
			return ft
		end
	end
	local lang_info = meta.language_info or {}
	local name = lang_info.name
	if type(name) == "string" then
		local ft = LANG_TO_FILETYPE[name:lower()]
		if ft ~= nil then
			return ft
		end
	end
	return nil
end

return M
