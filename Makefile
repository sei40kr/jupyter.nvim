.PHONY: test test-lua lint-lua check

test: test-lua

test-lua:
	vusted tests/lua

lint-lua:
	lua-language-server --check lua/jupyter_core --configpath=$(CURDIR)/.luarc.json --checklevel=Warning

check: lint-lua test
