#!/usr/bin/env bash
# Builds CDDA-3D as one AppImage for x86_64 Linux with glibc 2.38 or newer (Arch, Fedora 39+, Ubuntu 24.04+;
# older distros aren't supported). Run it in WSL Ubuntu 24.04 (or such a Linux) from the repo root. On Windows:
#   wsl.exe -d Ubuntu-24.04 --cd "<repo>" -- bash tools/build/appimage.sh
# Output in tools/out/appimage/: CDDA-3D-x86_64.AppImage, its .sha256 and THIRD_PARTY_LICENSES.txt.
# Steps: fetch the build tools once (Godot's Linux release template out of the 4.7.2 export templates, and the
# AppImage type2-runtime; both checked against the SHA-256 below), build the bridge (wsl_build.sh), export the
# client (client/export_presets.cfg, preset "Linux"), add CDDA's data and tilesets, the SDL2 libraries the
# bridge loads (from this Ubuntu, found through the bridge's RPATH) and the licences, then pack the AppImage.
# Inside: AppRun (tools/build/appimage/AppRun.sh) and usr/lib/cdda-3d/ with the game, its .pck, the bridge,
# libs/, cdda/{data,gfx}, assets/registry and contracts/mock. Saves, keys and settings stay in Godot's user
# folder (~/.local/share/godot/app_userdata/CDDA-3D/). No VR runtime inside: VR uses the system's OpenXR runtime.
# Needs: squashfs-tools rsync curl python3 binutils, the bridge's build packages (docs/BUILD.md) and Godot
# 4.7.2's Linux editor: $GODOT, else ~/tools/godot-4.7.2/Godot_v4.7.2-stable_linux.x86_64.
set -euo pipefail
umask 022

GODOT_VER=4.7.2
TPZ_URL="https://github.com/godotengine/godot/releases/download/$GODOT_VER-stable/Godot_v$GODOT_VER-stable_export_templates.tpz"
TPZ_SHA=f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011
TEMPLATE_SHA=d9f79ab89b5ae369aeed11c6052d402e8218cd503bf85b4a235f9c30c46a7c63   # templates/linux_release.x86_64 in the .tpz above
RUNTIME_URL=https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
RUNTIME_SHA=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

src="$(cd "$(dirname "$0")/../.." && pwd)"
dst="${FP3D_LINUX_DIR:-$HOME/cdda3d}"
tools="$HOME/tools"
godot="${GODOT:-$tools/godot-$GODOT_VER/Godot_v$GODOT_VER-stable_linux.x86_64}"
case "$dst" in
    /|"$HOME"|"$HOME"/|"$src"|"$src"/) echo "refusing to build in $dst" >&2; exit 1 ;;
esac
die() { echo "appimage.sh: $*" >&2; exit 1; }

for c in mksquashfs rsync curl python3 objcopy objdump nm sha256sum dpkg-query ldconfig git; do
    command -v "$c" >/dev/null || die "missing $c (sudo apt install squashfs-tools rsync curl python3 binutils git)"
done
[ -x "$godot" ] || die "no Godot $GODOT_VER editor at $godot (set GODOT)"
godot_version="$("$godot" --version 2>/dev/null | head -1 || true)"
case "$godot_version" in
    "$GODOT_VER.stable"*) ;;
    *) die "$godot isn't Godot $GODOT_VER" ;;
esac

sha_ok() { [ -f "$2" ] && [ "$(sha256sum <"$2" | cut -d' ' -f1)" = "$1" ]; }
fetch() {   # url sha256 file: downloads once, keeps it only when the checksum matches
    sha_ok "$2" "$3" && return 0
    echo "Downloading $1"
    mkdir -p "$(dirname "$3")"
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$3.part" "$1"
    sha_ok "$2" "$3.part" || { rm -f "$3.part"; die "checksum mismatch: $1"; }
    mv "$3.part" "$3"
}

# --- 1. Build tools (once) ---
runtime="$tools/appimage/runtime-x86_64-20251108"
fetch "$RUNTIME_URL" "$RUNTIME_SHA" "$runtime"
tpl_dir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$GODOT_VER.stable"
tpl="$tpl_dir/linux_release.x86_64"
if ! sha_ok "$TEMPLATE_SHA" "$tpl"; then
    tpz="$tools/downloads/Godot_v$GODOT_VER-stable_export_templates.tpz"
    fetch "$TPZ_URL" "$TPZ_SHA" "$tpz"
    mkdir -p "$tpl_dir"
    python3 -I - "$tpz" "$tpl.part" <<'PY'
import shutil, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, z.open("templates/linux_release.x86_64") as f, open(sys.argv[2], "wb") as o:
    shutil.copyfileobj(f, o)
