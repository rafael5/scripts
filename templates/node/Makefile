# Use ./node_modules/.bin tools, not whatever happens to be on PATH —
# protects against parent direnvs hijacking with the wrong version.
NPM := npm
BIN := ./node_modules/.bin

.PHONY: install hooks test test-watch test-cov lint format fix typecheck audit check build run clean push pull log

install:
	$(NPM) install
	$(MAKE) hooks

hooks:
	$(BIN)/simple-git-hooks

test:
	$(NPM) run test

test-watch:
	$(NPM) run test:watch

test-cov:
	$(NPM) run test:cov

lint:
	$(NPM) run lint

format:
	$(NPM) run format

fix:
	$(NPM) run fix

typecheck:
	$(NPM) run typecheck

audit:
	$(NPM) run audit

check: lint typecheck test-cov audit

build:
	$(NPM) run build

run:
	node --import tsx src/index.ts

clean:
	rm -rf dist coverage .nyc_output *.tsbuildinfo

# Append a dated entry to docs/build-log.md.
# Usage: make log MSG="what changed and why"
log:
	@if [ -z "$(MSG)" ]; then echo 'usage: make log MSG="..."'; exit 1; fi
	@printf '\n## %s\n\n%s\n' "$$(date -u +%Y-%m-%d)" "$(MSG)" >> docs/build-log.md
	@echo "appended to docs/build-log.md"

pull:
	git pull origin main

push: check
	git push origin main
