---@diagnostic disable: undefined-field, duplicate-set-field, unused-local, need-check-nil
-- Make queries/ discoverable so jupyter.cell can find its Treesitter query.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = require("tests.lua.helpers")

package.loaded["jupyter.lsp"] = nil
package.loaded["jupyter.registry"] = nil
local lsp = require("jupyter.lsp")
local registry = require("jupyter.registry")

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

---@param bufnr integer
---@param kernel table
local function set_kernel(bufnr, kernel)
	registry.set(bufnr, kernel)
end

---@param bufnr integer
local function clear_kernel(bufnr)
	registry.clear(bufnr)
end

local name_counter = 0

---Create a scratch buffer with a unique name. A named buffer is required
---so ``vim.uri_from_bufnr`` and ``vim.uri_to_bufnr`` round-trip back to
---the same bufnr — without a name, the URI is just ``file://`` and
---``uri_to_bufnr`` creates a brand new buffer on lookup.
---@param lines string[]
---@return integer
local function named_buf(lines)
	name_counter = name_counter + 1
	local bufnr = helpers.scratch_buf(lines)
	vim.api.nvim_buf_set_name(bufnr, ("/tmp/jupyter-lsp-spec-%d.py"):format(name_counter))
	vim.bo[bufnr].filetype = "python"
	return bufnr
end

---Call a method on the in-process server and capture the synchronous reply.
---@param method string
---@param params any
---@return any err, any result
local function call(method, params)
	local server = lsp._make_server({})
	---@type any, any
	local err_out, res_out
	local ok, request_id = server.request(method, params, function(err, result)
		err_out = err
		res_out = result
	end)
	assert.is_true(ok)
	assert.is_number(request_id)
	return err_out, res_out
end

---@param bufnr integer
---@return string
local function uri_for(bufnr)
	return vim.uri_from_bufnr(bufnr)
end