PY
    echo "linux_release.x86_64 sha256: $(sha256sum <"$tpl.part" | cut -d' ' -f1)"
    sha_ok "$TEMPLATE_SHA" "$tpl.part" || { rm -f "$tpl.part"; die "the Linux template isn't the pinned file (TEMPLATE_SHA)"; }
    chmod 755 "$tpl.part"
    mv "$tpl.part" "$tpl"
    rm -f "$tpz"   # 1.3 GB: only the Linux release template is needed
fi

# --- 2. Bridge (wsl_build.sh copies this checkout to $dst and builds there) ---
bash "$src/tools/build/wsl_build.sh" fp3d-cdda
so_built="$dst/client/bin/fp3d_cdda.linux.x86_64.so"
[ -f "$so_built" ] || die "no bridge at $so_built"

# --- 3. Export the client ---
work="$dst/tools/out/appimage"   # kept between runs for Godot's import cache; never copied back
cl="$work/client"
mkdir -p "$work"
rsync -a --delete --exclude=/.godot/ --exclude='/bin/*.so' "$dst/client/" "$cl/"
objcopy --strip-debug "$so_built" "$cl/bin/fp3d_cdda.linux.x86_64.so"
exports="$(nm -D --defined-only --format=posix "$cl/bin/fp3d_cdda.linux.x86_64.so" | awk '$2 !~ /^[Aa]$/ { sub(/@.*/, "", $1); print $1 }' | sort -u)"
[ "$exports" = "fp3d_cdda_init" ] || die "the bridge exports more than fp3d_cdda_init: $exports"
objdump -p "$cl/bin/fp3d_cdda.linux.x86_64.so" | grep 'RPATH *\$ORIGIN/libs$' >/dev/null || die "the bridge has no RPATH \$ORIGIN/libs"

rm -rf "$work/AppDir"
app="$work/AppDir/usr/lib/cdda-3d"
mkdir -p "$app"
"$godot" --headless --path "$cl" --import >"$work/import.log" 2>&1 || { tail -30 "$work/import.log"; die "import failed"; }
"$godot" --headless --path "$cl" --export-release Linux "$app/cdda-3d.x86_64" >"$work/export.log" 2>&1 \
    || { tail -30 "$work/export.log"; die "export failed"; }
for f in cdda-3d.x86_64 cdda-3d.pck fp3d_cdda.linux.x86_64.so; do
    [ -f "$app/$f" ] || { tail -30 "$work/export.log"; die "the export has no $f"; }
done
cmp -s "$app/fp3d_cdda.linux.x86_64.so" "$cl/bin/fp3d_cdda.linux.x86_64.so" || die "the exported bridge isn't the one just built"
cmp -s "$app/cdda-3d.x86_64" "$tpl" || die "the exported executable isn't Godot's release template"

# --- 4. Game data, repo files the client reads, licences ---
mkdir -p "$app/cdda" "$app/assets" "$app/contracts"
rsync -a --exclude=/data/cache/ "$dst/cdda/data" "$dst/cdda/gfx" "$app/cdda/"
cp "$dst/cdda/LICENSE.txt" "$app/cdda/"
rsync -a "$dst/assets/registry" "$app/assets/"
rsync -a "$dst/contracts/mock" "$app/contracts/"

