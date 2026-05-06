-- Auto-loaded entry shim for the jupyter.nvim editor module.
--
-- Calling `require("jupyter").setup({})` is the documented way to opt in
-- to commands and keymaps. This file exists so that `:JupyterStart` and
-- friends are usable even when the user never calls `setup` explicitly:
-- the first invocation of any registered command lazily forwards to
-- `setup({})`, after which the real implementations take over.

if vim.g.loaded_jupyter == 1 then
	return
end
vim.g.loaded_jupyter = 1

-- ipynb round-trip is independent of the editor module's user commands:
-- the BufReadCmd needs to be live before the user runs `nvim foo.ipynb`,
-- so register it eagerly rather than waiting for a lazy-command shim.
require("jupyter.format").setup()

local LAZY_COMMANDS = {
	"JupyterStart",
	"JupyterStop",
	"JupyterRestart",
	"JupyterExecute",
	"JupyterExecuteAll",
	"JupyterClear",
	"JupyterClearAll",
	"JupyterNext",
	"JupyterPrev",
	"JupyterInsertBelow",
	"JupyterInsertAbove",
	"JupyterHover",
}

for _, name in ipairs(LAZY_COMMANDS) do
	vim.api.nvim_create_user_command(name, function(args)
		for _, n in ipairs(LAZY_COMMANDS) do
			pcall(vim.api.nvim_del_user_command, n)
		end
		require("jupyter").setup(nil)
		local trailing = args.args and args.args ~= "" and (" " .. args.args) or ""
		local prefix = args.bang and "!" or ""
		vim.cmd(name .. prefix .. trailing)
	end, {
		nargs = "*",
		bang = true,
		desc = "jupyter.nvim: lazy-loaded — calls setup({}) on first use",
	})
end
