#!/bin/bash
# Automated checks in a real VR session under SteamVR's null headset (TASKS "VR without a headset"), Windows Git Bash.
#   tools/vr/vr_check.sh <scenarios, e.g. report> [client options, e.g. --live]
# Starts SteamVR when it isn't running (and closes it again afterwards), runs the client with --vr --vr-check, and
# prints the "vr check" lines; the full output goes to tools/out/vr-check.log (git-ignored). Exit code: 0 all ok, 1 not.
# Godot: $GODOT, else Godot_v4.7.2-stable_win64_console.exe on the PATH. Steam: $STEAM, else Program Files (x86).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-Godot_v4.7.2-stable_win64_console.exe}"
STEAM="${STEAM:-/c/Program Files (x86)/Steam}"
SVR="$STEAM/steamapps/common/SteamVR"
export XR_RUNTIME_JSON="$(cygpath -w "$SVR/steamxr_win64.json")"
up() { tasklist //FI "IMAGENAME eq vrcompositor.exe" | grep -qi vrcompositor; }
svr_up() { tasklist | grep -qiE "^(vrserver|vrmonitor|vrcompositor|vrdashboard|vrwebhelper)\.exe"; }   # SteamVR's own
started=0
if ! up; then
  "$SVR/bin/win64/vrstartup.exe" &
  started=1
  for i in $(seq 1 60); do up && break; sleep 2; done
  sleep 6   # the compositor takes sessions a few seconds after it starts
fi
mkdir -p "$ROOT/tools/out"
log="$ROOT/tools/out/vr-check.log"   # git-ignored
for try in 1 2 3; do   # a SteamVR that has just started sometimes refuses the first session
  timeout 300 "$GODOT" --xr-mode on --path "$ROOT/client" -- --vr --vr-check="${1:-report}" "${@:2}" > "$log" 2>&1
  grep -q "OpenXR: Failed to create session" "$log" || break
  echo "no VR session (try $try), again in 10 s"
  sleep 10
done
grep -E "^vr check" "$log"
grep -q "^vr check: [0-9]* ok, 0 failed" "$log"
ok=$?
if [ "$started" = 1 ]; then   # only SteamVR this run started
  for k in 1 2 3 4; do   # a graceful close; SteamVR sometimes ignores the first
    taskkill //IM vrmonitor.exe > /dev/null 2>&1
    for i in $(seq 1 10); do svr_up || break; sleep 2; done
    svr_up || break
  done
  svr_up && echo "SteamVR is still up: close it from its window"
fi
exit $ok
