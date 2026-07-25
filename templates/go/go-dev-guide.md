# Go Development Guide

The practices implemented by this template, with the reasoning behind each.
Anchored to what is actually used at Google, Cloudflare, Uber, HashiCorp, and
the Go team itself — not to fashion.

References:
- Effective Go — <https://go.dev/doc/effective_go>
- Google Go Style Guide — <https://google.github.io/styleguide/go/>
- Go Code Review Comments — <https://go.dev/wiki/CodeReviewComments>
- Uber Go Style Guide — <https://github.com/uber-go/guide>

---

## 1. Project layout

```
.
├── cmd/<binary>/main.go    # one subdir per binary, entry point only
├── internal/               # compiler-enforced private packages
│   └── <pkg>/              # core implementation
├── go.mod                  # module declaration, Go version, deps
├── go.sum                  # checksum lockfile — commit alongside go.mod
└── ...
```

Why this shape:

- **`cmd/<binary>`** — Go's de facto convention for executables. Keeps
  multiple binaries side-by-side without polluting the root.
- **`internal/`** — the compiler refuses to import `internal/...` from
  outside the module. This makes API stability free: anything not under
  `internal/` is part of your public surface; anything under it is yours
  to refactor.
- **No `pkg/`** — historical, adds nesting without value. Top-level
  domain-named packages (`auth/`, `store/`, `parser/`) read better when
  you have a public API. For an application that exposes nothing, keep
  everything in `internal/`.
- **One module per repo** — multi-module repos are a special case
  (monorepos with `go.work`). Don't reach for them by default.

## 2. Module hygiene

- Pin the Go version in `go.mod` (`go 1.24`) and in `.go-version` (read by
  CI and tools like `asdf` / `tenv`).
- Commit both `go.mod` and `go.sum`. `go.sum` is your dependency lockfile —
  CI verifies it with `go mod verify`.
- `go mod tidy` after every dependency change. The pre-commit hook enforces
  this so `go.mod` and `go.sum` never drift from imports.
- Avoid `replace` directives in committed `go.mod`. They hide local hacks
  and break consumers. Use `go.work` for local development across modules.
- Set `GOFLAGS=-mod=readonly` in CI so a missing dep fails fast instead of
  silently mutating `go.sum`.

## 3. Naming and style

- `gofmt` is the only formatter. The template's pre-commit hook runs it on
  every commit. There is no debate.
- Package names: short, lowercase, no underscores, no plurals.
  `package user`, not `package users` or `package user_management`.
- Exported identifiers are `CamelCase`; unexported are `camelCase`.
- Acronyms keep their case: `URL`, `HTTPServer`, `userID`, not `Url` /
  `HttpServer` / `userId`.
- Receiver names are short (1–3 chars) and consistent across all methods
  on a type. Don't use `self` or `this`.
- Comments on exported identifiers start with the identifier name and end
  with a period. `// User is a registered account.` `golangci-lint`'s
  `revive: exported` rule enforces this.
- Line length: gofmt does not wrap. Aim for readability, not a numeric
  limit. ~100 columns is informal.

## 4. Errors

- **Errors are values.** Return them, don't throw. `panic` is for genuinely
  unrecoverable programmer bugs (nil receiver of a non-pointer method,
  invalid invariants), never for control flow.
- Wrap context with `fmt.Errorf("doing X: %w", err)`. The `%w` verb keeps
  the chain inspectable via `errors.Is` and `errors.As`.
- Sentinel errors are package-level vars: `var ErrNotFound = errors.New("user: not found")`.
- Custom error types are structs implementing `Error() string`. Add fields
  callers might branch on; keep methods minimal.
- Check errors immediately. Don't `_ = thing.Close()` — wrap or log it. The
  `errcheck` linter catches both.
- Don't compare error strings (`err.Error() == "..."`). Always use
  `errors.Is` / `errors.As`.

## 5. Testing

The standard library's `testing` package is sufficient for almost everything.

### Conventions

- Tests live in `<file>_test.go` next to the code they test.
  Same-package tests can access unexported names; black-box tests use
  `package foo_test` to enforce a public-API-only test.
