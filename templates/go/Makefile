PROJECT  := myproject
GO       := go
PKG      := ./...
VERSION  := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS  := -s -w -X main.version=$(VERSION)
BUILD    := $(GO) build -trimpath -ldflags='$(LDFLAGS)'

.PHONY: install tools hooks test test-race test-cov watch fmt vet lint vuln check build run clean tidy push pull

install: tidy tools hooks

tools:
	$(GO) install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
	$(GO) install golang.org/x/vuln/cmd/govulncheck@latest
	$(GO) install gotest.tools/gotestsum@latest

hooks:
	pre-commit install --hook-type pre-commit --hook-type pre-push

tidy:
	$(GO) mod tidy

test:
	$(GO) test -count=1 $(PKG)

test-race:
	$(GO) test -race -count=1 $(PKG)

test-cov:
	$(GO) test -race -count=1 -coverprofile=coverage.out -covermode=atomic $(PKG)
	@$(GO) tool cover -func=coverage.out | tail -1

watch:
	gotestsum --watch -- -race -count=1 $(PKG)

fmt:
	$(GO) fmt $(PKG)

vet:
	$(GO) vet $(PKG)

lint:
	golangci-lint run

vuln:
	govulncheck $(PKG)

check: fmt vet lint test-race vuln

build:
	@mkdir -p bin
	CGO_ENABLED=0 $(BUILD) -o bin/$(PROJECT) ./cmd/$(PROJECT)

run:
	$(GO) run ./cmd/$(PROJECT)

clean:
	rm -rf bin/ coverage.out coverage.html

pull:
	git pull origin main

push: check
	git push origin main
