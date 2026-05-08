---Image-renderer abstraction for `jupyter.display`.
---
---Defines the `Renderer` interface plus a tiny registry that resolves a
---configured renderer name to a concrete instance. Per-renderer code
---lives in sibling files under `jupyter.display.image.*`.
---
---Currently only `snacks` is shipped; future renderers (image.nvim,
---sixel, …) plug in by adding a sibling module and registering it in
---`FACTORIES` below.

local M = {}

---@class jupyter.display.image.PlaceOpts
---@field max_width integer
---@field max_height integer

---@class jupyter.display.image.Placement
---@field close fun(self): nil

---Concrete renderers implement this interface. Implementations live as
---sibling modules (e.g. `jupyter.display.image.snacks`).
---@class jupyter.display.image.Renderer
---Probe whether the renderer is usable in the current environment
---(deps loaded, terminal supports the protocol, …).
---@field available fun(self): boolean
---Place an image at `anchor_row`. Returns a Placement (which the
---caller owns and must `:close()`) or nil on failure.
---@field place fun(self, bufnr: integer, anchor_row: integer, path: string, opts: jupyter.display.image.PlaceOpts): jupyter.display.image.Placement?

---Registered renderer factories, keyed by config name. Each factory
---returns a fresh Renderer instance.
---@type table<string, fun(): jupyter.display.image.Renderer>
local FACTORIES = {
	snacks = function()
		return require("jupyter.display.image.snacks").new()
	end,
}

---Cache of instantiated renderers, keyed by name. Renderers are
---stateless across invocations, so we reuse a single instance.
---@type table<string, jupyter.display.image.Renderer>
local _instances = {}

---Resolve a renderer by name. Returns the renderer when registered AND
---`available()` reports true; nil otherwise. Safe to call repeatedly.
---@param name string?
---@return jupyter.display.image.Renderer?
function M.resolve(name)
	if name == nil then
		return nil
	end
	local factory = FACTORIES[name]
	if factory == nil then
		return nil
	end
	local renderer = _instances[name]
	if renderer == nil then
		renderer = factory()
		_instances[name] = renderer
	end
	if not renderer:available() then
		return nil
	end
	return renderer
end

---Pick the best image MIME type from an output's data bundle, or nil
---when none of the supported types is present.
---@param output jupyter_core.Output
---@return string?
function M.pick_mime(output)
	for _, mime in ipairs({ "image/png", "image/jpeg" }) do
		local payload = output.data[mime]
		if type(payload) == "string" and payload ~= "" then
			return mime
		end
	end
	return nil
end

---Map an image MIME to the file extension used in the cache.
---@param mime string
---@return string
function M.ext_for_mime(mime)
	if mime == "image/jpeg" then
		return "jpg"
	end
	return "png"
end

---Decode a base64 image payload and write it to a content-addressed
---file under stdpath("cache")/jupyter.nvim/. Returns the absolute path
---or nil when decoding / writing fails.
---@param b64 string
---@param ext string
---@return string?
function M.cache(b64, ext)
	-- Hash the base64 (ASCII) instead of the decoded bytes: vim.fn.sha256
	-- treats Lua strings with NULs as Blobs, and base64 → bytes is
	-- bijective, so the hash is just as unique.
	local hash = vim.fn.sha256(b64)
	local dir = vim.fn.stdpath("cache") .. "/jupyter.nvim"
	local path = ("%s/%s.%s"):format(dir, hash, ext)
	if vim.uv.fs_stat(path) ~= nil then
		return path
	end
	local ok, bytes = pcall(vim.base64.decode, b64)
	if not ok or type(bytes) ~= "string" or bytes == "" then
		return nil
	end
	if vim.uv.fs_stat(dir) == nil then
		vim.uv.fs_mkdir(dir, tonumber("755", 8))
		if vim.uv.fs_stat(dir) == nil then
			return nil
		end
	end
	local fd = vim.uv.fs_open(path, "w", tonumber("644", 8))
	if fd == nil then
		return nil
	end
	vim.uv.fs_write(fd, bytes, 0)
	vim.uv.fs_close(fd)
	return path
end

return M
