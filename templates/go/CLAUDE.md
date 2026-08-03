# Claude Project Context

## What this project is
<!-- One paragraph: what does this app do, who uses it, why does it exist -->

## Dev workflow
```bash
make install    # go mod tidy + install dev tools + install pre-commit hooks
make test       # go test (no race) — fast inner loop
make test-race  # go test -race — required before push
make test-cov   # coverage with summary
make watch      # TDD mode: gotestsum re-runs on save
make fmt        # go fmt ./...
make vet        # go vet ./...
make lint       # golangci-lint run
make vuln       # govulncheck — scan for known CVEs in deps
make check      # fmt + vet + lint + test-race + vuln (THE gate — local, offline; no CI)
make build      # static binary into bin/myproject
make run        # go run ./cmd/myproject
make push       # check + git push
make pull       # git pull origin main
```

## Environment
- Go 1.24+ (pinned in `.go-version`)
- Module path: set in `go.mod` (default `github.com/rafael5/myproject` — change after copy)
- Lockfile: `go.sum` — always commit alongside `go.mod` changes
- Project-built binaries land in `./bin/` (gitignored, on PATH via direnv)

## Adding a dependency
```bash
go get github.com/some/pkg@latest
go mod tidy
# Commit both go.mod and go.sum
```

## Project structure
```
cmd/myproject/main.go     # thin entry point: flags, logging, signals -> internal
internal/myproject/       # all real behavior; "internal" is enforced by the compiler
  doc.go                  # package-level doc comment
  myproject.go            # Run + exported API
  myproject_test.go       # tests live next to code (Go convention)
```

When the project grows beyond a single package, add sibling packages under
`internal/`. Keep `cmd/` for binaries only — one subdir per binary.

## Testing conventions
- Write the test first (TDD)
- Tests live in `<file>_test.go` next to the code they test (same package),
  or in `<file>_test.go` in a `_test` package for black-box tests
- Use **table-driven** tests with `t.Run(name, ...)` subtests
- Call `t.Parallel()` in every test that doesn't share global state
- Always run with `-race` before pushing
- Coverage minimum: 80% (enforced by `make check` on `coverage.out`)
- Integration tests: file suffix `_integration_test.go` + `//go:build integration`

## Code style
- Formatter: `gofmt` (no alternatives — it is the standard)
- Lint: `golangci-lint` configured via `.golangci.yml`
- Imports: `goimports` (formatter handles this)
- No bare panics in library code; return errors. Wrap with `fmt.Errorf("ctx: %w", err)`
- Logging: `log/slog` (stdlib). Pass loggers, don't use globals in libraries.
- Context first: any function that blocks, does I/O, or could be canceled
  takes `ctx context.Context` as the **first** argument

## Git conventions
- Main branch: `main`
- Pre-push hook runs `golangci-lint` + `go test -race` — push fails if either fails
- `make push` runs the full `check` gate before pushing
- Commit messages: short imperative ("add retry logic", "fix timeout bug")
- Always commit `go.sum` alongside `go.mod` changes

## Debugging
```bash
go test -run TestName ./internal/myproject     # single test
go test -v -run TestName/subtest_name ./...    # single subtest
dlv test ./internal/myproject -- -test.run=TestX  # delve debugger
go test -race ./...                             # data race detector
```
Inside any function, `runtime.Breakpoint()` halts under `dlv`.
For ad-hoc tracing, prefer `slog.Debug(...)` over `fmt.Println` — keep prod and
debug output on the same channel.

## Claude guidelines
- Prefer editing existing files over creating new ones
- Keep functions small and independently testable
- Use `log/slog` not `fmt.Println` in library code
- No mocks of types you don't own — define small interfaces at the consumer
- This is a small hobbyist project — keep solutions simple and direct
- See `go-dev-guide.md` for the full set of practices this template implements
