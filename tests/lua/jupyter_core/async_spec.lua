---@diagnostic disable: undefined-field, need-check-nil
package.loaded["jupyter_core.async"] = nil
local async = require("jupyter_core.async")

local function flush()
	-- Drain pending vim.schedule callbacks.
	vim.wait(50, function()
		return false
	end, 5)
end

describe("jupyter_core.async", function()
	before_each(function()
		async._reset()
	end)

	it("hands fresh ids out and tracks pending count", function()
		local id1 = async.register(function() end)
		local id2 = async.register(function() end)
		assert.is_number(id1)
		assert.is_number(id2)
		assert.are_not.equal(id1, id2)
		assert.equals(2, async._pending_count())
	end)

	it("delivers the result via the callback on the next tick", function()
		---@type {err: any, result: any}?
		local seen
		local id = async.register(function(err, result)
			seen = { err = err, result = result }
		end)

		async._resolve(id, nil, { matches = { "foo" } })
		-- Callback is dispatched via vim.schedule, so it has not fired yet.
		assert.is_nil(seen)

		flush()
		assert.is_truthy(seen)
		assert.is_nil(seen.err)
		assert.same({ matches = { "foo" } }, seen.result)
		assert.equals(0, async._pending_count())
	end)

	it("forwards the err string when the worker reported a failure", function()
		---@type {err: any, result: any}?
		local seen
		local id = async.register(function(err, result)
			seen = { err = err, result = result }
		end)

		async._resolve(id, "kernel exploded", nil)
		flush()

		assert.is_truthy(seen)
		assert.equals("kernel exploded", seen.err)
		assert.is_nil(seen.result)
	end)

	it("ignores resolutions for unknown ids without crashing", function()
		assert.has_no.errors(function()
			async._resolve(99999, nil, { ok = true })
		end)
		flush()
		assert.equals(0, async._pending_count())
	end)

	it("cancel drops a pending callback before it fires", function()
		local fired = false
		local id = async.register(function()
			fired = true
		end)
		async.cancel(id)
		async._resolve(id, nil, { ok = true })
		flush()
		assert.is_false(fired)
	end)
end)
