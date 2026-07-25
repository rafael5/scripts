# myproject

<!-- One paragraph: what this does, who it's for, why it exists. -->

## Install

```bash
make install
```

## Usage

```bash
myproject --help
```

## Develop

```bash
make test       # pytest, stop on first failure, random order
make watch      # auto-rerun tests on file save (TDD)
make check      # lint + mypy + coverage (CI gate)
make format     # ruff format
make push       # check + git push
```

See [`CLAUDE.md`](CLAUDE.md) for the full dev workflow and project conventions.

## Layout

```
src/myproject/   # importable package
tests/           # pytest, mirrors src/
docs/            # long-form docs
scripts/         # one-off dev helpers (optional)
```

## License

<!-- Add a LICENSE file (e.g. MIT) before publishing. -->
