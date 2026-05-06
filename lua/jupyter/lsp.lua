---In-process ("virtual") LSP server backed by the Jupyter kernel.
---
---Exposes ``textDocument/completion`` and ``textDocument/hover`` so that
---any LSP-aware client (Neovim's built-in, nvim-cmp, blink.cmp, …) can
---surface kernel completions and inspect output without a per-client
---adapter. The server is implemented as a Lua function passed as
---``cmd`` to ``vim.lsp.start``; no real process is spawned.
---
---Position handling: the server advertises ``positionEncoding = utf-8``
---so LSP positions and Jupyter's byte-based cursor_pos use the same
---unit and translation between them is purely arithmetic.

local cell_mod = require("jupyter.cell")
local registry = require("jupyter.registry")

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

local M = {}

local CLIENT_NAME = "jupyter"

---Heuristic mapping from a kernel match string to LSP CompletionItemKind.
---Trailing ``(`` → callable, ALL_CAPS → constant, otherwise variable.
---@param label string
---@return integer
local function kind_for(label)
	if label:sub(-1) == "(" then
		return CompletionItemKind.Function
	end
	if label:match("^[%u_][%u%d_]*$") then
		return CompletionItemKind.Constant
	end
	return CompletionItemKind.Variable
end

---@param s string
---@return string
local function strip_ansi(s)
	return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---@param data table<string, string>
---@return string body, string kind  ``kind`` is "markdown" or "plaintext"
local function pick_representation(data)
	local md = data["text/markdown"]
	if type(md) == "string" and md ~= "" then
		return md, "markdown"
	end
	local plain = data["text/plain"]
	if type(plain) == "string" and plain ~= "" then
		return plain, "plaintext"
	end
	return "", "plaintext"
end

---Convert an LSP position (0-indexed line/character, byte units) into
---the byte offset Jupyter expects within ``table.concat(cell.source, "\n")``.
---@param cell jupyter.Cell
---@param position {line: integer, character: integer}
---@return integer
local function position_to_offset(cell, position)
	local rel = position.line - cell.start_row
	if rel < 0 then
		rel = 0
	end
	local offset = 0
	for i = 1, rel do
		offset = offset + #(cell.source[i] or "") + 1
	end
	local cur_line = cell.source[rel + 1] or ""
	local col = position.character
	if col > #cur_line then
		col = #cur_line
	end
	return offset + col
end

---Inverse of ``position_to_offset``: given a byte offset within the
---cell's joined source, recover the buffer line/character pair.
---@param cell jupyter.Cell
---@param byte_offset integer
---@return {line: integer, character: integer}
local function offset_to_position(cell, byte_offset)
	local pos = 0
	for i, line in ipairs(cell.source) do
		local line_len = #line
		if pos + line_len >= byte_offset then
			return { line = cell.start_row + i - 1, character = byte_offset - pos }
		end
		pos = pos + line_len + 1
	end
	local last_idx = #cell.source
	local last = cell.source[last_idx] or ""
	return {
		line = cell.start_row + math.max(last_idx - 1, 0),
		character = #last,
	}
end

---Resolve the buffer the request targets. Falls back to the request
---buffer (``vim.uri_to_bufnr``) so a stale URI doesn't crash the
---handler.
---@param uri string
---@return integer
local function bufnr_for_uri(uri)
	return vim.uri_to_bufnr(uri)
end

---@param params any  textDocument/completion params (uri, position)
---@param callback fun(err: any, result: any)
function M._handle_completion(params, callback)
	local bufnr = bufnr_for_uri(params.textDocument.uri)
	local kernel = registry.get(bufnr)
	if kernel == nil then
		return callback(nil, nil)
	end

	local cell = cell_mod.get_cell_at(bufnr, params.position.line)
	if cell == nil then
		return callback(nil, nil)
	end

	local code = table.concat(cell.source, "\n")
	local cursor_pos = position_to_offset(cell, params.position)

	local ok = pcall(function()
		kernel:complete_async(code, cursor_pos, function(err, result)
			if err ~= nil or result == nil then
				return callback(nil, nil)
			end

			local start_pos = offset_to_position(cell, result.cursor_start)
			local end_pos = offset_to_position(cell, result.cursor_end)

			---@type table[]
			local items = {}
			for i, match in ipairs(result.matches) do
				items[i] = {
					label = match,
					kind = kind_for(match),
					textEdit = {
						range = { start = start_pos, ["end"] = end_pos },
						newText = match,
					},
				}
			end
			callback(nil, { items = items, isIncomplete = false })
		end)
	end)
	if not ok then
		callback(nil, nil)
	end
end

---@param params any  textDocument/hover params (uri, position)
---@param callback fun(err: any, result: any)
function M._handle_hover(params, callback)
	local bufnr = bufnr_for_uri(params.textDocument.uri)
	local kernel = registry.get(bufnr)
	if kernel == nil then
		return callback(nil, nil)
	end

	local cell = cell_mod.get_cell_at(bufnr, params.position.line)
	if cell == nil then
		return callback(nil, nil)
	end

	local code = table.concat(cell.source, "\n")
	local cursor_pos = position_to_offset(cell, params.position)

	local ok = pcall(function()
		kernel:inspect_async(code, cursor_pos, function(err, result)
			if err ~= nil or result == nil or not result.found then
				return callback(nil, nil)
			end

			local body, kind = pick_representation(result.data)
			if body == "" then
				return callback(nil, nil)
			end

			callback(nil, {
				contents = {
					kind = (kind == "markdown") and "markdown" or "plaintext",
					value = strip_ansi(body),
				},
			})
		end)
	end)
	if not ok then
		callback(nil, nil)
	end
end

---@type table<string, fun(params: any, callback: fun(err: any, result: any))>
local METHODS = {
	---@diagnostic disable-next-line: unused-local
	initialize = function(params, callback)
		callback(nil, {
			capabilities = {
				positionEncoding = "utf-8",
				textDocumentSync = {
					openClose = true,
					change = 0,
				},
				completionProvider = {
					triggerCharacters = { ".", "[" },
					resolveProvider = false,
				},
				hoverProvider = true,
			},
			serverInfo = { name = "jupyter.nvim", version = "0.1" },
		})
	end,
	shutdown = function(_, callback)
		callback(nil, nil)
	end,
	["textDocument/completion"] = function(p, cb)
		M._handle_completion(p, cb)
	end,
	["textDocument/hover"] = function(p, cb)
		M._handle_hover(p, cb)
	end,
}

---Construct the in-process server. Returned table conforms to the
---``lsp.rpc.PublicClient`` contract Neovim expects from ``cmd``.
---@param dispatchers table
---@return table
function M._make_server(dispatchers)
	local closing = false
	local request_id = 0

	local function reply_method_not_found(method, callback)
		callback({
			code = -32601,
			message = "Method not found: " .. tostring(method),
		}, nil)
	end

	return {
		---@param method string
		---@param params any
		---@param callback fun(err: any, result: any)
		---@return boolean, integer
		request = function(method, params, callback)
			request_id = request_id + 1
			local handler = METHODS[method]
			if handler ~= nil then
				handler(params, callback)
			else
				reply_method_not_found(method, callback)
			end
			return true, request_id
		end,
		---@param method string
		---@diagnostic disable-next-line: unused-local
		notify = function(method, params)
			if method == "exit" then
				closing = true
				if dispatchers and dispatchers.on_exit then
					vim.schedule(function()
						dispatchers.on_exit(0, 0)
					end)
				end
			end
			return true
		end,
		is_closing = function()
			return closing
		end,
		terminate = function()
			closing = true
		end,
	}
end

---Attach the virtual LSP to ``bufnr``. Idempotent — ``vim.lsp.start``
---deduplicates by ``name`` + ``root_dir``, so multiple buffers share a
---single server instance.
---@param bufnr integer
---@return integer? client_id
function M.attach(bufnr)
	return vim.lsp.start({
		name = CLIENT_NAME,
		cmd = M._make_server,
		root_dir = vim.fn.getcwd(),
	}, { bufnr = bufnr })
end

---Detach the virtual LSP from ``bufnr``. Stops the underlying client
---only when no other buffers remain attached.
---@param bufnr integer
function M.detach(bufnr)
	local clients = vim.lsp.get_clients({ bufnr = bufnr, name = CLIENT_NAME })
	for _, client in ipairs(clients) do
		pcall(vim.lsp.buf_detach_client, bufnr, client.id)
		local remaining = vim.lsp.get_clients({ id = client.id })
		local still_attached = false
		for _, c in ipairs(remaining) do
			if c.attached_buffers and next(c.attached_buffers) ~= nil then
				still_attached = true
				break
			end
		end
		if not still_attached then
			vim.lsp.stop_client(client.id, false)
		end
	end
end

---Stop every active jupyter virtual LSP client.
function M.stop_all()
	for _, client in ipairs(vim.lsp.get_clients({ name = CLIENT_NAME })) do
		vim.lsp.stop_client(client.id, false)
	end
end

return M
