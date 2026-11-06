"""Writes THIRD_PARTY_LICENSES.txt for a bridge DLL release (see TASKS.md "Releases").

Run from the repo root: python -I tools/release/third_party_licenses.py <out.txt>
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


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    parts = [("Cataclysm: Dark Days Ahead (CC BY-SA 3.0)", text("cdda/LICENSE.txt")),
             ("CDDA-3D (CC BY-SA 3.0)", text("LICENSE.md")),
             ("godot-cpp (MIT)", text("bridge/godot-cpp/LICENSE.md"))]
    parts += [(name, text(VCPKG / port / "copyright")) for name, port in VCPKG_PORTS]
    parts += [("Dear ImGui (MIT)", text(TP / "imgui/LICENSE.txt")),
              ("Zstandard (BSD)", text(TP / "zstd/LICENSE")),
              ("Pinyin data (Unicode)", text(TP / "pinyin/LICENSE")),
              ("FlatBuffers (Apache License 2.0; modified by the CDDA project)",
               "Copyright 2014 Google Inc. All rights reserved.\n\n" + text("cdda/LICENSE-Apache-Robot-Font.txt"))]
    out = [HEAD] + ["\n%s\n%s\n%s\n\n%s\n" % ("=" * 78, n, "=" * 78, t) for n, t in parts]
    Path(sys.argv[1]).write_text("".join(out), encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
