#!/usr/bin/env python3
"""
build.py — WayLume build tool
Assembles src/* → waylume.sh via two-pass placeholder substitution.

Usage:
    ./build.py             # build only
    ./build.py --install   # build + run waylume.sh --install
"""

import argparse
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────────────

ROOT = Path(__file__).parent

SRC = ROOT / "src"
OUTPUT = ROOT / "waylume.sh"

SOURCES = [
    SRC / "sources" / "bing.sh",
    SRC / "sources" / "unsplash.sh",
    SRC / "sources" / "apod.sh",
    SRC / "sources" / "wikimedia.sh",
]

FILES = {
    "main":         SRC / "main.sh",
    "fetcher":      SRC / "fetcher.sh",
    "icon":         SRC / "waylume.svg",
    "i18n_pt":      SRC / "i18n" / "pt.sh",
    "i18n_en":      SRC / "i18n" / "en.sh",
    "lib_gallery":  SRC / "lib" / "gallery.sh",
    "lib_wallpaper": SRC / "lib" / "wallpaper.sh",
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8").rstrip("\n")

def validate():
    missing = [p for p in list(FILES.values()) + SOURCES if not p.exists()]
    if missing:
        for p in missing:
            print(f"❌ Arquivo não encontrado: {p}")
        sys.exit(1)

def check_placeholders(content: str, placeholders: list[str], location: str):
    for ph in placeholders:
        if ph not in content:
            print(f"❌ Placeholder {ph} não encontrado em {location}")
            sys.exit(1)

# ── Build ─────────────────────────────────────────────────────────────────────

def build() -> str:
    main         = read(FILES["main"])
    fetcher      = read(FILES["fetcher"])
    icon         = read(FILES["icon"])
    i18n_pt      = read(FILES["i18n_pt"])
    i18n_en      = read(FILES["i18n_en"])
    lib_gallery  = read(FILES["lib_gallery"])
    lib_wallpaper = read(FILES["lib_wallpaper"])
    sources_content = "\n\n".join(read(p) for p in SOURCES)

    check_placeholders(main,    ["##FETCHER_CONTENT##", "##ICON_CONTENT##", "##I18N_PT##", "##I18N_EN##"], "src/main.sh")
    check_placeholders(fetcher, ["##LIB_GALLERY##", "##LIB_WALLPAPER##", "##SOURCES##"],                   "src/fetcher.sh")

    # Pass 1 — expand lib/source placeholders inside the fetcher skeleton
    fetcher_expanded = (fetcher
        .replace("##LIB_GALLERY##",   lib_gallery)
        .replace("##LIB_WALLPAPER##", lib_wallpaper)
        .replace("##SOURCES##",       sources_content)
    )

    # Pass 2 — embed expanded fetcher + assets into main
    result = (main
        .replace("##FETCHER_CONTENT##", fetcher_expanded)
        .replace("##ICON_CONTENT##",    icon)
        .replace("##I18N_PT##",         i18n_pt)
        .replace("##I18N_EN##",         i18n_en)
    )

    OUTPUT.write_text(result, encoding="utf-8")
    OUTPUT.chmod(OUTPUT.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    lines = result.count("\n")
    print(f"  src/main.sh             : {main.count(chr(10))} linhas")
    print(f"  src/fetcher.sh          : {fetcher.count(chr(10))} linhas (esqueleto)")
    print(f"  src/lib/gallery.sh      : {lib_gallery.count(chr(10))} linhas")
    print(f"  src/lib/wallpaper.sh    : {lib_wallpaper.count(chr(10))} linhas")
    for p in SOURCES:
        print(f"  src/sources/{p.name:<16}: {read(p).count(chr(10))} linhas")
    print(f"  src/waylume.svg         : {icon.count(chr(10))} linhas")
    print(f"  src/i18n/pt.sh          : {i18n_pt.count(chr(10))} linhas")
    print(f"  src/i18n/en.sh          : {i18n_en.count(chr(10))} linhas")
    print(f"  waylume.sh              : {lines} linhas (saída)")

    return result

# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="WayLume build tool")
    parser.add_argument("--install", action="store_true",
                        help="Run ./waylume.sh --install after a successful build")
    args = parser.parse_args()

    validate()
    build()

    # Optional: shellcheck
    if shutil.which("shellcheck"):
        print("🔍 Rodando shellcheck...")
        rc = subprocess.run(["shellcheck", "-S", "warning", str(OUTPUT)]).returncode
        print("  ✅ shellcheck OK" if rc == 0 else "  ⚠️  shellcheck encontrou avisos")

    print("✅ Build concluído: waylume.sh")

    if args.install:
        print()
        subprocess.run([str(OUTPUT), "--install"], check=True)


if __name__ == "__main__":
    main()
