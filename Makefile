.PHONY: test test-lua test-python test-integration lint-lua check

test: test-lua test-python

test-lua:
	scripts/test-lua.sh

test-python:
	scripts/test-python.sh

test-integration:
	scripts/test-integration.sh

lint-lua:
	lua-language-server --check lua --configpath=$(CURDIR)/.luarc.json --checklevel=Warning

check: lint-lua test
