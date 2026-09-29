#!/usr/bin/env python3
"""Builds OpenStill's bundled replacement skies from Poly Haven HDRIs (CC0); never used at app runtime.

Each chosen sky panorama is projected to a 16:9 view looking up at the sky (the horizon sits just below the frame),
saved as a JPEG plate, and described in Resources/Skies/skies.json with its credit and its average color, which the
app uses to relight the rest of the photo to match the new sky.

  scripts/build-sky-library.py --mood sunset --out DIR     # download and project one mood's skies
  scripts/build-sky-library.py --catalog DIR                # write skies.json from the plates' .json sidecars

Poly Haven (https://polyhaven.com) publishes every asset under CC0; each sky's page and authors are recorded.
"""
import argparse, io, json, math, pathlib, sys, urllib.request
import numpy as np
from PIL import Image

API = 'https://api.polyhaven.com'
WIDTH, HEIGHT, HFOV = 2400, 1350, 96.0
# mood: (OpenStill category, Poly Haven tags/categories that pick it, how many)
MOODS = {
    'blue': ('Blue Sky', ['clear', 'sunny', 'partly cloudy'], 6),
    'clouds': ('Clouds', ['partly cloudy', 'cloudy'], 6),
    'sunset': ('Sunset & Sunrise', ['sunrise-sunset', 'sunset', 'sunrise', 'golden hour', 'dusk', 'dawn'], 7),
    'dramatic': ('Dramatic', ['overcast', 'dramatic', 'stormy', 'storm'], 5),
    'overcast': ('Overcast', ['overcast', 'cloudy'], 3),
    'night': ('Night', ['night', 'moon', 'stars', 'moonlit'], 5),
}
USER_AGENT = {'User-Agent': 'OpenStill sky library builder (https://github.com/haon-v2/OpenStill)'}


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=USER_AGENT), timeout=120) as r:
        return r.read()


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def project(pano, yaw, pitch):
    """A pinhole view of an equirectangular panorama (width = 2 × height)."""
    ph, pw = pano.shape[:2]
    f = (WIDTH / 2) / math.tan(math.radians(HFOV / 2))
    xs, ys = np.meshgrid(np.arange(WIDTH) - WIDTH / 2 + 0.5, np.arange(HEIGHT) - HEIGHT / 2 + 0.5)
    d = np.stack([xs, -ys, np.full_like(xs, f)], -1)
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    cp, sp = math.cos(pitch), math.sin(pitch)
    x, y, z = d[..., 0], d[..., 1] * cp + d[..., 2] * sp, -d[..., 1] * sp + d[..., 2] * cp
    lon = np.arctan2(x, z) + yaw
    lat = np.arcsin(np.clip(y, -1, 1))
    u = ((lon / (2 * math.pi) + 0.5) % 1) * (pw - 1)
    v = (0.5 - lat / math.pi) * (ph - 1)
    u0, v0 = np.floor(u).astype(int), np.clip(np.floor(v).astype(int), 0, ph - 2)
    fu, fv = (u - u0)[..., None], (v - v0)[..., None]
    u1 = (u0 + 1) % pw
    return (pano[v0, u0] * (1 - fu) * (1 - fv) + pano[v0, u1] * fu * (1 - fv) + pano[v0 + 1, u0] * (1 - fu) * fv + pano[v0 + 1, u1] * fu * fv)


def choose(mood):
    category, wanted, count = MOODS[mood]
    assets = json.loads(fetch(f'{API}/assets?t=hdris'))
    picked = []
    for key, info in sorted(assets.items(), key=lambda kv: -kv[1].get('download_count', 0)):
        tags = set(t.lower() for t in info.get('tags', []) + info.get('categories', []))
        if 'skies' not in tags and 'sky' not in tags and mood != 'night': continue
        if not tags.intersection(wanted): continue
        if mood == 'blue' and tags.intersection({'sunrise-sunset', 'night', 'overcast'}): continue
        if mood == 'clouds' and tags.intersection({'sunrise-sunset', 'night'}): continue
        if mood in ('dramatic', 'overcast') and tags.intersection({'night'}): continue
        picked.append((key, info))
        if len(picked) >= count: break
    return category, picked


def build(mood, out):
    out.mkdir(parents=True, exist_ok=True)
    category, picked = choose(mood)
    for key, info in picked:
        files = json.loads(fetch(f'{API}/files/{key}'))
        url = files.get('tonemapped', {}).get('url')
        if not url: print('skip (no tonemapped JPG)', key); continue
        pano = np.asarray(Image.open(io.BytesIO(fetch(url))).convert('RGB'), dtype=np.float32) / 255
        if pano.shape[1] > 8192:
            pano = np.asarray(Image.fromarray((pano * 255).astype('uint8')).resize((8192, 4096), Image.Resampling.LANCZOS), dtype=np.float32) / 255
        vfov = 2 * math.degrees(math.atan(math.tan(math.radians(HFOV / 2)) * HEIGHT / WIDTH))
        pitch = math.radians(vfov / 2 + 1.5)
        # Face the most interesting part of the sky: the brightest region for sunsets and night, else the most varied.
        ph, pw = pano.shape[:2]
        band = srgb_to_linear(pano[ph // 6: ph // 2]).mean(-1)
        cols = band.mean(0) if mood in ('sunset', 'night') else band.std(0)
        window = max(1, pw // 8)
        smooth = np.convolve(np.concatenate([cols, cols[:window]]), np.ones(window) / window, 'valid')[:pw]
        yaw = (np.argmax(smooth) / pw - 0.5) * 2 * math.pi
        plate = np.clip(project(pano, yaw, pitch), 0, 1)
        mean = srgb_to_linear(plate).reshape(-1, 3).mean(0)
        bottom = srgb_to_linear(plate[-HEIGHT // 8:]).reshape(-1, 3).mean(0)
        name = info.get('name', key)
        Image.fromarray((plate * 255 + 0.5).astype('uint8')).save(out / f'{key}.jpg', quality=84, optimize=True, progressive=True)
        record = dict(id='polyhaven-' + key, name=name, category=category, file=f'{key}.jpg', creator=', '.join(info.get('authors', {}).keys()) or 'Poly Haven',
                      source=f'https://polyhaven.com/a/{key}', license='CC0-1.0', mean=[round(float(c), 5) for c in mean],
                      horizon=[round(float(c), 5) for c in bottom], tags=sorted(set(info.get('tags', [])))[:8])
        (out / f'{key}.json').write_text(json.dumps(record))
        print('built', key, name, round(float(mean.mean()), 3), (out / f'{key}.jpg').stat().st_size)


def catalog(folder):
    entries = [json.loads(p.read_text()) for p in sorted(folder.glob('*.json')) if p.name != 'skies.json']
    order = [m[0] for m in MOODS.values()]
    seen, unique = set(), []
    for e in sorted(entries, key=lambda e: (order.index(e['category']), e['name'])):
        if e['id'] in seen: continue
        seen.add(e['id']); unique.append(e)
    (folder / 'skies.json').write_text(json.dumps(dict(version=1, skies=unique), indent=1, ensure_ascii=False) + '\n')
    for p in folder.glob('*.json'):
        if p.name != 'skies.json': p.unlink()
    print(len(unique), 'skies')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('--mood', choices=list(MOODS)); ap.add_argument('--out', type=pathlib.Path); ap.add_argument('--catalog', type=pathlib.Path)
    a = ap.parse_args()
    if a.catalog: catalog(a.catalog)
    elif a.mood and a.out: build(a.mood, a.out)
    else: sys.exit(ap.format_usage())
