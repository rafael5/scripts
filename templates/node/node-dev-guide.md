# Node Development Guide

The practices implemented by this template, with the reasoning behind
each. Anchored to what the Node core team, npm, Vercel, and Cloudflare
Workers ship in 2026 — not to fashion.

References:
- Node.js docs — <https://nodejs.org/docs/latest/api/>
- TypeScript handbook — <https://www.typescriptlang.org/docs/handbook/>
- Biome docs — <https://biomejs.dev/>
- Effective TypeScript (Vanderkam) — exhaustive style reference

---

## 1. Project layout

```
.
├── src/
│   ├── index.ts           # public API entry point
│   ├── index.test.ts      # tests next to code (Node convention)
│   └── ...
├── docs/
│   └── build-log.md       # chronological per-feature notes
├── dist/                  # tsc output (gitignored)
├── package.json
├── package-lock.json      # commit alongside package.json
├── tsconfig.json
├── biome.json             # linter + formatter config
├── .node-version          # for nvm/asdf — pinned to 24
├── .npmrc                 # engine-strict=true — wrong Node fails install
└── .github/
    ├── workflows/ci.yml
    └── dependabot.yml
```

Why this shape:

- **Tests next to code** (`foo.ts` ↔ `foo.test.ts`) — Node's built-in
  test runner discovers them by glob, no separate test root needed,
  and refactoring a module moves its test along with it.
- **`src/` + `dist/`** — clean separation of source and build output.
  `tsc` reads `src/`, writes `dist/`, never the other way.
- **Single `index.ts` entry** — re-exports the public API so consumers
  do `import { thing } from 'mypackage'`. Subpath exports are an
  optional later addition via `package.json`'s `"exports"` field.
- **No `lib/` directory** — historical, adds nesting without value.
- **CLI?** Add `src/cli.ts` with a shebang and declare `"bin"` in
  `package.json`. Keep CLI logic thin; call into the library.

## 2. Module hygiene

- Pin Node version in `.node-version` (read by `nvm`, `asdf`, `volta`,
  `tenv`, `actions/setup-node`) AND in `package.json`'s `engines.node`
  (read by `npm install` and many tools).
- Commit `package.json` + `package-lock.json` together. Never commit
  one without the other.
- `npm ci` in CI (frozen lockfile, fails on drift). `npm install`
  locally (mutates lockfile when adding deps).
- ESM (`"type": "module"`) is the default for new projects. CommonJS
  exists for legacy interop only.
- Lock direct deps to caret ranges (`^1.2.3`); the lockfile pins
  transitive resolution. Don't pin to exact versions in `package.json`
  unless a specific version has a known issue.
