SHELL := /bin/sh

.PHONY: test shellcheck e2e e2e-bg

test: shellcheck
	./tests/test_cli.sh
	./tests/test_render.sh
	./tests/test_select.sh
	./tests/test_orphans_e2e.sh </dev/null
	./tests/test_bgalive_e2e.sh </dev/null

# Just the end-to-end test of the orphaned sessions (also run by `make test`).
e2e:
	./tests/test_orphans_e2e.sh </dev/null

# Just the end-to-end test of the background health check (also run by `make test`).
e2e-bg:
	./tests/test_bgalive_e2e.sh </dev/null

shellcheck:
	shellcheck -x -s sh orchestra.tmux bin/* lib/* tests/*.sh
