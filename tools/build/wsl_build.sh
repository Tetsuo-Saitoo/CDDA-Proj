#!/usr/bin/env bash
# Builds the Linux bridge inside WSL (or any Linux) from this checkout: docs/BUILD.md step 5, Linux.
# Copies the working tree (no git data, no build output) into a Linux folder first, because building on
# /mnt/<drive> is slow, then builds there with preset fp3d-linux and copies the .so back to client/bin/.
#   bash tools/build/wsl_build.sh [targets...]      (default: fp3d-cdda; JOBS=<n> overrides the job count)
# Linux folder: $FP3D_LINUX_DIR, default ~/cdda3d, and next to it <folder>.mirror. Files deleted here are deleted
# there on the next run.
# CDDA's data cache (cdda/data/cache/) stays apart: Windows' entries carry other file times, and CDDA
# would stop at boot with "stale game data".
set -eu
src="$(cd "$(dirname "$0")/../.." && pwd -P)"
dst="$(realpath -m -- "${FP3D_LINUX_DIR:-$HOME/cdda3d}")"
mirror="$dst.mirror"
home="$(realpath -m -- "$HOME")"
# rsync --delete empties what it syncs into: never /, the checkout, home or a folder holding either, or one inside
# the checkout.
for d in "$dst" "$mirror"; do
    refuse=
    [ "$d" != / ] || refuse=1
    case "$src/" in "$d"/*) refuse=1 ;; esac
    case "$home/" in "$d"/*) refuse=1 ;; esac
    case "$d/" in "$src"/*) refuse=1 ;; esac
    if [ -n "$refuse" ]; then echo "refusing to sync into $d" >&2; exit 1; fi
done
mkdir -p "$dst" "$mirror"
skip=(--exclude=.git/ --exclude=/.claude/ --exclude=/cdda/out/ --exclude=/client/.godot/ --exclude=/tools/out/ --exclude=/game/
      --exclude='*.dll' --exclude='*.so' --exclude='*.pdb' --exclude='*.exp' --exclude='*.lib'
      --exclude=__pycache__/ --exclude=/cdda/CMakeUserPresets.json --exclude=/cdda/data/cache/)
# Two steps. The mirror keeps Windows' file times, so rsync's quick check (size and time) finds what changed
# without reading every file through /mnt. The build folder then gets only the files whose content differs, with
# the time of the copy: a file edited while an earlier build ran can't look older than its object file (ninja
# would skip it), and an unchanged file keeps its time, so nothing rebuilds for nothing.
rsync -a --delete "${skip[@]}" "$src/" "$mirror/"
rsync -a --no-times --checksum --delete "${skip[@]}" "$mirror/" "$dst/"
cp -p "$dst/tools/build/CMakeUserPresets.json" "$dst/cdda/"
cd "$dst/cdda"
# Configure on the first run and whenever the preset changed since.
stamp=out/build/fp3d-linux/fp3d-preset.stamp
if [ ! -f out/build/fp3d-linux/build.ninja ] || [ CMakeUserPresets.json -nt "$stamp" ]; then
    cmake --preset fp3d-linux
    touch "$stamp"
fi
if [ $# -eq 0 ]; then set -- fp3d-cdda; fi
# CDDA's big files take ~2 GB each to compile: more jobs than memory allows get killed by the OOM killer.
mem_gb=$(awk '/MemTotal/ { print int($2 / 1048576) }' /proc/meminfo)
jobs=$(( mem_gb / 2 )); [ "$jobs" -ge 1 ] || jobs=1; [ "$jobs" -le "$(nproc)" ] || jobs=$(nproc)
# KEEP_GOING=1: report every compile error in one run instead of stopping at the first.
cmake --build out/build/fp3d-linux --parallel "${JOBS:-$jobs}" --target "$@" -- ${KEEP_GOING:+-k 0}
if [ -f "$dst/client/bin/fp3d_cdda.linux.x86_64.so" ]; then
    cp "$dst/client/bin/fp3d_cdda.linux.x86_64.so" "$src/client/bin/"
fi