describe("jupyter.lsp _make_server", function()
	after_each(function()
		for _, b in ipairs(registry.bufnrs()) do
			registry.clear(b)
		end
	end)

	describe("initialize", function()
		it("advertises completion + hover with utf-8 position encoding", function()
			local err, result = call("initialize", { capabilities = {} })
			assert.is_nil(err)
			assert.is_table(result)
			assert.equals("utf-8", result.capabilities.positionEncoding)
			assert.is_true(result.capabilities.hoverProvider)
			assert.same({ ".", "[" }, result.capabilities.completionProvider.triggerCharacters)
			assert.equals(false, result.capabilities.completionProvider.resolveProvider)
			assert.equals("jupyter.nvim", result.serverInfo.name)
		end)
	end)

	describe("shutdown", function()
		it("replies with nil result", function()
			local err, result = call("shutdown", nil)
			assert.is_nil(err)
			assert.is_nil(result)
		end)
	end)

	describe("unknown methods", function()
		it("respond with -32601 Method not found", function()
			local err, result = call("textDocument/declaration", {})
			assert.is_nil(result)
			assert.is_table(err)
			assert.equals(-32601, err.code)
			assert.matches("Method not found", err.message)
		end)
	end)

	describe("textDocument/completion", function()
		it("returns nil when no kernel is attached", function()
			local bufnr = named_buf({ "# %%", "x = 1" })
			clear_kernel(bufnr)
			local err, result = call("textDocument/completion", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 1, character = 1 },
			})
			assert.is_nil(err)
			assert.is_nil(result)
		end)

		it("returns nil when the cursor is outside any cell", function()
			local bufnr = named_buf({ "preamble", "# %%", "x = 1" })
			set_kernel(bufnr, {
				complete_async = function()
					error("kernel:complete_async should not run when cursor has no cell")
				end,
			})
			local err, result = call("textDocument/completion", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 0, character = 0 },
			})
			assert.is_nil(err)
			assert.is_nil(result)
		end)

		it("translates kernel matches into LSP CompletionItems with textEdit ranges", function()
			local bufnr = named_buf({ "# %%", "x = 1", "x." })
			---@type {code: string, pos: integer}?
			local seen
			set_kernel(bufnr, {
				complete_async = function(_self, code, pos, cb)
					seen = { code = code, pos = pos }
					cb(nil, {
						matches = { "real", "MAX(", "BIT_FLAG" },
						-- Replace the empty range right after the dot.
						-- "# %%" (4) + \n + "x = 1" (5) + \n + "x." (2) = 13
						cursor_start = 13,
						cursor_end = 13,
					})
				end,
			})

			local err, result = call("textDocument/completion", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 2, character = 2 }, -- right after the dot
			})
			assert.is_nil(err)
			assert.is_table(result)
			assert.is_false(result.isIncomplete)
			assert.equals(3, #result.items)

			assert.is_truthy(seen)
			assert.equals("# %%\nx = 1\nx.", seen.code)
			assert.equals(13, seen.pos)

			local item1 = result.items[1]
			assert.equals("real", item1.label)
			assert.equals(CompletionItemKind.Variable, item1.kind)
			assert.same({
				range = {
					start = { line = 2, character = 2 },
					["end"] = { line = 2, character = 2 },
				},
				newText = "real",
			}, item1.textEdit)

			assert.equals(CompletionItemKind.Function, result.items[2].kind)
			assert.equals(CompletionItemKind.Constant, result.items[3].kind)
		end)

		it("returns nil when dispatch throws", function()
			local bufnr = named_buf({ "# %%", "x = 1" })
			set_kernel(bufnr, {
				complete_async = function()
					error("boom")
				end,
			})
			local err, result = call("textDocument/completion", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 1, character = 1 },
			})
			assert.is_nil(err)
			assert.is_nil(result)
		end)

		it("returns nil when the kernel reports an error via callback", function()
			local bufnr = named_buf({ "# %%", "x = 1" })
			set_kernel(bufnr, {
				complete_async = function(_self, _code, _pos, cb)
					cb("kernel boom", nil)
				end,
			})
			local err, result = call("textDocument/completion", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 1, character = 1 },
			})
			assert.is_nil(err)
			assert.is_nil(result)
		end)

		it("recovers cursor_start that points at an earlier line", function()
			-- Replace the identifier "foo" that starts on line 1 (0-indexed)
			-- of the cell from a request whose cursor is on line 2.
			local bufnr = named_buf({
				"# %%",
				"foo = 1",
				"foo",
			})
			set_kernel(bufnr, {
				complete_async = function(_self, _code, _pos, cb)
					-- "# %%" (4) + \n = 5  → start of "foo = 1"
					cb(nil, {
						matches = { "foo" },
						cursor_start = 5,
						cursor_end = 8, -- end of "foo"
					})
				end,
			})

			local _, result = call("textDocument/completion", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 2, character = 3 },
			})
			assert.is_table(result)
			assert.same({
				start = { line = 1, character = 0 },
				["end"] = { line = 1, character = 3 },
			}, result.items[1].textEdit.range)
		end)
	end)

	describe("textDocument/hover", function()
		it("returns nil when no kernel is attached", function()
			local bufnr = named_buf({ "# %%", "x = 1" })
			clear_kernel(bufnr)
			local err, result = call("textDocument/hover", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 1, character = 0 },
			})
			assert.is_nil(err)
			assert.is_nil(result)
		end)

		it("returns nil when the cursor is in the preamble", function()
			local bufnr = named_buf({ "preamble", "# %%", "x = 1" })
			set_kernel(bufnr, {
				inspect_async = function()
					error("kernel:inspect_async should not run when cursor has no cell")
				end,
			})
			local err, result = call("textDocument/hover", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 0, character = 0 },
			})
			assert.is_nil(err)
			assert.is_nil(result)
		end)

		it("returns nil when the kernel reports no information", function()
			local bufnr = named_buf({ "# %%", "x = 1" })
			set_kernel(bufnr, {
				inspect_async = function(_self, _code, _pos, cb)
					cb(nil, { found = false, data = {} })
				end,
			})
			local _, result = call("textDocument/hover", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 1, character = 0 },
			})
			assert.is_nil(result)
		end)

		it("prefers text/markdown and strips ANSI sequences from text/plain", function()
			local bufnr = named_buf({ "# %%", "x = 1" })
			set_kernel(bufnr, {
				inspect_async = function(_self, _code, _pos, cb)
					cb(nil, {
						found = true,
						data = {
							["text/markdown"] = "# Heading\n\nbody",
							["text/plain"] = "ignored",
						},
					})
				end,
			})
			local _, md_result = call("textDocument/hover", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 1, character = 0 },
			})
			assert.is_table(md_result)
			assert.equals("markdown", md_result.contents.kind)
			assert.equals("# Heading\n\nbody", md_result.contents.value)

			set_kernel(bufnr, {
				inspect_async = function(_self, _code, _pos, cb)
					cb(nil, {
						found = true,
						data = { ["text/plain"] = "\27[31mhello\27[0m world" },
					})
				end,
			})
			local _, plain_result = call("textDocument/hover", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 1, character = 0 },
			})
			assert.is_table(plain_result)
			assert.equals("plaintext", plain_result.contents.kind)
			assert.equals("hello world", plain_result.contents.value)
		end)

		it("forwards the byte offset of the cursor inside the cell", function()
			local bufnr = named_buf({
				"# %%",
				"x = '日本語'",
				"y = foo",
			})
			---@type {code: string, pos: integer}?
			local seen
			set_kernel(bufnr, {
				inspect_async = function(_self, code, pos, cb)
					seen = { code = code, pos = pos }
					cb(nil, { found = false, data = {} })
				end,
			})
			-- Cursor at byte col 4 of "y = foo" (line 2 of the buffer).
			local _, _ = call("textDocument/hover", {
				textDocument = { uri = uri_for(bufnr) },
				position = { line = 2, character = 4 },
			})
			-- "# %%"        =  4 bytes + \n  =  5
			-- "x = '日本語'" = 15 bytes + \n  = 16  → cumulative 21
			-- col 4 in "y = foo"             =  4
			-- total                          = 25
			assert.is_truthy(seen)
			assert.equals("# %%\nx = '日本語'\ny = foo", seen.code)
			assert.equals(25, seen.pos)
		end)
	end)
