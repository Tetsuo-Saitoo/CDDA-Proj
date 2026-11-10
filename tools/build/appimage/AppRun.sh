#!/bin/sh
# Starts CDDA-3D from its AppImage (tools/build/appimage.sh copies this file in as AppRun).
#   CDDA-3D-x86_64.AppImage [--vr] [--town] [game options, docs/BUILD.md]
# The live CDDA game on the desktop by default, from CDDA's main menu (new game or a save; F5 and closing the
# window save); --town shows the mock town instead (no CDDA game).
# --vr: the VR view through the system's OpenXR runtime. Like tools/vr/play_vr.sh, SteamVR's runtime is preferred
# when SteamVR is installed in Steam's usual places and XR_RUNTIME_JSON isn't set, and SteamVR is started first
# (at most 30 s, less when SteamVR gives up; nothing is waited for without SteamVR).
# Saves, keys and logs stay outside the image: ~/.local/share/godot/app_userdata/CDDA-3D/.
set -eu
here="${APPDIR:-$(dirname "$(readlink -f "$0")")}"
app="$here/usr/lib/cdda-3d"

# A line on the console, and a desktop notification when one can be shown (the AppImage is often started without a
# terminal, and nothing else is on screen until Godot's window opens).
say() {
    echo "$1" >&2
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "CDDA-3D" "$1" >/dev/null 2>&1 || true
    fi
}
steamvr_wait=30   # seconds; SteamVR usually has its compositor up in 10-20 s

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
            if ! pgrep -u "$(id -u)" -f vrcompositor >/dev/null && [ -x "$startup" ]; then
                # Godot opens its window only once OpenXR has started, so say now what the wait is.
                say "Starting SteamVR first (up to $steamvr_wait s); the game window opens after it."
                "$startup" >/dev/null 2>&1 &
                t=0
                up=0
                while [ "$t" -lt "$steamvr_wait" ]; do
                    if pgrep -u "$(id -u)" -f vrcompositor >/dev/null; then up=1; break; fi
                    # Nothing of SteamVR left running (it gave up or crashed): don't wait out the rest.
                    if [ "$t" -ge 5 ] && ! pgrep -u "$(id -u)" -f 'vrstartup|vrmonitor|vrserver' >/dev/null; then
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
fi

# The bundled libraries (usr/lib/cdda-3d/libs: SDL2 and what it needs) load through the bridge's RPATH only.
if [ "$vr" = 1 ]; then
    exec "$app/cdda-3d.x86_64" --xr-mode on -- "$@"
fi
exec "$app/cdda-3d.x86_64" -- "$@"
