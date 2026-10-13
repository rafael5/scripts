#!/usr/bin/env bash
# guest-screens-test.sh — guest-screens records a guest with a window and
# not a headless one: v-factory's batches start the guest headless, and
# their runs were recorded as a session (2026-10-13). Sources the script for
# its functions, with a stand-in VBoxManage on the PATH.
# Usage: bash ~/scripts/tests/guest-screens-test.sh
set -euo pipefail

fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
cat >"$fake/VBoxManage" <<'STUB'
#!/usr/bin/env bash
case "$1" in
list) [ -n "${FAKE_STATE:-}" ] && echo "\"win10_x64\" {f7b2e631-8812-4bd6-9fed-293e37da3570}" ;;
showvminfo) printf 'name="win10_x64"\nVMState="running"\n'
	[ -n "${FAKE_SESSION:-}" ] && printf 'SessionName="%s"\n' "$FAKE_SESSION" ;;
esac
exit 0
STUB
chmod +x "$fake/VBoxManage"
PATH=$fake:$PATH
# shellcheck source=/dev/null
source "$HOME/scripts/bin/guest-screens"

fails=0
check() { # check WANT STATE SESSION
	local got=no
	if FAKE_STATE=$2 FAKE_SESSION=$3 windowed; then got=yes; fi
	if [ "$got" != "$1" ]; then
		echo "FAIL: running=${2:-no} session=${3:-none}: windowed=$got, want $1"
		fails=$((fails + 1))
	fi
}
check yes on "GUI/Qt"   # a hand run's window
check yes on ""         # no session name reported: recorded, as before
check no on "headless"  # a batch
check no "" "GUI/Qt"    # not running
[ "$fails" -eq 0 ] && echo "guest-screens-test: ok" || exit 1
