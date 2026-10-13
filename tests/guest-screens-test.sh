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

# A session's end writes contact sheets beside its frames, thirty frames a
# sheet, each thumbnail labelled with its frame's number; and --timeline
# RUN joins a v-factory run's calls to the frames of its session, each call
# under the last frame taken before it, by the run's own clocks (the copy's
# clock is its instant plus the time since the copy started).
scratch=$(mktemp -d)
sess=$scratch/data/vista-forge/cprs-screens/20261013T144258Z
mkdir -p "$sess"
printf 'seq\tfile\tutc\tt_s\n' >"$sess/frames.tsv"
t=0
for n in $(seq 1 32); do
	f=$(printf '%04d-20261013T1443%02dZ.png' "$n" "$t")
	convert -size 1024x784 xc:"rgb(0,32,$((96 + n)))" "$sess/$f"
	printf '%d\t%s\t20261013T1443%02dZ\t%d\n' "$n" "$f" "$t" "$t" >>"$sess/frames.tsv"
	t=$((t + 1))
done
(
	HOME=$scratch
	# shellcheck source=/dev/null
	source "$self" 2>/dev/null
	finish "$sess" 40 >/dev/null
)
for s in sheet-1.png sheet-2.png; do
	if [ ! -s "$sess/$s" ]; then
		echo "FAIL: no $s beside the frames"
		fails=$((fails + 1))
	fi
done
if [ -e "$sess/sheet-3.png" ]; then
	echo "FAIL: a third sheet for 32 frames"
	fails=$((fails + 1))
fi
run=$scratch/run
mkdir -p "$run"
cat >"$run/entry.json" <<'JSON'
{"instant": "2026-10-05T06:02:00Z", "copyStarted": "2026-10-13T14:42:58.500000000Z",
 "began": "2026-10-13T10:42:55-04:00", "ended": "2026-10-13T10:44:30-04:00", "dir": "RUNDIR"}
JSON
cat >"$run/calls.json" <<'JSON'
{"schema": "x", "calls": [
 {"seq": 1, "rpc": "XUS SIGNON SETUP", "at": "67848,21726"},
 {"seq": 2, "rpc": "ORWU USERINFO", "at": "67848,21726"},
 {"seq": 3, "rpc": "ORWPT SELECT", "at": "67848,21740"}]}
JSON
gs --timeline "$run" >/dev/null
tl=$sess/timeline.tsv
# 21726 is 06:02:06 on the copy's clock, six seconds after its start: 14:43:04.5
# here, under frame 5 (14:43:04); 21740 is 14:43:18.5, under frame 19.
want_in "$tl" "$run"
want_in "$tl" "$(printf '5\t0005-20261013T144304Z.png\t20261013T144304Z\t')"
want_in "$tl" "$(printf '\t2\t1-2\tXUS SIGNON SETUP, ORWU USERINFO')"
want_in "$tl" "$(printf '19\t0019-20261013T144318Z.png')"
want_in "$tl" "$(printf '\t1\t3-3\tORWPT SELECT')"
if [ "$(grep -c $'\t0\t\t' "$tl")" -ne 30 ]; then
	echo "FAIL: $tl does not list the 30 frames with no call as such:"
	cat "$tl"
	fails=$((fails + 1))
fi
# A run two frame sessions began during is refused: which is its own is
# not known.
mkdir -p "$scratch/data/vista-forge/cprs-screens/20261013T144400Z"
cp "$sess/frames.tsv" "$scratch/data/vista-forge/cprs-screens/20261013T144400Z/"
rc=0
gs --timeline "$run" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
	echo "FAIL: --timeline chose one of two sessions during the run"
	fails=$((fails + 1))
fi
rm -rf "$scratch/data/vista-forge/cprs-screens/20261013T144400Z"
# A run no frame session began during is refused, never joined to another.
sed -i 's/2026-10-13T10:42:55-04:00/2026-10-12T10:42:55-04:00/; s/2026-10-13T10:44:30-04:00/2026-10-12T10:44:30-04:00/' "$run/entry.json"
rc=0
gs --timeline "$run" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
	echo "FAIL: --timeline joined a run to a session that began a day after it"
	fails=$((fails + 1))
fi
rc=0
gs --timeline "$scratch/nowhere" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
	echo "FAIL: --timeline of no run went on"
	fails=$((fails + 1))
fi
rm -rf "$scratch"
[ "$fails" -eq 0 ] && echo "guest-screens-test: sheets and timeline ok" || exit 1
