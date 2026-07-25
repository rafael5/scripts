# Claude Project Context

## What this project is
<!-- One paragraph: what does this app do, who uses it, why does it exist -->

## Dev workflow
```bash
make install    # create .venv, install deps, install pre-commit hooks
make test       # run pytest — stops at first failure (-x), random order
make test-lf    # rerun only the tests that failed last time
make watch      # TDD mode: auto-rerun tests on file save
make cov        # run pytest with coverage report
make check      # lint + mypy + cov (full gate — same as CI)
make format     # auto-format with ruff
make push       # check + git push
make pull       # git pull origin main
```

## Environment
- Python 3.12, managed via `uv`
- Virtual env: `.venv/` (auto-activated via direnv + `.envrc`)
- Deps declared in `pyproject.toml`
- Lockfile: `uv.lock` — always commit after adding/changing dependencies

## Adding a dependency
```bash
# 1. Add to pyproject.toml under [project.dependencies] or [project.optional-dependencies].dev
# 2. Re-lock and sync:
uv lock && uv sync --extra dev
# 3. Commit both pyproject.toml and uv.lock
```

## Project structure
```
src/myproject/     # all application code lives here
tests/             # mirrors src/ structure: src/foo.py -> tests/test_foo.py
```

## Testing conventions
- Write the test first (TDD)
- One test file per source module
- `conftest.py` handles sys.path — no install needed to run tests
- Coverage minimum: 80% (enforced in CI and `make check`)

## Code style
- Formatter + linter: `ruff` only (no black)
- Line length: 88
- Rules: E, F, I (errors, pyflakes, isort)
- Pre-commit hooks enforce style on every commit

## Git conventions
- Main branch: `main`
- Pre-push hook runs `pytest` — push fails if tests fail
- `make push` runs full `check` before pushing
- Commit messages: short imperative ("add retry logic", "fix timeout bug")
- Always commit `uv.lock` alongside `pyproject.toml` changes

## Debugging
```bash
pytest --pdb          # drop into debugger on first failure
pytest -k "test_name" # run a single test by name
pytest -s             # show print output (normally captured)
```
Inside any function: `breakpoint()` pauses execution and opens the debugger.
Logging is configured in `__init__.py` — use `logging.getLogger(__name__)` in modules, not `print()`.

## Claude guidelines
- Prefer editing existing files over creating new ones
- Keep functions small and independently testable
- Use `logging` not `print()` in library code
- No mocks unless unavoidable — prefer real objects and fakes
- This is a small hobbyist project — keep solutions simple and direct
