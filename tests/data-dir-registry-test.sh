#!/usr/bin/env bash
# data-dir-registry-test.sh — the registry lists every entry of the data folder
# whatever folder it is started from. Started outside ~/data it wrote an empty
# table, and --check then called the empty table current (2026-10-17).
# Usage: bash ~/scripts/tests/data-dir-registry-test.sh
set -euo pipefail

root=$(mktemp -d)
elsewhere=$(mktemp -d)
trap 'rm -rf "$root" "$elsewhere"' EXIT
mkdir -p "$root/alpha/sub" "$root/beta"
echo x >"$root/alpha/sub/file"
ln -s "$root/beta" "$root/gamma"
registry=$root/data-dir-registry.md
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cd "$elsewhere"
DATA_ROOT=$root "$HOME/scripts/bin/data-dir-registry" >/dev/null
for name in alpha beta gamma; do
	grep -q "^| \`$name\` |" "$registry" || fail "$name has no row when run from another folder"
done
grep -q '^| `alpha` | 1 | 1 |' "$registry" || fail "alpha's counts are not 1 subdirectory and 1 file"
DATA_ROOT=$root "$HOME/scripts/bin/data-dir-registry" --check >/dev/null || fail "--check reds a registry just written"
mkdir "$root/delta"
if DATA_ROOT=$root "$HOME/scripts/bin/data-dir-registry" --check >/dev/null; then
	fail "--check from another folder misses a new directory"
fi

# A subtree this user cannot read is counted as far as it goes and its row says
# so; it must not stop the script (it did under set -e, 2026-10-17).
rm -rf "$root/delta"
mkdir -p "$root/epsilon/locked"
chmod 000 "$root/epsilon/locked"
DATA_ROOT=$root "$HOME/scripts/bin/data-dir-registry" >/dev/null || fail "a locked subtree stops the write"
grep -q '^| `epsilon` |.*partial — 1 unreadable' "$registry" || fail "epsilon's row does not say it is partial"
DATA_ROOT=$root "$HOME/scripts/bin/data-dir-registry" --check >/dev/null || fail "a locked subtree reds --check"
chmod 755 "$root/epsilon/locked"

[ "$fails" -eq 0 ] && echo "data-dir-registry-test: ok" || exit 1
