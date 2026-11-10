#!/usr/bin/env bash
# Fetches Godot 4.7.2's Linux editor for CI (tools/build/ci_linux.sh) and checks it against a pinned SHA-256
# (taken from the zip that matched Godot's own SHA512-SUMS.txt).
#   bash tools/build/ci_godot.sh [dir]     (default ~/godot) -> <dir>/Godot_v4.7.2-stable_linux.x86_64
set -euo pipefail
ver=4.7.2
zip_sha=cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4
bin_sha=8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e
dir="${1:-$HOME/godot}"
exe="$dir/Godot_v$ver-stable_linux.x86_64"
if [ -x "$exe" ] && [ "$(sha256sum <"$exe" | cut -d' ' -f1)" = "$bin_sha" ]; then echo "$exe"; exit 0; fi
mkdir -p "$dir"
zip="$dir/godot.zip.part"
curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$zip" \
    "https://github.com/godotengine/godot/releases/download/$ver-stable/Godot_v$ver-stable_linux.x86_64.zip"
[ "$(sha256sum <"$zip" | cut -d' ' -f1)" = "$zip_sha" ] || { rm -f "$zip"; echo "ci_godot.sh: checksum mismatch" >&2; exit 1; }
python3 -I - "$zip" "$exe" "Godot_v$ver-stable_linux.x86_64" <<'PY'
import shutil, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, z.open(sys.argv[3]) as f, open(sys.argv[2], "wb") as o:
    shutil.copyfileobj(f, o)
PY
rm -f "$zip"
[ "$(sha256sum <"$exe" | cut -d' ' -f1)" = "$bin_sha" ] || { rm -f "$exe"; echo "ci_godot.sh: editor checksum mismatch" >&2; exit 1; }
chmod 755 "$exe"
echo "$exe"
