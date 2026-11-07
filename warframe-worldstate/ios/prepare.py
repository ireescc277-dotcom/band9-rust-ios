"""Prepare iOS bundle resources.

The root warframe-worldstate.html is the single source of truth; this script
copies it into the app bundle and decodes the AppIcon (stored as base64 in git
so that the repository stays plain text).

Usage: python3 ios/prepare.py
"""
import base64
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "ios" / "WarframeWorldState" / "Resources"
ICON_DIR = ROOT / "ios" / "WarframeWorldState" / "Assets.xcassets" / "AppIcon.appiconset"


def main():
    RESOURCES.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "warframe-worldstate.html", RESOURCES / "warframe-worldstate.html")
    encoded = (ICON_DIR / "AppIcon.png.base64").read_text(encoding="ascii").strip()
    (ICON_DIR / "AppIcon.png").write_bytes(base64.b64decode(encoded))
    print("bundle resources ready: warframe-worldstate.html + AppIcon.png")


if __name__ == "__main__":
    main()
