# agentmux - developer targets. `make check` is what CI would run.
RUFF ?= uvx ruff
PYTHON ?= python3
SH_FILES := agentmux.tmux bin/agentmux hooks/agentmux-hook lib/constants.sh tests/lib.sh tests/e2e.sh tests/test_hook_parse.sh tests/test_install.sh

.PHONY: lint test e2e check fmt

lint:
	shellcheck $(SH_FILES)
	$(RUFF) check .
	$(RUFF) format --check .

fmt:
	$(RUFF) format .
	$(RUFF) check --fix .

test:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v
	sh tests/test_hook_parse.sh
	sh tests/test_install.sh

e2e:
	sh tests/e2e.sh

check: lint test e2e