# The bridge's libraries, and theirs, except what every desktop Linux has and must stay the system's own:
# glibc, the C++ runtime, compression and font libraries, and the X11/Wayland/GL/audio stack, which Godot and
# the GPU driver load too (the bridge loads first: a bundled copy would replace the system's for them).
system_lib() {
    case "$1" in
        ld-linux*|libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|libutil.so.*|libmvec.so.*) ;;
        libstdc++.so.*|libgcc_s.so.*|libz.so.*|libzstd.so.*|liblzma.so.*|libbz2.so.*|libbrotli*|libpng16.so.*) ;;
        libfreetype.so.*|libharfbuzz.so.*|libfontconfig.so.*|libexpat.so.*|libglib-2.0.so.*|libgobject-2.0.so.*) ;;
        libgio-2.0.so.*|libgmodule-2.0.so.*|libffi.so.*|libpcre2*|libdbus-1.so.*|libsystemd.so.*|libudev.so.*) ;;
        libX11.so.*|libX11-xcb.so.*|libxcb*|libXext.so.*|libXcursor.so.*|libXi.so.*|libXfixes.so.*|libXrandr.so.*) ;;
        libXrender.so.*|libXinerama.so.*|libXau.so.*|libXdmcp.so.*|libwayland-*|libxkbcommon*) ;;
        libGL*|libEGL*|libOpenGL*|libgbm.so.*|libdrm.so.*|libvulkan.so.*) ;;
        libasound.so.*|libpulse*|libjack*|libpipewire*|libsndfile*) ;;
        *) return 1 ;;
    esac
}
libs="$app/libs"
debs="$work/debian"
rm -rf "$debs"
mkdir -p "$libs" "$debs"
pkgs=""
queue=($(objdump -p "$app/fp3d_cdda.linux.x86_64.so" | awk '/NEEDED/ { print $2 }'))
declare -A seen=()
while [ ${#queue[@]} -gt 0 ]; do
    n="${queue[0]}"
    queue=("${queue[@]:1}")
    [ -z "${seen[$n]:-}" ] || continue
    seen[$n]=1
    system_lib "$n" && continue
    p="$(ldconfig -p | awk -v n="$n" '$1 == n && /x86-64/ && !f { print $NF; f = 1 }')"
    [ -n "$p" ] || die "can't find $n"
    real="$(readlink -f "$p")"
    cp "$real" "$libs/$n"
    owner="$(dpkg-query -S "$real" 2>/dev/null || dpkg-query -S "${real#/usr}" 2>/dev/null || true)"
    pkg="${owner%%:*}"
    [ -n "$pkg" ] || die "no package owns $real"
    copyright="/usr/share/doc/$pkg/copyright"
    [ -f "$copyright" ] || die "no copyright file for $pkg"
    cp "$copyright" "$debs/$pkg.copyright"
    pkgs+="  $n: $pkg $(dpkg-query -W -f='${Version}' "$pkg")"$'\n'
    queue+=($(objdump -p "$real" | awk '/NEEDED/ { print $2 }'))
done
[ -f "$libs/libSDL2-2.0.so.0" ] || die "SDL2 wasn't bundled"

"$godot" --headless --path "$cl" --script "$dst/tools/release/godot_licenses.gd" -- "$work/godot_licenses.txt" \
    >"$work/licenses.log" 2>&1 || { tail -20 "$work/licenses.log"; die "Godot's notices failed"; }
(cd "$dst" && python3 -I tools/release/third_party_licenses.py --appimage "$work/godot_licenses.txt" "$debs" \
    "$work/THIRD_PARTY_LICENSES.txt")
doc="$work/AppDir/usr/share/doc/cdda-3d"
mkdir -p "$doc"
cp "$dst/LICENSE.md" "$work/THIRD_PARTY_LICENSES.txt" "$doc/"
proj="$(git -c safe.directory='*' -C "$src" rev-parse HEAD)"
code="$(git -c safe.directory='*' -C "$src/cdda" rev-parse HEAD)"
cat >"$doc/BUILD_INFO.txt" <<EOF
CDDA-3D AppImage, built $(date -u +%Y-%m-%d) on $(. /etc/os-release && echo "$PRETTY_NAME")
CDDA-Proj $proj, CDDA-3D-code (cdda/) $code
Godot $godot_version, Linux release template sha256 $TEMPLATE_SHA
AppImage type2-runtime 20251108, sha256 $RUNTIME_SHA
Bundled libraries (Ubuntu packages):
$pkgs
EOF

install -m 755 "$dst/tools/build/appimage/AppRun.sh" "$work/AppDir/AppRun"
cp "$dst/tools/build/appimage/cdda-3d.desktop" "$work/AppDir/"
cp "$dst/cdda/data/xdg/org.cataclysmdda.CataclysmDDA.svg" "$work/AppDir/cdda-3d.svg"
ln -s cdda-3d.svg "$work/AppDir/.DirIcon"

# Nothing from this machine's paths may ship (CDDA's source paths are mapped out at compile time).
if grep -rlaF -e "$HOME" -e "$src" "$work/AppDir" >"$work/leaks.txt"; then
    cat "$work/leaks.txt"
    die "files above contain this machine's paths"
fi

# --- 5. Pack: the runtime, then the squashfs image ---
rm -f "$work/app.squashfs"
mksquashfs "$work/AppDir" "$work/app.squashfs" -root-owned -noappend -no-xattrs -comp zstd -Xcompression-level 19 \
    -b 1M -no-progress >/dev/null
out="$src/tools/out/appimage"
mkdir -p "$out"
cat "$runtime" "$work/app.squashfs" >"$out/CDDA-3D-x86_64.AppImage.part"
chmod 755 "$out/CDDA-3D-x86_64.AppImage.part"
mv "$out/CDDA-3D-x86_64.AppImage.part" "$out/CDDA-3D-x86_64.AppImage"
cp "$work/THIRD_PARTY_LICENSES.txt" "$out/"
(cd "$out" && sha256sum CDDA-3D-x86_64.AppImage >CDDA-3D-x86_64.AppImage.sha256)
ls -l "$out"
cat "$out/CDDA-3D-x86_64.AppImage.sha256"
