"""Writes THIRD_PARTY_LICENSES.txt for a bridge DLL release (see TASKS.md "Releases").

Run from the repo root: python -I tools/release/third_party_licenses.py <out.txt>
The AppImage (tools/build/appimage.sh) uses
  python3 -I tools/release/third_party_licenses.py --appimage <godot.txt> <debian_dir> <out.txt>
with Godot's notices (tools/release/godot_licenses.gd) and the Debian copyright files of the bundled libraries
(<debian_dir>/<package>.copyright).
Lists every library linked into the bridge (Windows DLL, Linux .so) with its notice. If the DLL starts linking
something new (check the .lib list in cdda/out/build/fp3d-msvc/fp3d-bridge/fp3d-cdda.vcxproj), add it here.
"""
import sys
from pathlib import Path

VCPKG = Path("D:/vcpkg/installed-cdda/x64-windows-static/share")
TP = Path("cdda/src/third-party")
VCPKG_PORTS = [("SDL2", "sdl2"), ("SDL2_image", "sdl2-image"), ("SDL2_ttf", "sdl2-ttf"), ("FreeType", "freetype"),
               ("libpng", "libpng"), ("zlib", "zlib"), ("bzip2", "bzip2"), ("Brotli", "brotli"),
               ("libjpeg-turbo", "libjpeg-turbo")]
HEAD = """Licences for the CDDA-3D bridge (fp3d_cdda.windows.x86_64.dll, fp3d_cdda.linux.x86_64.so)

Both contain Cataclysm: Dark Days Ahead 0.I-1 with the CDDA-3D changes (CC BY-SA 3.0), godot-cpp, Dear ImGui,
Zstandard, FlatBuffers and CDDA's pinyin data. The Windows DLL also links SDL2, SDL2_image, SDL2_ttf,
FreeType, libpng, zlib, bzip2, Brotli and libjpeg-turbo statically. The Linux library loads SDL2, SDL2_image,
SDL2_ttf, FreeType and zlib from the system instead, and contains GCC's C++ runtime (GPLv3 with the GCC
Runtime Library Exception). The notices follow.
Portions of this software are copyright (c) The FreeType Project (www.freetype.org). All rights reserved.
This software is based in part on the work of the Independent JPEG Group.
"""


def text(p):
    return Path(p).read_text(encoding="utf-8", errors="replace").strip()


APPIMAGE_HEAD = """Licences for the CDDA-3D AppImage (CDDA-3D-x86_64.AppImage)

It contains:
- the CDDA-3D client (CC BY-SA 3.0), exported with Godot Engine 4.7.2 (MIT; its third-party parts are
  listed in the Godot section below);
- the bridge fp3d_cdda.linux.x86_64.so: Cataclysm: Dark Days Ahead 0.I-1 with the CDDA-3D changes
  (CC BY-SA 3.0), godot-cpp, Dear ImGui, Zstandard, FlatBuffers, CDDA's pinyin data and GCC's C++ runtime
  (GPLv3 with the GCC Runtime Library Exception);
- CDDA's game data and tilesets (CC BY-SA 3.0; some tilesets carry their own notes in gfx/);
- shared libraries from Ubuntu 24.04 that the bridge loads (SDL2, SDL2_image, SDL2_ttf and what they
  need), each with its Debian copyright file below; their sources are in Ubuntu's archive;
- the AppImage type2-runtime, release 20251108 (MIT), the launcher at the start of the file. It is
  statically linked with libfuse 3.15.0 (LGPL-2.1, patched), squashfuse 0.5.2 (BSD-2-Clause), Zstandard
  (BSD), zlib, mimalloc (MIT) and musl libc (MIT). Source and build scripts:
  https://github.com/AppImage/type2-runtime/tree/20251108
Portions of this software are copyright (c) The FreeType Project (www.freetype.org). All rights reserved.
This software is based in part on the work of the Independent JPEG Group.
"""


def common_parts():
    return [("Cataclysm: Dark Days Ahead (CC BY-SA 3.0)", text("cdda/LICENSE.txt")),
            ("CDDA-3D (CC BY-SA 3.0)", text("LICENSE.md")),
            ("godot-cpp (MIT)", text("bridge/godot-cpp/LICENSE.md"))]


def bridge_parts():
    return [("Dear ImGui (MIT)", text(TP / "imgui/LICENSE.txt")),
            ("Zstandard (BSD)", text(TP / "zstd/LICENSE")),
            ("Pinyin data (Unicode)", text(TP / "pinyin/LICENSE")),
            ("FlatBuffers (Apache License 2.0; modified by the CDDA project)",
             "Copyright 2014 Google Inc. All rights reserved.\n\n" + text("cdda/LICENSE-Apache-Robot-Font.txt"))]


def write(path, head, parts):
    out = [head] + ["\n%s\n%s\n%s\n\n%s\n" % ("=" * 78, n, "=" * 78, t) for n, t in parts]
    Path(path).write_text("".join(out), encoding="utf-8", newline="\n")


def appimage(godot_txt, debian_dir, out_path):
    debs = sorted(Path(debian_dir).glob("*.copyright"))
    if not debs:
        sys.exit("no Debian copyright files in " + debian_dir)
    parts = common_parts() + bridge_parts()
    parts += [("Godot Engine (MIT) and its third-party parts", text(godot_txt))]
    parts += [("%s (Ubuntu 24.04 package)" % d.name[:-len(".copyright")], text(d)) for d in debs]
    parts += [("AppImage type2-runtime (MIT)", text("tools/release/appimage_runtime_LICENSE.txt")),
              ("libfuse 3 in the AppImage runtime (GNU LGPL 2.1)", text("/usr/share/common-licenses/LGPL-2.1"))]
    write(out_path, APPIMAGE_HEAD, parts)


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--appimage":
        appimage(*sys.argv[2:])
        return
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    parts = common_parts()
    parts += [(name, text(VCPKG / port / "copyright")) for name, port in VCPKG_PORTS]
    parts += bridge_parts()
    write(sys.argv[1], HEAD, parts)


if __name__ == "__main__":
    main()
