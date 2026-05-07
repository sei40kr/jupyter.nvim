-- Auto-loaded entry shim for the jupyter.nvim editor module.
--
-- The public Lua API is `require("jupyter").<fn>()`; users wire it up
-- themselves with `vim.keymap.set` and friends. This file only handles
-- the one piece that must be live before any user interaction: the
-- `.ipynb` BufReadCmd needs to be registered before the user runs
-- `nvim foo.ipynb`, so we register it eagerly.

if vim.g.loaded_jupyter == 1 then
	return
end
vim.g.loaded_jupyter = 1

require("jupyter.format").setup()
