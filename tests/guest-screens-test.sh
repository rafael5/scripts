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

# --install writes a user unit naming this script by its path today, run as
# --service, restarting only on a failure and stopping after three in ten
# minutes (machine-setup.md: a unit that restarts always hides a failure as
# activity); --uninstall takes it away; --status says what is there. Run
# with a stand-in systemctl and a scratch HOME, so nothing real is touched.
scratch=$(mktemp -d)
cat >"$fake/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"$HOME/systemctl.log"
[ "$2" = is-active ] && echo active
exit 0
STUB
chmod +x "$fake/systemctl"
self=$(readlink -f "$HOME/scripts/bin/guest-screens")
gs() { HOME=$scratch PATH=$fake:$PATH timeout 10 bash "$self" "$@"; }
unitfile=$scratch/.config/systemd/user/guest-screens.service
want_in() { # want_in FILE TEXT
	if ! grep -qF -- "$2" "$1" 2>/dev/null; then
		echo "FAIL: $1 lacks: $2"
		fails=$((fails + 1))
	fi
}
gs --install >/dev/null
want_in "$unitfile" "ExecStart=$self --service"
want_in "$unitfile" "Restart=on-failure"
want_in "$unitfile" "StartLimitBurst=3"
want_in "$scratch/systemctl.log" "systemctl --user enable --now guest-screens.service"
gs --status >"$scratch/status" 2>&1
want_in "$scratch/status" "active"
want_in "$scratch/status" "ExecStart=$self --service"
gs --uninstall >/dev/null
if [ -e "$unitfile" ]; then
	echo "FAIL: --uninstall left $unitfile"
	fails=$((fails + 1))
fi
want_in "$scratch/systemctl.log" "systemctl --user disable --now guest-screens.service"
# The service waits for the lock while a manual recorder holds it, rather
# than fail and be restarted in a loop.
mkdir -p "$scratch/data/vista-forge/cprs-screens"
(
	exec 9>"$scratch/data/vista-forge/cprs-screens/.lock"
	flock 9
	sleep 5
) &
holder=$!
sleep 0.5
rc=0
HOME=$scratch PATH=$fake:$PATH timeout 2 bash "$self" --service >/dev/null 2>&1 || rc=$?
kill "$holder" 2>/dev/null || true
if [ "$rc" -ne 124 ]; then
	echo "FAIL: the service did not wait for a manual recorder's lock (exit $rc)"
	fails=$((fails + 1))
fi
# With no recorder holding the lock, the service runs until it is stopped:
# one that ended by itself would end as a success and not be restarted.
rc=0
HOME=$scratch PATH=$fake:$PATH timeout 2 bash "$self" --service >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 124 ]; then
	echo "FAIL: the service ended by itself (exit $rc)"
	fails=$((fails + 1))
fi
rm -rf "$scratch"
[ "$fails" -eq 0 ] && echo "guest-screens-test: service ok" || exit 1
