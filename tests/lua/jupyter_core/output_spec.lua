---@diagnostic disable: undefined-field
local Output = require("jupyter_core.output")

describe("jupyter_core.Output", function()
	it("preserves the full MIME bundle in data", function()
		local out = Output.from_raw({
			output_type = "execute_result",
			data = {
				["text/plain"] = "hello",
				["text/html"] = "<p>hello</p>",
			},
		})
		assert.equals("execute_result", out.output_type)
		assert.equals("hello", out.data["text/plain"])
		assert.equals("<p>hello</p>", out.data["text/html"])
	end)

	it("splits text/plain into lines on \\n", function()
		local out = Output.from_raw({
			output_type = "stream",
			data = { ["text/plain"] = "line1\nline2\nline3" },
		})
		assert.same({ "line1", "line2", "line3" }, out.text)
	end)

	it("returns an empty text list when text/plain is missing", function()
		local out = Output.from_raw({
			output_type = "display_data",
			data = { ["image/png"] = "base64..." },
		})
		assert.same({}, out.text)
	end)

	it("returns an empty text list when data is absent", function()
		local out = Output.from_raw({ output_type = "error" })
		assert.same({}, out.text)
		assert.same({}, out.data)
	end)

	it("prefers the rplugin's pre-split text over re-deriving from data", function()
		-- The rplugin uses Python's splitlines(), which differs from
		-- vim.split on inputs like a trailing newline. Honor it.
		local out = Output.from_raw({
			output_type = "stream",
			data = { ["text/plain"] = "first\n" },
			text = { "first" },
		})
		assert.same({ "first" }, out.text)
	end)

	it("preserves error tracebacks even when data is empty", function()
		local out = Output.from_raw({
			output_type = "error",
			data = {},
			text = {
				"Traceback (most recent call last):",
				"  File ...",
				"ValueError: boom",
			},
		})
		assert.equals("error", out.output_type)
		assert.same({
			"Traceback (most recent call last):",
			"  File ...",
			"ValueError: boom",
		}, out.text)
	end)
end)
