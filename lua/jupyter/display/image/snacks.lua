---`snacks.image`-backed implementation of the
---`jupyter.display.image.Renderer` interface.
---
---Gates on `pcall(require, "snacks.image")` and
---`Snacks.image.supports_terminal()`. The Placement value returned by
---`place()` is the snacks placement itself — its native `:close()`
---method already conforms to the Placement interface, so no wrapper is
---needed.

---@class jupyter.display.image.SnacksRenderer : jupyter.display.image.Renderer
---@field private _snacks any?       lazily-cached snacks.image module
local SnacksRenderer = {}
SnacksRenderer.__index = SnacksRenderer

---@return jupyter.display.image.SnacksRenderer
function SnacksRenderer.new()
	return setmetatable({ _snacks = nil }, SnacksRenderer)
end

---@return boolean
function SnacksRenderer:available()
	local ok, snacks = pcall(require, "snacks.image")
	if not ok or snacks == nil then
		self._snacks = nil
		return false
	end
	if type(snacks.supports_terminal) == "function" then
		local supported_ok, supported = pcall(snacks.supports_terminal)
		if not supported_ok or not supported then
			self._snacks = nil
			return false
		end
	end
	self._snacks = snacks
	return true
end

---@param bufnr integer
---@param anchor_row integer       0-indexed buffer row
---@param path string
---@param opts jupyter.display.image.PlaceOpts
---@return jupyter.display.image.Placement?
function SnacksRenderer:place(bufnr, anchor_row, path, opts)
	if self._snacks == nil then
		return nil
	end
	local ok, placement = pcall(self._snacks.placement.new, bufnr, path, {
		pos = { anchor_row + 1, 0 },
		inline = true,
		max_width = opts.max_width,
		max_height = opts.max_height,
	})
	if not ok then
		return nil
	end
	return placement
end

return SnacksRenderer