end)

describe("jupyter.lsp attach / detach", function()
	---@type integer[]
	local started_buffers = {}

	---Wait for every "jupyter" client to disappear from ``get_clients``.
	---``vim.lsp.stop_client`` is async; without this, the next test sees
	---leftover clients.
	local function wait_for_no_clients()
		vim.wait(2000, function()
			return #vim.lsp.get_clients({ name = "jupyter" }) == 0
		end, 10)
	end

	before_each(function()
		started_buffers = {}
		-- Kill anything left over from earlier tests in this file.
		for _, c in ipairs(vim.lsp.get_clients({ name = "jupyter" })) do
			vim.lsp.stop_client(c.id, true)
		end
		wait_for_no_clients()
	end)

	after_each(function()
		for _, b in ipairs(started_buffers) do
			lsp.detach(b)
		end
		for _, c in ipairs(vim.lsp.get_clients({ name = "jupyter" })) do
			vim.lsp.stop_client(c.id, true)
		end
		wait_for_no_clients()
		for _, b in ipairs(registry.bufnrs()) do
			registry.clear(b)
		end
	end)

	it("attaches a real LSP client to the buffer and detaches cleanly", function()
		local bufnr = named_buf({ "# %%", "x = 1" })
		started_buffers[#started_buffers + 1] = bufnr

		local client_id = lsp.attach(bufnr)
		assert.is_number(client_id)

		local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "jupyter" })
		assert.equals(1, #clients)
		assert.equals(client_id, clients[1].id)
		assert.is_true(clients[1].server_capabilities.hoverProvider)

		lsp.detach(bufnr)

		clients = vim.lsp.get_clients({ bufnr = bufnr, name = "jupyter" })
		assert.equals(0, #clients)
	end)

	it("reuses a single client across multiple buffers", function()
		local buf_a = named_buf({ "# %%", "x = 1" })
		local buf_b = named_buf({ "# %%", "y = 2" })
		started_buffers[#started_buffers + 1] = buf_a
		started_buffers[#started_buffers + 1] = buf_b

		local id_a = lsp.attach(buf_a)
		local id_b = lsp.attach(buf_b)
		assert.equals(id_a, id_b)

		-- Detaching one buffer must not stop the shared client.
		lsp.detach(buf_a)
		local clients = vim.lsp.get_clients({ bufnr = buf_b, name = "jupyter" })
		assert.equals(1, #clients)

		lsp.detach(buf_b)
		wait_for_no_clients()
		clients = vim.lsp.get_clients({ name = "jupyter" })
		assert.equals(0, #clients)
	end)
end)