- Test functions: `func TestThing(t *testing.T)`.
- Use `t.Run(name, ...)` for subtests — they get separate output, support
  `-run TestThing/case` filtering, and reset `t.Parallel` boundaries.
- Call `t.Parallel()` in every test that doesn't share global state. The
  race detector (`go test -race`) finds the rare cases where you can't.
- Use `t.Helper()` in helper functions so failures point to the call site.
- Use `t.Cleanup(...)` to register teardown — beats `defer` because it
  runs in LIFO across nested helpers.
- `t.TempDir()` creates a temp dir that's auto-cleaned. Don't roll your own.

### Table-driven tests

The dominant idiom in the standard library and at Google. The template
includes a working example in `myproject_test.go`:

```go
tests := []struct {
    name string
    in   X
    want Y
}{
    {name: "empty", in: X{}, want: Y{}},
    {name: "happy path", in: X{...}, want: Y{...}},
}

for _, tc := range tests {
    t.Run(tc.name, func(t *testing.T) {
        t.Parallel()
        got := FunctionUnderTest(tc.in)
        if !reflect.DeepEqual(got, tc.want) {
            t.Errorf("got %+v, want %+v", got, tc.want)
        }
    })
}
```

### Fakes over mocks

Define small interfaces **at the consumer**, not at the implementation:

```go
// In the package that *uses* a UserStore — not in the package that defines it.
type userStore interface {
    Get(ctx context.Context, id string) (User, error)
}

func handler(s userStore) http.Handler { ... }
```

Then a fake is a 5-line struct. This is how the `net/http` and `io`
packages are designed, and how Google internal Go code is written. Mocking
libraries (`gomock`, `testify/mock`) generate boilerplate that fakes don't
need — and they couple your tests to method signatures instead of behavior.

### Other testing tools

- **Race detector**: `go test -race` — required before every push.
- **Coverage**: `go test -coverprofile=coverage.out`, then
  `go tool cover -func=coverage.out`. Aim for >80% on changed code, not
  100% on everything.
- **Fuzzing**: built-in. `func FuzzX(f *testing.F)`. Use it on parsers and
  any function handling untrusted bytes.
- **Benchmarks**: `func BenchmarkX(b *testing.B)`. Compare with `benchstat`
  before claiming a perf change.
- **Golden files**: store expected output under `testdata/`. Add a `-update`
  flag to your test for regenerating them.
- **Integration tests**: separate file with `//go:build integration` so
  `go test ./...` stays fast and `go test -tags=integration ./...` runs
  the full suite.

## 6. Concurrency

- `context.Context` is the first parameter of any function that does I/O,
  blocks, or might need cancellation. Never store a `Context` in a struct;
  pass it through.
- Every `go funcCall()` needs an answer to "who stops this and how?" If
  you can't answer, don't spawn it.
- `golang.org/x/sync/errgroup` for fan-out work — propagates the first
  error and cancels siblings. Almost always better than raw goroutines +
  channels for parallel I/O.
- `sync.Mutex`'s zero value is ready to use. Embed it; don't initialize.
- Prefer channels for *ownership transfer* and synchronization;
  prefer mutexes for *protecting shared state*. The Go proverb
  "do not communicate by sharing memory; share memory by communicating"
  is a guideline, not a rule.
- For tests of time-based code, use `testing/synctest` (Go 1.24+). Before
  that, inject a `Clock` interface.

## 7. Logging

- `log/slog` (stdlib, since Go 1.21). No third-party logger needed.
- Pass loggers down explicitly:
  `func handler(logger *slog.Logger) http.Handler`.
- JSON in production, text in development:
  `slog.NewJSONHandler` vs `slog.NewTextHandler`.
- Structured fields, not formatted strings:
  `slog.Info("request handled", "method", r.Method, "path", r.URL.Path)`.
- Don't log secrets. Don't log full request bodies.
- Set context-aware fields with `slog.With(...)` once; reuse the logger.

## 8. CI/CD pipeline

