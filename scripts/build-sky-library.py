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
# mood: (OpenStill category, how many). Picks prefer Poly Haven's "Pure Sky" versions, which have no ground.
MOODS = {
    'blue': ('Blue Sky', 5),
    'clouds': ('Clouds', 8),
    'sunset': ('Sunset & Sunrise', 8),
    'dramatic': ('Dramatic', 5),
    'overcast': ('Overcast', 3),
    'night': ('Night', 4),
}
USER_AGENT = {'User-Agent': 'OpenStill sky library builder (https://github.com/haon-v2/OpenStill)'}


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=USER_AGENT), timeout=120) as r:
        return r.read()


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(np.maximum(c, 0), 1 / 2.4) - 0.055)


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


def mood_of(key, info):
    """Each sky belongs to one mood, so no sky appears twice."""
    tags = set(t.lower() for t in info.get('tags', []) + info.get('categories', []))
    if tags & {'night', 'moon', 'stars', 'moonlit', 'milky way'} or 'night' in key: return 'night'
    if tags & {'sunrise-sunset', 'sunset', 'sunrise', 'golden hour', 'dusk', 'dawn'}: return 'sunset'
    if tags & {'overcast', 'stormy', 'storm', 'rain'}: return 'overcast'
    if tags & {'partly cloudy', 'cloudy', 'clouds'}: return 'clouds'
    if tags & {'clear', 'sunny', 'blue sky'}: return 'blue'
    return None


def choose(mood):
    category, count = MOODS[mood]
    assets = json.loads(fetch(f'{API}/assets?t=hdris'))
    source_mood = 'overcast' if mood == 'dramatic' else mood
    pool = []
    for key, info in assets.items():
        pure = key.endswith('_puresky')
        if mood != 'night' and not pure: continue
        if mood_of(key, info) != source_mood: continue
        pool.append((key, info))
    pool.sort(key=lambda kv: -kv[1].get('download_count', 0))
    # Overcast keeps the most popular few; Dramatic grades the next ones into storms.
    if mood == 'overcast': pool = pool[:count]
    if mood == 'dramatic': pool = pool[MOODS['overcast'][1]:]
    return category, pool[:count]


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
        # The frame's lower edge sits just above the horizon; night panoramas keep their ground, so look higher.
        pitch = math.radians(vfov / 2 + (14 if mood == 'night' else 2))
        # Face the most interesting part of the sky: the brightest region for sunsets and night, else the most varied.
        ph, pw = pano.shape[:2]
        band = srgb_to_linear(pano[ph // 6: ph // 2]).mean(-1)
        cols = band.mean(0) if mood in ('sunset', 'night') else band.std(0)
        window = max(1, pw // 8)
        smooth = np.convolve(np.concatenate([cols, cols[:window]]), np.ones(window) / window, 'valid')[:pw]
        yaw = (np.argmax(smooth) / pw - 0.5) * 2 * math.pi
        plate = np.clip(project(pano, yaw, pitch), 0, 1)
        name = info.get('name', key).replace(' (Pure Sky)', '')
        if mood == 'night':
            # Panoramas are exposed for display, which makes night look like dusk: bring it down to night, keep the stars.
            lin = srgb_to_linear(plate); k = 0.025 / max(float((lin @ np.array([0.2126, 0.7152, 0.0722])).mean()), 1e-4)
            stars = np.clip((lin - 0.35) / 0.65, 0, 1) * 0.55
            plate = linear_to_srgb(np.clip(lin * k + stars, 0, 1))
        if mood == 'dramatic':
            # A storm graded from an overcast sky: darker, deeper contrast, a cold cast.
            lin = srgb_to_linear(plate) * 0.32
            lum = (lin @ np.array([0.2126, 0.7152, 0.0722]))[..., None]
            lin = np.clip(lum + (lin - lum) * 0.7, 0, 1) * np.array([0.92, 0.98, 1.1])
            s = linear_to_srgb(np.clip(lin, 0, 1)); plate = np.clip(0.5 + (s - 0.5) * 1.35, 0, 1)
            name = 'Storm · ' + name
        mean = srgb_to_linear(plate).reshape(-1, 3).mean(0)
        bottom = srgb_to_linear(plate[-HEIGHT // 8:]).reshape(-1, 3).mean(0)
        Image.fromarray((plate * 255 + 0.5).astype('uint8')).save(out / f'{mood}-{key}.jpg', quality=84, optimize=True, progressive=True)
        record = dict(id=f'polyhaven-{mood}-{key}', name=name, category=category, file=f'{mood}-{key}.jpg', creator=', '.join(info.get('authors', {}).keys()) or 'Poly Haven',
                      source=f'https://polyhaven.com/a/{key}', license='CC0-1.0', mean=[round(float(c), 5) for c in mean],
                      horizon=[round(float(c), 5) for c in bottom], tags=sorted(set(info.get('tags', [])))[:8])
        (out / f'{mood}-{key}.json').write_text(json.dumps(record))
        print('built', key, name, round(float(mean.mean()), 3), (out / f'{mood}-{key}.jpg').stat().st_size)


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
