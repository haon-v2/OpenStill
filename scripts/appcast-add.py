#!/usr/bin/env python3
"""Adds one release to appcast.xml. Used by scripts/release.sh and the Release workflow.

Environment: VERSION, BUILD, MINIMUM (macOS), SIGNATURE (sign_update output: sparkle:edSignature="…" length="…"),
ARCHS (lipo -archs output), and optionally NOTES: one change per line, shown as "What's new" in the
update window before the user installs. Refuses a build number that is already listed.
"""
import email.utils, html, os, re, sys

version, build = os.environ["VERSION"], os.environ["BUILD"]
signature = os.environ["SIGNATURE"].strip()
if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', signature):
    sys.exit(f"Unexpected sign_update output: {signature!r}")
text = open("appcast.xml").read()
if f"<sparkle:version>{build}</sparkle:version>" in text:
    sys.exit(f"appcast.xml already lists build {build}.")
base = f"https://github.com/haon-v2/OpenStill/releases/download/v{version}"
# An Apple silicon-only build must not be offered to Intel Macs.
hardware = "" if "x86_64" in os.environ["ARCHS"].split() else "\n            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
notes = [line.strip(" -*\t") for line in os.environ.get("NOTES", "").splitlines()]
notes = [line for line in notes if line]
description = ""
if notes:
    points = "".join(f"<li>{html.escape(line)}</li>" for line in notes)
    description = f"\n            <description><![CDATA[<h3>What’s new in {version}</h3><ul>{points}</ul>]]></description>"
item = f"""        <item>
            <title>OpenStill {version}</title>{description}
            <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{os.environ["MINIMUM"]}</sparkle:minimumSystemVersion>{hardware}
            <sparkle:fullReleaseNotesLink>https://github.com/haon-v2/OpenStill/releases/tag/v{version}</sparkle:fullReleaseNotesLink>
            <enclosure url="{base}/OpenStill-{version}.zip" {signature} type="application/octet-stream"/>
        </item>
"""
marker = "    </channel>"
if marker not in text:
    sys.exit("appcast.xml has no </channel>")
open("appcast.xml", "w").write(text.replace(marker, item + marker, 1))
print(f"Added OpenStill {version} (build {build}) to appcast.xml.")
