#!/usr/bin/env python3
"""Sets CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist without reformatting the file."""
import re, sys

version, build = sys.argv[1], sys.argv[2]
path = "Resources/Info.plist"
text = open(path).read()
for key, value in (("CFBundleShortVersionString", version), ("CFBundleVersion", build)):
    text, count = re.subn(rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{value}\g<2>", text)
    if count != 1:
        sys.exit(f"Expected one {key} in {path}, found {count}")
open(path, "w").write(text)
print(f"Info.plist: {version} (build {build})")
