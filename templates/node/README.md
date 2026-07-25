# myproject

> One-line description of what this package does.

## Install

```bash
npm install myproject
```

## Usage

```ts
import { greet } from 'myproject';

console.log(greet('Ada'));                            // "Hello, Ada!"
console.log(greet('Lovelace', { title: 'Dr.' }));     // "Hello, Dr. Lovelace!"
```

## Develop

See [`CLAUDE.md`](CLAUDE.md) for the project conventions
(test-first, Biome-formatted, Node ≥ 22, etc.) and
[`node-dev-guide.md`](node-dev-guide.md) for the reasoning behind
the choices.

```bash
make install     # npm install + git hooks
make test        # node --test (built-in runner)
make test-watch  # TDD mode
make check       # lint + typecheck + test-cov + audit (full gate)
make push        # check + git push
```

The chronological log of feature landings and design decisions lives
in [`docs/build-log.md`](docs/build-log.md).

## License

MIT — see [`LICENSE`](LICENSE).