- `package.json` `"files"` field whitelists what gets shipped to npm
  (not just everything that isn't gitignored). Fail-safe.

## 3. TypeScript settings

The template's `tsconfig.json` has these non-default flags on:

- **`strict: true`** — bundles `strictNullChecks`, `noImplicitAny`, etc.
  All recent Node frameworks assume strict mode.
- **`noUncheckedIndexedAccess: true`** — `arr[0]` is `T | undefined`,
  not `T`. Catches real bugs; cost is occasional explicit narrowing.
- **`exactOptionalPropertyTypes: true`** — `{ x?: number }` does not
  accept `{ x: undefined }`. Distinguishes "not present" from "present
  but undefined." Surprising the first time but more honest.
- **`isolatedModules: true`** — every file must be independently
  compilable. Required for fast bundlers (esbuild, swc) and a good
  discipline regardless.
- **`verbatimModuleSyntax: true`** — `import` vs `import type` is
  preserved 1:1 in the output. Combined with Biome's `useImportType`
  rule, you write `import type { Thing }` for type-only imports and
  the runtime knows what's a value vs what's a type.
- **`module: NodeNext` + `moduleResolution: NodeNext`** — Node's
  actual module resolution algorithm, including `package.json`
  `"exports"`. Required for ESM in Node.

Notes:
- `target: ES2023` works on Node 20+. `ES2024` is safe on the
  pinned Node ≥24.
- Test files are excluded from `tsc` build (they're not shipped) but
  still type-checked when `tsc --noEmit` runs without the exclude
  applied — see `npm run typecheck`'s effective scope.

## 4. Errors

- **Errors are values.** `throw` from genuinely exceptional paths;
  return a result object (`{ ok: true, value }` / `{ ok: false, error }`)
  for routine failures consumers should handle.
- Wrap context with `new Error("doing X", { cause: err })`. The
  `cause` field is part of the spec since ES2022 and is preserved by
  `inspect`, `console.error`, and most loggers.
- Subclass `Error` for branchable error types: `class NotFoundError
  extends Error { code = 'NOT_FOUND' as const }`. Check via
  `instanceof` or a discriminator (`err.code`).
- Don't compare error messages (`err.message === '...'`). Use
  `instanceof` or named codes.
- `process.on('unhandledRejection', ...)` and
  `process.on('uncaughtException', ...)` should log and exit. Don't
  swallow.

## 5. Testing

Node's built-in `node:test` runner (since Node 20 LTS) is sufficient
for almost everything. No Vitest / Jest unless you have a specific
need.

### Conventions

- Tests live in `<file>.test.ts` next to the code they test.
- `describe` groups related cases; `it` (or `test`) is one case.
- `node:assert/strict` for assertions — `assert.equal`,
  `assert.deepEqual`, `assert.throws`, `assert.match`.
- Async tests: just return a promise or use `async`. The runner waits.
- `t.mock.method(obj, 'method', impl)` for mocking — built-in, no
  library. `t.mock.timers.enable()` for fake timers.
- `t.cleanup(...)` for teardown — runs LIFO across nested helpers.
- Coverage: `c8` (the modern node-coverage tool). Wraps the runner;
  no source instrumentation. Configured in `package.json`.

### Table-driven tests

The dominant idiom across the Node core, Go, and Python ecosystems.
The template includes a working example in `src/index.test.ts`:

```ts
const cases: ReadonlyArray<{
  readonly name: string;
  readonly input: Parameters<typeof greet>;
  readonly expected: string;
}> = [
  { name: 'plain', input: ['Ada'], expected: 'Hello, Ada!' },
  { name: 'titled', input: ['Lovelace', { title: 'Dr.' }],
    expected: 'Hello, Dr. Lovelace!' },
];

for (const tc of cases) {
  it(tc.name, () => {
    assert.equal(greet(...tc.input), tc.expected);
  });
}
```

The `Parameters<typeof greet>` trick keeps the test data type-safe
against the function signature — change the function and the test
fails to compile if you forget to update fixtures.

### Fakes over mocks

Define small interfaces **at the consumer**, not at the implementation:

```ts
// In the module that USES a UserStore — not in the module that defines it.
interface UserStore {
  get(id: string): Promise<User>;
}

export function makeHandler(store: UserStore) { ... }
```

Then a fake is a small object literal. This is how Node's own
`net.Server` and `http.Server` are designed (small interfaces with
hand-rolled stubs in tests). Mock libraries are unnecessary.

### Other testing tools

- **Coverage**: `c8 --reporter=text --reporter=lcov node --test ...`.
  Aim for >80% on changed code, not 100% on everything.
- **Snapshot tests**: `t.assert.snapshot(value)` — built-in (Node 22+),
  stored in `<filename>.snapshot`. Update with `--test-update-snapshots`.
- **Test isolation**: `node --test` runs each test file in its own
  process. State leaks across files are impossible by default.
- **Filtering**: `--test-name-pattern='regex'` runs matching tests.
- **`--watch`** mode is built-in.

## 6. Async and concurrency

- `async` / `await` everywhere. Don't mix with `.then`.
- Top-level await works in ESM. Use it for one-shot scripts.
- For fan-out, `Promise.allSettled` is usually safer than
  `Promise.all` (the latter rejects on first failure and abandons
  in-flight work). Inspect the results array and decide.
- For cancellation, **AbortSignal**. Pass `signal` as an option;
  every Node API that does I/O accepts it. `AbortController` is the
  way to cancel.
  ```ts
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 5000);
  await fetch(url, { signal: ac.signal });
  ```
- `setTimeout` / `setInterval` from `node:timers/promises` for
  promise-friendly waits.
- Worker threads (`node:worker_threads`) for CPU-bound parallelism.
  Don't reach for them by default — most Node workloads are I/O-bound
  and single-threaded async is sufficient.
- Never `await` inside a `forEach`. Use `for...of` (sequential) or
  `Promise.all(arr.map(async ...))` (parallel).

## 7. Logging

- **Production**: `pino` (fast, JSON, structured) is the de-facto
  choice. ~10x faster than `winston`. Use child loggers for context.
- **Development**: `pino-pretty` for human-readable output.
- **Tests**: don't log; use assertions. The test runner captures
  output anyway, and noise hides real failures.
- **Library code**: don't pick a logger. Accept an opaque logger
  interface (`{ info(msg, fields?), error(msg, fields?) }`) and let
  the consumer plug their choice in.
- **Never** log secrets or full request bodies in production.
  Sanitisers exist (`pino`'s `redact` option) but the cleanest fix
  is to log only what you need.

## 8. CI/CD pipeline

The template's `.github/workflows/ci.yml` runs steps in this order —
fastest first, so a typo fails fast:

1. **`actions/setup-node@v4`** with `cache: 'npm'` — restores both
   the `node_modules` cache and the npm download cache.
2. **`npm ci`** — frozen-lockfile install. Fails if `package.json`
   and `package-lock.json` disagree.
3. **`npm run lint`** — Biome check.
4. **`npm run typecheck`** — `tsc --noEmit`.
5. **`npm run test:cov`** — `node --test` under `c8`.
6. **`npm run audit`** — `npm audit --audit-level=high`. High and
   critical vulns block; moderate/low are advisory.
7. **`npm run build`** — `tsc` emits `dist/`.

Node version: single-pinned to **24** (Active LTS, EOL 2028-04) via
`.node-version`; CI reads that same file (`node-version-file`), so a
bump is one edit. `engines.node` is `>=24` and `.npmrc` sets
`engine-strict=true`, so an older Node hard-fails `npm install` rather
than silently building against the wrong runtime. When Node 26 becomes
Active LTS (Oct 2026) and 24 leaves Active, bump the pin 24 → 26.

Pre-commit hooks (via `simple-git-hooks` — zero-deps, declared
inline in `package.json`):
- **pre-commit**: `npm run lint` + `npm run typecheck` (fast, < 5s)
- **pre-push**: `npm run test:cov` (full test suite, < 30s for most
  projects)

So `git push` enforces what `make check` and CI enforce.

## 9. Build & publish

```bash
npm run build        # tsc → dist/
npm publish --access=public   # publishes per package.json "files" whitelist
```

`tsc` is the right build tool for **libraries**. It emits `.js` +
`.d.ts` + `.js.map` + `.d.ts.map` — everything consumers need for
both runtime and IDE.

For **CLIs that ship as a single file**, swap to `tsup` or `esbuild`:
```bash
tsup src/cli.ts --format=esm --dts --clean
```

For **applications run from source** (no publish), don't build at
all. Just `node --import tsx src/index.ts` in production.

`prepublishOnly` in `package.json` runs `build` before publish, so
the dist is fresh on every release.

## 10. Security

- **`npm audit --audit-level=high`** in CI. Moderate/low are noise;
  high and critical block.
- **Dependabot** (configured in `.github/dependabot.yml`) opens
  weekly grouped PRs for npm and github-actions. Group dev vs runtime
  so the noisy dev updates don't drown out runtime patches.
- **No `eval` / `Function()` / `vm.runInThisContext`** in app code.
  Biome's recommended set warns on `eval`.
- Set `permissions: contents: read` on workflows (template does
  this). Limits the GITHUB_TOKEN to the minimum needed.
- For npm publish, use **trusted publishing** (OIDC) when available;
  else a granular token with publish-only scope, never a full token.

## 11. Performance

- **Don't optimize without a benchmark.** `node --test --benchmark`
  is built-in (Node 22.10+), or use `mitata` for richer comparison.
- `node --inspect` + Chrome DevTools profiler is excellent for ad-hoc
  flamegraphs. `0x` for an automated flamegraph from a CLI run.
- Allocations matter more than micro-CPU savings. Watch the heap
  with `node --inspect` and the Allocation Timeline panel.
- `--max-old-space-size=N` raises the heap limit when needed (for
  one-off scripts processing big datasets).

## 12. Reliability checklist for production code

- HTTP servers set explicit timeouts (`server.requestTimeout`,
  `server.headersTimeout`, `server.keepAliveTimeout`). Defaults are
  not always safe.
- HTTP clients (`fetch` or `undici`) set a `signal` with a timeout.
  Default `fetch` blocks indefinitely.
- Always handle stream backpressure — `stream.pipeline` from
  `node:stream/promises`, never raw `.pipe()` chains.
- Use `signal.NotifyContext`-equivalent: catch `SIGTERM` /  `SIGINT`,
  signal an `AbortController`, drain in-flight work, exit cleanly.
- Long-running loops poll `signal.aborted` regularly.
- No unbounded queues. Set `highWaterMark` explicitly on streams and
  caps on queues.

## 13. Dependencies

- Stdlib first. Modern Node has `fetch`, `URL`, `crypto.subtle`,
  streams, http(s), worker_threads, test, etc. — most "small utility"
  packages are unneeded.
- Each dep is a future CVE, a build dep, and a maintenance hazard.
- Trusted ecosystems for hobby/production use:
  - Node core (`node:*` imports)
  - `pino` (logging), `zod` (runtime validation), `undici` (HTTP),
    `valibot` (smaller `zod` alternative), `pg` (Postgres)
  - `@types/*` from DefinitelyTyped — first-party for many libs
- Avoid: anything unmaintained > 1 year, anything with a single
  contributor, anything that wraps stdlib for "ergonomics" only,
  micro-utilities (`is-odd`, `left-pad` style).

## 14. Documentation

- **Per-package**: a `README.md` for humans (install, usage, contract);
  a `CLAUDE.md` for the agent (workflow, conventions, project layout).
- **Per public function/class**: TSDoc comments. They show in IDEs and
  feed `typedoc` if you generate API docs.
- **Build log**: `docs/build-log.md` is the chronological narrative.
  Update it as you land features. The git log is per-commit; the build
  log is per-decision. Both are useful and they don't duplicate.
- **`SPEC.md` / `STATUS.md`**: optional, but extremely useful for
  multi-milestone projects. SPEC.md is the design contract;
  STATUS.md is the current state vs the contract.

## 15. What this template gives you out of the box

- Project layout with `src/`, `docs/`, `dist/`
- A working `greet()` function with table-driven tests in
  `src/index.test.ts` demonstrating the canonical idiom
- `Makefile` with the same target verbs as the Python and Go templates
  (`install`, `test`, `watch`, `lint`, `check`, `push`, `pull`, `log`)
- `tsconfig.json` with the modern strict options (`noUncheckedIndexedAccess`,
  `exactOptionalPropertyTypes`, `verbatimModuleSyntax`)
- `biome.json` configured for ESM, single quotes, 2-space indent, 100-col
  lines, recommended rules + a few extras
- `package.json` scripts matching Makefile targets, `simple-git-hooks`
  pre-commit (lint + typecheck) and pre-push (test:cov), `engines.node`
  `>=24` (enforced by `.npmrc` `engine-strict=true`)
- `.github/workflows/ci.yml` running install / lint / typecheck /
  test+cov / audit / build on the pinned Node (read from `.node-version`)
- `.github/dependabot.yml` for weekly grouped dep updates
- `direnv` `.envrc` adding `./node_modules/.bin` to PATH and loading
  `.env` if present
- `docs/build-log.md` starter with a "how to use this log" section
- A first-class `CLAUDE.md` describing the workflow for the agent

## 16. New project setup

```bash
cp -r ~/scripts/templates/node ~/projects/myapp
cd ~/projects/myapp

# Set the package name (replace 'myproject' everywhere)
grep -rl 'myproject' --include='*.json' --include='*.md' --include='*.ts' --include='Makefile' \
  | xargs sed -i 's/myproject/myapp/g'

# Install deps + tools + git hooks, then verify
make install
make check

# Data dir lives outside the repo (see ~/scripts/FILESYSTEM.md)
mkdir -p ~/data/myapp/{input,output,db}

# Initialize and push
git init -b main
git remote add origin git@github.com:rafael5/myapp.git
git add .
git commit -m "initial commit from node template"
make push
```

## 17. Build log convention

`docs/build-log.md` is a chronological narrative of *why* the project
got to its current shape, in addition to the *what* in `git log`.

Format: dated entries, each with a short heading and a few paragraphs.
Useful sub-sections per entry: **Done**, **Tried and reverted**,
**Deferred**, **Smoke results**.

```markdown
## 2026-04-26 — initial scaffold

**Done:**
- Project bootstrapped from ~/scripts/templates/node
- `greet()` function added with table-driven tests, 100% coverage
- CI green on the pinned Node 24

**Tried and reverted:**
- (nothing yet)

**Deferred:**
- Publish to npm — waiting on a real API surface
```

`make log MSG="…"` appends a dated entry. Keep entries small —
better one entry per landed change than a big retrospective once a
month. The log is for *humans reading the project later*, including
you in six months.

## 18. Module resolution gotchas

A few Node-specific traps the template avoids but that come up when
adding deps:

- **Dual-package hazard**: a library shipped as both CJS and ESM can
  end up loaded twice (once each format), with two copies of its
  internal state. Modern libraries are ESM-only (good); older ones
  use `"exports"` with conditional `import`/`require` that's tricky.
  `import { ... } from 'pkg'` should be your default; only fall back
  to `require` for legacy.
- **Subpath imports**: `import {} from 'pkg/sub'` only works if `pkg`
  declares `"exports": { "./sub": ... }` in its `package.json`. Many
  packages don't and require a deep import path. Check before relying.
- **Native modules**: anything using `node-gyp` (better-sqlite3, sharp,
  bcrypt) needs prebuilds for the target platform/arch or it builds
  on install. Pin Node version, use `prebuild-install`, or use a
  pure-JS alternative (`bcryptjs`, `sql.js`).
- **`tsx` vs Node-native TS**: Node 22.6+ supports `--experimental-strip-types`
  for native TS without a transpiler. Once stable (likely Node 24+),
  the template will switch off `tsx`. For now `tsx` is more
  ergonomic.