The template's `.github/workflows/ci.yml` runs steps in this order — fastest
first, so a typo fails fast and an integration test failure isn't blocked
by a build queue:

1. `go mod verify` — checksum lockfile integrity
2. `gofmt -l .` — must be empty
3. `go vet ./...` — built-in static analysis
4. `golangci-lint run` — meta-linter
5. `go test -race -coverprofile=...` — full test suite under race detector
6. `go tool cover -func=...` — coverage summary
7. `govulncheck ./...` — CVE scan against actually-called code paths
8. Build matrix (linux/amd64, linux/arm64, darwin/arm64) on success

Caching: `actions/setup-go@v5 with: cache: true` reuses both the module
cache and build cache between runs. Speeds CI up by ~50% on small repos.

Pre-commit hooks (this template):
- **pre-commit**: `gofmt`, `go vet`, `go mod tidy`, hygiene checks
- **pre-push**: `golangci-lint run`, `go test -race ./...`

So `git push` enforces the same gate as `make check` and CI.

## 9. Build & release

```bash
go build -trimpath -ldflags="-s -w -X main.version=$(git describe --tags --always --dirty)" -o bin/myproject ./cmd/myproject
```

- `-trimpath` removes local filesystem paths from the binary (reproducible
  builds).
- `-ldflags="-s -w"` strips symbol and DWARF tables (smaller binary).
- `-X main.version=...` injects the version string at link time.
- `CGO_ENABLED=0` produces a static binary that runs in any minimal
  container or distro. Use this unless you genuinely need a C dep.
- Cross-compilation needs no toolchain: `GOOS=linux GOARCH=arm64 go build`.

For multi-platform releases, **GoReleaser** is the tool. Add it later
when the project actually ships binaries.

## 10. Security

