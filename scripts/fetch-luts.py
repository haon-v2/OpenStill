#!/usr/bin/env python3
"""Refresh the pinned CC0 LUT assets; never used at app runtime."""
import hashlib, json, re, urllib.request, urllib.parse
from pathlib import Path

REVISION = '9004af74b02c67e507190e9950b5fc690fb0a900'
ROOT = Path(__file__).resolve().parent.parent
LOOKS = [
 ('vintage_400_film','Vintage 400 Film','Portraits',1660,'M.Fahri','film_stock_&_vintage','Warm film color with a nostalgic portrait mood.'),
 ('romantic_cinema','Romantic Cinema','Portraits',169,'SHAAM WORX','cinematic_&_blockbuster','A deeper, warm cinematic treatment for expressive portraits.'),
 ('golden_years_film','Golden Years Film','Portraits',1015,'jackofalltrades','film_stock_&_vintage','Golden vintage color for sunlit, story-driven portraits.'),
 ('city_neon_cinema','City Neon Cinema','Cityscape & Street',2426,'Gina','cinematic_&_blockbuster','Teal cinematic color for neon streets and city light.'),
 ('city_night_film','City Night Film','Cityscape & Street',148,'SHAAM WORX','dark_&_moody','Cool, low-key film color for urban evenings.'),
 ('night_glow','Night Glow','Cityscape & Street',357,'maisayantan','dark_&_moody','Cool shadows and a dramatic night-time mood.'),
 ('cool_cinema','Cool Cinema','Automotive',218,'Andy','cinematic_&_blockbuster','Cool cinematic color for metal, reflections, and dramatic car scenes.'),
 ('teal_punch','Teal Punch','Automotive',285,'tjtop','teal_&_orange_vibes','A bold teal treatment for stylized automotive photography.'),
 ('noir_era','Noir Era','Automotive',1053,'jackofalltrades','dark_&_moody','Moody brown-toned cinema color for low-key car portraits.'),
 ('emerald_film','Emerald Film','Nature & Landscape',276,'pushpak dsilva','film_stock_&_vintage','Green film color for a cinematic landscape mood.'),
 ('woodland_drama','Woodland Drama','Nature & Landscape',166,'SHAAM WORX','dark_&_moody','Deep green drama for woodland and shaded foliage.'),
 ('tropical_teal','Tropical Teal','Nature & Landscape',217,'Andy','teal_&_orange_vibes','Warm and teal color for coastlines and travel landscapes.'),
]

def get(url):
    return urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'OpenStill-LUT-Provenance/1.0'}),timeout=45).read()

entries=[]
for slug,name,category,source_id,creator,folder,description in LOOKS:
    source=f'https://freshluts.com/luts/{source_id}'
    html=get(source).decode()
    plain=re.sub(r'\s+',' ',re.sub(r'<[^>]+>',' ',html))
    for label in ['CC0 Creative Commons','Free for commercial use','No attribution required']:
        if label not in plain: raise RuntimeError(f'License not verified: {source}')
    path=f'src/colors/{folder}/{slug}.cube'
    download=f'https://raw.githubusercontent.com/OpenShot/openshot-qt/{REVISION}/'+urllib.parse.quote(path,safe='/')
    data=get(download)
    (ROOT/'Resources/LUTs'/f'{slug}.cube').write_bytes(data)
    entries.append(dict(id='freshluts-'+str(source_id),name=name,category=category,filename=slug+'.cube',creator=creator,source=source,license='CC0-1.0',checksum=hashlib.sha256(data).hexdigest(),description=description,download=download,inputSpace='Rec.709 creative',verified='2026-09-24'))
    print(name,len(data),'CC0 verified',flush=True)
(ROOT/'Resources/LUTs/catalog.json').write_text(json.dumps(dict(version=1,revision=REVISION,entries=entries),indent=2)+'\n')
(ROOT/'Resources/Licenses/LUTs/PROVENANCE.md').write_text('# Bundled LUT provenance\n\nAll 12 entries in Resources/LUTs/catalog.json were retrieved from OpenShot revision '+REVISION+'. Each linked FreshLUTs creator page displayed CC0 Creative Commons, Free for commercial use, and No attribution required on 2026-09-24. The manifest records the original creator page, pinned download URL, SHA-256, and creator credit for every file.\n\nOpenShot provenance: https://github.com/OpenShot/openshot-qt/blob/'+REVISION+'/src/colors/AUTHORS.md\n\nOnly CC0 data files are incorporated; no OpenShot application code is included. Names follow OpenShot; photography categories and descriptions are OpenStill recommendations. They do not imply endorsement or exclusive suitability.\n\nLicense: https://creativecommons.org/publicdomain/zero/1.0/\n')
(ROOT/'Resources/Licenses/LUTs/CC0-1.0.txt').write_bytes(get('https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt'))
