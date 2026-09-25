#!/usr/bin/env python3
"""Reproduce the bundled Lensfun schema-1 profile adaptation, without network access."""
import hashlib
import pathlib
import tarfile
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parents[1]
archive = root / 'Resources/Licenses/NativeSources/lensfun-profiles-bbd4332.tar.gz'
expected = 'fd0b47fbd71945da0ca89d62a3dacf9a8573c2a718301ec093dfab3b6d9a5331'
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise RuntimeError('Pinned Lensfun database archive checksum mismatch')
output = root / 'Resources/LensProfiles'
count = 0
with tarfile.open(archive) as source:
    for member in source:
        parts = pathlib.PurePosixPath(member.name).parts
        if not member.isfile() or len(parts) != 4 or parts[1:3] != ('data', 'db') or not parts[-1].endswith('.xml'):
            continue
        tree = ET.fromstring(source.extractfile(member).read())
        tree.set('version', '1')
        for calibration in tree.findall('.//calibration'):
            for item in list(calibration):
                if item.get('model') == 'acm':
                    calibration.remove(item)
                elif item.tag == 'distortion' and 'real-focal' in item.attrib:
                    ET.SubElement(calibration, 'real-focal-length', {'focal': item.get('focal'), 'real-focal': item.attrib.pop('real-focal')})
        ET.indent(tree, space='  ')
        ET.ElementTree(tree).write(output / parts[-1], encoding='utf-8', xml_declaration=True)
        count += 1
if count == 0:
    raise RuntimeError('No profile XML files found in the pinned archive')
print(f'Regenerated {count} Lensfun profile files')
