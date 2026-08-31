# Use ./node_modules/.bin tools, not whatever happens to be on PATH —
# protects against parent direnvs hijacking with the wrong version.
NPM := npm
BIN := ./node_modules/.bin

.PHONY: node-pin-check install hooks test test-watch test-cov lint format fix typecheck audit check build run clean push pull log

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

check: node-pin-check lint typecheck test-cov audit

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

node-pin-check: ## refuse to run the gate on a Node other than .node-version
	@want="$$(cat .node-version)"; have="$$(node -v | sed 's/^v//; s/\..*//')"; \
	if [ "$$want" != "$$have" ]; then \
	  echo "node-pin-check: REFUSING — .node-version pins $$want, running Node $$have."; \
	  echo "  A suite run on the wrong Node is not evidence: a binding or API"; \
	  echo "  mismatch surfaces as assertion failures, not as a build error."; \
	  echo "  Run:  nvm use $$want && npm ci"; \
	  exit 2; \
	fi; \
	echo "node-pin-check: Node $$have matches .node-version ✓"
