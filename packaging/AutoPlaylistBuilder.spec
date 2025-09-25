# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller build specification for Spotify Playlist Builder."""

from __future__ import annotations

import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_submodules

if "__file__" in globals():
    SPEC_PATH = Path(__file__).resolve()
else:
    SPEC_PATH = Path(sys.argv[0]).resolve()

PROJECT_ROOT = SPEC_PATH.parent.parent
APP_NAME = "AutoPlaylistBuilder"

# Data files that must ship with the binary (KV layout, default settings).
DATAS = [
    (str(PROJECT_ROOT / "app" / "ui" / "main.kv"), "app/ui"),
    (str(PROJECT_ROOT / "config" / "settings.py"), "config"),
]

# Common Kivy backends that should be bundled so the app runs without debug output.
HIDDENIMPORTS = [
    "kivy.core.window.window_sdl2",
    "kivy.core.text.text_sdl2",
    "kivy.core.image.img_sdl2",
    "kivy.core.audio.audio_sdl2",
    "kivy.core.clipboard.clipboard_sdl2",
]

# Extra dependencies required on Windows to ship the bundled SDL/GLEW stacks.
if sys.platform.startswith("win"):
    HIDDENIMPORTS += [
        "kivy_deps.glew",
        "kivy_deps.sdl2",
        "kivy_deps.angle",
    ]
elif sys.platform == "darwin":
    HIDDENIMPORTS += [
        "kivy_deps.glew",
        "kivy_deps.sdl2",
        "kivy_deps.gstreamer",
    ]

# Collect additional optional modules to prevent missing garden/widget errors.
HIDDENIMPORTS += collect_submodules("kivy.modules")

block_cipher = None


a = Analysis(
    [str(PROJECT_ROOT / "main.py")],
    pathex=[str(PROJECT_ROOT)],
    binaries=[],
    datas=DATAS,
    hiddenimports=HIDDENIMPORTS,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name=APP_NAME,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=sys.platform == "darwin",
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name=APP_NAME,
)