- `govulncheck ./...` (Google's official scanner). Unlike CVE feeds, it
  only flags vulns in code you actually call — minimal noise.
- Dependabot (configured in `.github/dependabot.yml`) opens weekly grouped
  PRs for `gomod` and `github-actions`.
- `gosec` (via `golangci-lint`) catches common smells: hardcoded creds,
  unsafe SQL, weak crypto.
- Set `permissions: contents: read` on workflows. The template does this.

## 11. Performance

- **Don't optimize without a benchmark.** Add `BenchmarkX` first, change
  the code, run `benchstat` to confirm.
- `go test -cpuprofile=cpu.prof -memprofile=mem.prof` + `go tool pprof` is
  excellent for local analysis.
- `net/http/pprof` exposes runtime profiling on a debug port. Useful in
  prod behind authentication; off in default builds.
- Allocations matter more than micro-CPU savings. `go test -bench=. -benchmem`
  reports allocs/op; that's where wins live.

## 12. Reliability checklist for production code

- HTTP servers set explicit timeouts (`ReadTimeout`, `WriteTimeout`,
  `IdleTimeout`) — defaults are unsafe.
- HTTP clients set a `Timeout`. The default `http.Client{}` blocks forever.
- Always close response bodies (`bodyclose` linter enforces it).
- Use `signal.NotifyContext` + `srv.Shutdown(ctx)` for graceful shutdown.
- Long-running loops poll `ctx.Done()` regularly.
- No goroutine without a stop story.
- No global mutable state except registries set up in `init()`.

## 13. Dependencies

- Stdlib first. Go's standard library is broad and unusually stable.
- Each new dep is a future CVE, a build dep, and a maintenance hazard.
- Trusted ecosystems for hobby/production use:
  - `golang.org/x/...` — Go-team-maintained extensions
  - `github.com/google/...` (uuid, go-cmp, etc.)
  - `github.com/spf13/cobra` for CLIs (only if your tool needs subcommands;
    `flag` is fine for simple binaries — this template uses `flag`)
- Avoid: anything unmaintained for >1 year, anything with one contributor,
  anything that wraps stdlib for "ergonomics" only.

## 14. Documentation

- `doc.go` per package — package comment shows on `pkg.go.dev`.
- Every exported identifier has a doc comment starting with its name.
- `func ExampleX()` in test files is checked by `go test` *and* renders as
  runnable example documentation.
- A `README.md` for humans; a `CLAUDE.md` for the agent (this template
  provides both conventions).

## 15. What this template gives you out of the box

- Project layout with `cmd/`, `internal/`, `go.mod`, `.go-version`
- A working `flag` + `slog` + signal-handling entry point in `main.go`
- A `Run(ctx)` skeleton in `internal/myproject` with a context-canceled test
- Table-driven test example demonstrating the canonical idiom
- `Makefile` with the same target names as the Python template
  (`install`, `test`, `watch`, `lint`, `check`, `push`, ...)
- `.golangci.yml` with the linter set common in production Go shops
- `.pre-commit-config.yaml` running `gofmt`, `go vet`, `go mod tidy` on
  commit and `golangci-lint` + `go test -race` on push
- `.github/workflows/ci.yml` running format / vet / lint / test+race+cov /
  govulncheck and a multi-arch build matrix
- `.github/dependabot.yml` for weekly grouped dep updates
- `direnv` `.envrc` adding `./bin` to PATH and loading `.env` if present
- A first-class `CLAUDE.md` describing the workflow for the agent

## 16. New project setup

```bash
cp -r ~/scripts/templates/go ~/projects/myapp
cd ~/projects/myapp

# Rename the package and binary
mv cmd/myproject cmd/myapp
mv internal/myproject internal/myapp

# Set the module path (replace with your GitHub user/org)
go mod edit -module github.com/rafael5/myapp

# Update internal imports + the binary name in Makefile/CI
grep -rl 'myproject' --include='*.go' --include='Makefile' --include='*.yml' --include='*.md' \
  | xargs sed -i 's/myproject/myapp/g'

# Install deps + tools + git hooks, then verify
make install
make check

# Data dir lives outside the repo (see ~/scripts/machine-setup.md)
mkdir -p ~/data/myapp/{input,output,db}

# Initialize and push
git init -b main
git remote add origin git@github.com:rafael5/myapp.git
git add .
git commit -m "initial commit from go template"
make push
```

## 17. Toolchain install — lessons from a real bootstrap

Errors hit while installing Go 1.26.2 on `mini-mint` and the fixes that landed.
Read this before re-running `~/scripts/bin/install-go.sh`. Each subsection ends
with **Status** indicating whether the fix is already applied or only
documented as a recommendation.

### 17.1 `https://go.dev/dl/<tarball>.sha256` no longer serves a raw hash

Go's `dl` site now redirects `.sha256` URLs to a documentation anchor on the
download page instead of returning the bare hash. Anything that fetches the
URL and treats it as a checksum sees HTML instead:

```
ERROR checksum mismatch:
  got  990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282
  want <!DOCTYPE html>
       <html><head><meta http-equiv="refresh" content="0; url=/dl/...">
```

(The actual download was fine — only the comparison string was wrong.)

**Fix applied:** read the SHA-256 from the JSON metadata endpoint, which Go
documents as machine-readable: `https://go.dev/dl/?mode=json&include=all`.
Each release lists its files with `sha256` fields. The script parses the JSON
with `python3` (always present on Mint) and rejects any response that isn't a
valid 64-hex-char string before comparing.

**Status:** fixed in `~/scripts/bin/install-go.sh` (the `EXPECTED=$(... python3
... )` block). Validated end-to-end against `go1.26.2.linux-amd64.tar.gz`.

### 17.2 `sudo tar` hung for 12+ minutes with no visible password prompt

What happened: the script ran `curl --progress-bar` to download the tarball
(carriage-return-redrawing line). Immediately after, it ran `sudo rm -rf
/usr/local/go` followed by `sudo tar ...`. The first sudo prompt was emitted
on a line that had been overwritten by the progress bar; the user could not
see it. `sudo` waited indefinitely. The user then re-ran the script twice
more, stacking three zombie processes — only `ps -ef` showed the original
`sudo tar` had been waiting since 22:37.

```
$ ps -ef | grep -E 'tar|install-go'
root  32927  ...  22:37  ...  sudo tar -C /usr/local -xz   # 12 min hung
rafael 43167 ...  22:47  ...  /bin/bash install-go.sh      # stacked
rafael 44889 ...  22:49  ...  /bin/bash install-go.sh      # stacked
```

**Fix recommended (not yet applied):** pre-authenticate sudo *before* any
download so the prompt happens at a clean moment when the user is watching,
and refresh the timestamp in a background loop so later sudo calls never
re-prompt. Detect concurrent runs early with a pidfile.

```bash
# Place near the top of install-go.sh, after preflight checks.
say "Authenticating sudo (you may be prompted for your password) ..."
sudo -v || die "sudo authentication failed"
( while sudo -n true 2>/dev/null; do sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT

# Concurrent-run guard
LOCKFILE=/tmp/install-go.lock
exec 9>"$LOCKFILE"
flock -n 9 || die "another install-go.sh is already running (lockfile $LOCKFILE)"
```

**Recovery if this happens again:**
```bash
ps -ef | grep -E 'tar|install-go' | grep -v grep   # find PIDs
sudo kill -9 <hung-sudo-tar-pid>
kill <stacked-script-pids>
sudo ls /usr/local/go && /usr/local/go/bin/go version  # check state
# If /usr/local/go is empty or partial, redo extraction manually:
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzvf /tmp/go<ver>.linux-amd64.tar.gz | tail
```

**Status:** documented; script not yet patched. Apply when you next touch
`install-go.sh`.

### 17.3 Subshells don't inherit `~/.bashrc` PATH

After install, a fresh interactive shell had `/usr/local/go/bin` and
`~/go/bin` on PATH — `go version` worked. But non-interactive subshells (CI,
cron, agent harnesses, Makefiles invoked via `sh -c`) do **not** source
`~/.bashrc` and saw `go: command not found`.

This is not a Go problem; it's bash. `~/.bashrc` is sourced for *interactive*
shells only.

**Fix in scripts and CI:** export PATH explicitly inside the script, don't
rely on the parent shell:

```bash
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
```

The template's `Makefile` uses bare `go` / `golangci-lint` / etc., which is
correct because the user's interactive shell has PATH set. In GitHub Actions,
`actions/setup-go@v5` handles PATH automatically. In any other non-interactive
context — cron, systemd units, AI agents — set PATH at the top of the script.

**Status:** N/A (not a script bug, just a thing to know).

### 17.4 `govet: enable-all: true` includes `fieldalignment`, which is too eager

The first `make check` after install reported:

```
internal/myproject/myproject_test.go:33:13: fieldalignment:
    struct with 40 pointer bytes could be 32 (govet)
```

…on a 3-field struct in a table-driven test. `fieldalignment` reorders fields
to reduce GC scan cost. The Go standard library does not pass it. The check
is only worthwhile when a struct is allocated millions of times in a hot path,
and even then a benchmark should justify the change. In tests it is pure
noise.

**Fix applied** (`.golangci.yml`):

```yaml
linters:
  settings:
    govet:
      enable-all: true
      disable:
        - fieldalignment
```

If a hot-path struct genuinely warrants memory tuning, re-enable it for that
package via a per-directory `.golangci.yml` override or a narrowly scoped
`//nolint:fieldalignment` directive — and back the change with a benchmark.

**Status:** fixed in `~/scripts/templates/go/.golangci.yml`.

### 17.5 Smoke-test passed end-to-end after the above fixes

For the record, on `mini-mint` (Linux Mint, AMD64, Go 1.26.2):

| Step | Result |
|---|---|
| `go build ./...` | clean |
| `go vet ./...` | clean |
| `gofmt -l .` | empty |
| `go test -race -count=1 ./...` | 3/3 in 1.0s |
| `golangci-lint run` | 0 issues |
| `govulncheck ./...` | no vulnerabilities |
| `make check` (full gate) | rc=0 |
| `make build` | 2.1 MB static stripped binary |
| `./bin/myproject --version` | `dev` |
| `./bin/myproject` | structured slog start → done |
