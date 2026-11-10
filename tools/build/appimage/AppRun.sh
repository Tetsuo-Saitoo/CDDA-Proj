#!/bin/sh
# Starts CDDA-3D from its AppImage (tools/build/appimage.sh copies this file in as AppRun).
#   CDDA-3D-x86_64.AppImage [--vr] [--town] [game options, docs/BUILD.md]
# The live CDDA game on the desktop by default, from CDDA's main menu (new game or a save; F5 and closing the
# window save); --town shows the mock town instead (no CDDA game).
# --vr: the VR view through the system's OpenXR runtime. Like tools/vr/play_vr.sh, SteamVR's runtime is preferred
# when SteamVR is installed in Steam's usual places and XR_RUNTIME_JSON isn't set, and SteamVR is started first.
# Saves, keys and logs stay outside the image: ~/.local/share/godot/app_userdata/CDDA-3D/.
set -eu
here="${APPDIR:-$(dirname "$(readlink -f "$0")")}"
app="$here/usr/lib/cdda-3d"

vr=0
town=0
for a in "$@"; do
    case "$a" in
        --vr) vr=1 ;;
        --town) town=1 ;;
    esac
done
# The game's own options: everything except --town, with --live added for a live game.
n=$#
i=0
while [ "$i" -lt "$n" ]; do
    a="$1"
    shift
    i=$((i + 1))
    [ "$a" = "--town" ] || set -- "$@" "$a"
done
[ "$town" = 1 ] || set -- --live "$@"

if [ "$vr" = 1 ]; then
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
                t=0
                until pgrep -f vrcompositor >/dev/null; do
                    t=$((t + 1))
                    if [ "$t" -ge 60 ]; then echo "SteamVR didn't start within 60 s; trying anyway"; break; fi
                    sleep 1
                done
                sleep 5   # the compositor needs a few more seconds before it takes sessions
            fi
            ;;
    esac
    echo "OpenXR runtime: ${XR_RUNTIME_JSON:-the active system runtime}"
fi

# The bundled libraries (usr/lib/cdda-3d/libs: SDL2 and what it needs) load through the bridge's RPATH only.
if [ "$vr" = 1 ]; then
    exec "$app/cdda-3d.x86_64" --xr-mode on -- "$@"
fi
exec "$app/cdda-3d.x86_64" -- "$@"
