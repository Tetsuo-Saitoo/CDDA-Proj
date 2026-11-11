#!/usr/bin/env bash
# Starts the VR view (docs/BUILD.md step 6). Prefers SteamVR's OpenXR runtime when SteamVR is installed in
# Steam's usual places and no runtime was picked by hand (XR_RUNTIME_JSON); otherwise the system's active
# OpenXR runtime (Monado, WiVRn, ...) is used. With SteamVR it starts SteamVR first and waits for it (at most
# steamvr_wait seconds, less when SteamVR gives up): the game can't open a VR session before SteamVR's
# compositor runs. The same wait as the AppImage's AppRun.sh.
#   tools/vr/play_vr.sh [client options, e.g. --live --vr-turn=smooth]
# Godot: $GODOT, else `godot` on the PATH (must be 4.7.x).
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
godot="${GODOT:-godot}"
# A line on the console, and a desktop notification when one can be shown (nothing else is on screen until
# Godot's window opens).
say() {
    echo "$1" >&2
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "CDDA-3D" "$1" >/dev/null 2>&1 || true
    fi
}
steamvr_wait=30   # seconds; SteamVR usually has its compositor up in 10-20 s
if [ -z "${XR_RUNTIME_JSON:-}" ]; then
    for steam in "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
                 "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        json="$steam/steamapps/common/SteamVR/steamxr_linux64.json"
        if [ -f "$json" ]; then
            export XR_RUNTIME_JSON="$json"
            break
        fi
    done
fi
case "${XR_RUNTIME_JSON:-}" in
    *steamxr*)
        startup="$(dirname "$XR_RUNTIME_JSON")/bin/vrstartup.sh"
        if ! pgrep -u "$(id -u)" -f vrcompositor >/dev/null && [ -x "$startup" ]; then
            # Godot opens its window only once OpenXR has started, so say now what the wait is.
            say "Starting SteamVR first (up to $steamvr_wait s); the game window opens after it."
            "$startup" >/dev/null 2>&1 &
            t=0
            up=0
            while [ "$t" -lt "$steamvr_wait" ]; do
                if pgrep -u "$(id -u)" -f vrcompositor >/dev/null; then up=1; break; fi
                # Nothing of SteamVR, nor the Steam client it may hand over to, left running (it gave up or
                # crashed): don't wait out the rest.
                if [ "$t" -ge 10 ] && ! pgrep -u "$(id -u)" -f 'vrstartup|vrmonitor|vrserver' >/dev/null &&
                    ! pgrep -u "$(id -u)" -x steam >/dev/null; then
                    break
                fi
                sleep 1
                t=$((t + 1))
                [ $((t % 5)) -ne 0 ] || echo "  waiting for SteamVR: $t s" >&2
            done
            if [ "$up" = 1 ]; then
                sleep 5   # the compositor needs a few more seconds before it takes sessions
            else
                say "SteamVR isn't up after $t s; starting the game anyway (without it, it opens the desktop view)."
            fi
        fi
        ;;
esac
echo "OpenXR runtime: ${XR_RUNTIME_JSON:-the active system runtime}"
exec "$godot" --xr-mode on --path "$root/client" -- --vr "$@"
