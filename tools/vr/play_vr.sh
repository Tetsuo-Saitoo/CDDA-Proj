#!/usr/bin/env bash
# Starts the VR view (docs/BUILD.md step 6). Prefers SteamVR's OpenXR runtime when SteamVR is installed in
# Steam's usual places and no runtime was picked by hand (XR_RUNTIME_JSON); otherwise the system's active
# OpenXR runtime (Monado, WiVRn, ...) is used.
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
echo "OpenXR runtime: ${XR_RUNTIME_JSON:-the active system runtime}"
exec "$godot" --xr-mode on --path "$root/client" -- --vr "$@"
