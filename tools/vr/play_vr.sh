#!/usr/bin/env bash
# Starts the VR view (docs/BUILD.md step 6). Prefers SteamVR's OpenXR runtime when SteamVR is installed in
# Steam's usual places and no runtime was picked by hand (XR_RUNTIME_JSON); otherwise the system's active
# OpenXR runtime (Monado, WiVRn, ...) is used. With SteamVR it starts SteamVR first and waits for it: the
# game can't open a VR session before SteamVR's compositor runs.
#   tools/vr/play_vr.sh [client options, e.g. --live --vr-turn=smooth]
# Godot: $GODOT, else `godot` on the PATH (must be 4.7.x).
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
godot="${GODOT:-godot}"
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
        if ! pgrep -f vrcompositor >/dev/null && [ -x "$startup" ]; then
            echo "Starting SteamVR..."
            "$startup" >/dev/null 2>&1 &
            n=0
            until pgrep -f vrcompositor >/dev/null; do
                n=$((n + 1))
                if [ "$n" -ge 60 ]; then echo "SteamVR didn't start within 60 s; trying anyway"; break; fi
                sleep 1
            done
            sleep 5   # the compositor needs a few more seconds before it takes sessions
        fi
        ;;
esac
echo "OpenXR runtime: ${XR_RUNTIME_JSON:-the active system runtime}"
exec "$godot" --xr-mode on --path "$root/client" -- --vr "$@"
