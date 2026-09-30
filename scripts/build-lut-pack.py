#!/usr/bin/env python3
"""Builds OpenStill's bundled look library; never used at app runtime.

Sources, all free to use and redistribute:
  1. FreshLUTs community looks (CC0-1.0), as collected by OpenShot at a pinned revision.
  2. RawTherapee Film Simulation Collection 2015-09-20 (CC BY-SA 4.0), Hald CLUT PNGs.
  3. OpenStill Originals (CC0-1.0), generated here from Resources/LUTs/originals.json.

Writes Resources/LUTs/Library.lutpack (one compressed 3D table per look), Resources/LUTs/catalog.json (version 2)
and Resources/Licenses/LUTs/PROVENANCE.md.

  scripts/build-lut-pack.py --openshot DIR --film "DIR/HaldCLUT/Film Simulation"

DIR for --openshot holds the 50 .cube files listed in OpenShot's src/colors/AUTHORS.md (download them from
https://raw.githubusercontent.com/OpenShot/openshot-qt/<REVISION>/src/colors/<folder>/<file>); --film is the
"Film Simulation" folder of the RawTherapee collection (for example from github.com/cedeber/hald-clut).

Pack format: the file starts with b"OSLUTPK1"; each look is a raw-deflate stream of three planes (R, G, B), each
dimension³ little-endian UInt16 values (value / (2^bits − 1); bits is 16 unless the catalog says otherwise; the film
simulations use 8, the precision of their source images), red index fastest, stored as differences from the previous
value (mod 2¹⁶). catalog.json gives each look's offset, length, dimension and the SHA-256 of the decoded planes.
"""
import argparse, hashlib, json, re, sys, zlib
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OPENSHOT_REVISION = '9004af74b02c67e507190e9950b5fc690fb0a900'
SIZE = 33
FILM_CREDIT = 'RawTherapee Film Simulation Collection · Pat David, Pavlov Dmitry, Michael Ezra'
FILM_SOURCE = 'https://rawpedia.rawtherapee.com/Film_Simulation'
ORIGINALS_CREDIT = 'OpenStill'

# ---------------------------------------------------------------------------------------------------------------
# FreshLUTs (CC0). The first 12 keep the ids, names and files OpenStill has shipped since 0.0.1.
FRESHLUTS = {  # file: (freshluts id, OpenStill name, category, creator, description)
 'vintage_400_film.cube': (1660,'Vintage 400 Film','Vintage & Faded','M.Fahri','Warm film color with a nostalgic portrait mood.'),
 'romantic_cinema.cube': (169,'Romantic Cinema','Cinematic','SHAAM WORX','A deeper, warm cinematic treatment for expressive portraits.'),
 'golden_years_film.cube': (1015,'Golden Years Film','Vintage & Faded','jackofalltrades','Golden vintage color for sunlit, story-driven portraits.'),
 'city_neon_cinema.cube': (2426,'City Neon Cinema','City & Night','Gina','Teal cinematic color for neon streets and city light.'),
 'city_night_film.cube': (148,'City Night Film','City & Night','SHAAM WORX','Cool, low-key film color for urban evenings.'),
 'night_glow.cube': (357,'Night Glow','City & Night','maisayantan','Cool shadows and a dramatic night-time mood.'),
 'cool_cinema.cube': (218,'Cool Cinema','Cinematic','Andy','Cool cinematic color for metal, reflections, and dramatic scenes.'),
 'teal_punch.cube': (285,'Teal Punch','Cinematic','tjtop','A bold teal treatment for stylized photography.'),
 'noir_era.cube': (1053,'Noir Era','Moody','jackofalltrades','Moody brown-toned cinema color for low-key scenes.'),
 'emerald_film.cube': (276,'Emerald Film','Landscape & Nature','pushpak dsilva','Green film color for a cinematic landscape mood.'),
 'woodland_drama.cube': (166,'Woodland Drama','Landscape & Nature','SHAAM WORX','Deep green drama for woodland and shaded foliage.'),
 'tropical_teal.cube': (217,'Tropical Teal','Landscape & Nature','Andy','Warm and teal color for coastlines and travel.'),
}
FRESHLUTS_CATEGORY = {'Film Stock & Vintage':'Vintage & Faded','Dark & Moody':'Moody','Cinematic & Blockbuster':'Cinematic',
                      'Teal & Orange Vibes':'Cinematic','Vibrant & Colorful':'Vibrant','Utility & Correction':'Utility'}

# ---------------------------------------------------------------------------------------------------------------
# Film Simulation families → OpenStill's descriptive names (the collection's file names, which name film stocks,
# are recorded in PROVENANCE.md only). Value: (name, category, description).
NEG, SLIDE, INSTANT, BW, CREATIVE = 'Film · Color', 'Film · Slide', 'Film · Instant', 'Film · Black & White', 'Creative'
FILM = {
 'Kodak Portra 160': ('Portrait 160', NEG, 'Fine-grain portrait negative: soft contrast and natural skin.'),
 'Kodak Portra 160 NC': ('Portrait 160 Natural', NEG, 'Lower-saturation portrait negative for gentle skin tones.'),
 'Kodak Portra 160 VC': ('Portrait 160 Vivid', NEG, 'Portrait negative with livelier color.'),
 'Kodak Portra 400': ('Portrait 400', NEG, 'The classic warm, forgiving portrait negative.'),
 'Kodak Portra 400 NC': ('Portrait 400 Natural', NEG, 'Muted, natural portrait color.'),
 'Kodak Portra 400 UC': ('Portrait 400 Ultra', NEG, 'Saturated portrait negative for bright days.'),
 'Kodak Portra 400 VC': ('Portrait 400 Vivid', NEG, 'Portrait negative with punchier color.'),
 'Kodak Portra 800': ('Portrait 800', NEG, 'Fast portrait negative with warm shadows.'),
 'Kodak Portra 800 HC': ('Portrait 800 Contrast', NEG, 'Fast portrait negative with more contrast.'),
 'Kodak Ektar 100': ('Fine Grain Vivid 100', NEG, 'Saturated, very clean negative for landscapes and travel.'),
 'Kodak Elite Color 200': ('Everyday Color 200', NEG, 'A consumer print film look.'),
 'Kodak Elite ExtraColor 100': ('Everyday Extra Color', NEG, 'Consumer film with extra saturation.'),
 'Fuji 160C': ('Studio 160 Contrast', NEG, 'Crisp studio negative with clean whites.'),
 'Fuji 400H': ('Pastel 400', NEG, 'Airy pastel negative with cool greens: a wedding favourite.'),
 'Fuji 800Z': ('Pro 800', NEG, 'Fast professional negative with gentle color.'),
 'Fuji Superia 200': ('Everyday 200', NEG, 'Drugstore film: cool greens and honest color.'),
 'Fuji Superia 100': ('Everyday 100', NEG, 'Clean everyday film.'),
 'Fuji Superia 200 XPRO': ('Cross Process 200', NEG, 'Everyday film cross-processed: shifted colors and contrast.'),
 'Fuji Superia 400': ('Everyday 400', NEG, 'The classic snapshot look.'),
 'Fuji Superia 800': ('Everyday 800', NEG, 'Fast snapshot film with grain-friendly color.'),
 'Fuji Superia 1600': ('Everyday 1600', NEG, 'Very fast film with deep greens.'),
 'Fuji Superia HG 1600': ('Everyday HG 1600', NEG, 'Fast high-grade everyday color.'),
 'Fuji Superia Reala 100': ('True Color 100', NEG, 'Faithful, balanced color.'),
 'Fuji Superia X-Tra 800': ('Everyday Extra 800', NEG, 'Cool, contrasty fast snapshot color.'),
 'Agfa Ultra Color 100': ('Ultra Color 100', NEG, 'Very saturated consumer color.'),
 'Agfa Vista 200': ('Warm Everyday 200', NEG, 'Warm reds and soft contrast.'),
 'Agfa Precisa 100': ('Crisp Slide 100', SLIDE, 'Cool, crisp slide color.'),
 'Fuji Velvia 50': ('Vivid Slide 50', SLIDE, 'Intense saturation and deep contrast for landscapes.'),
 'Fuji Velvia 100 Generic': ('Vivid Slide 100', SLIDE, 'Rich slide color for nature.'),
 'Fuji Provia 100 Generic': ('Standard Slide 100', SLIDE, 'Neutral, accurate slide color.'),
 'Fuji Provia 100F': ('Standard Slide 100F', SLIDE, 'Neutral slide color with fine grain.'),
 'Fuji Provia 400F': ('Standard Slide 400', SLIDE, 'Faster neutral slide color.'),
 'Fuji Provia 400X': ('Standard Slide 400X', SLIDE, 'Faster slide color with a little more punch.'),
 'Fuji Astia 100 Generic': ('Soft Slide 100', SLIDE, 'Gentle slide color for skin.'),
 'Fuji Astia 100F': ('Soft Slide 100F', SLIDE, 'Soft slide color with fine grain.'),
 'Fuji Sensia 100': ('Everyday Slide 100', SLIDE, 'Consumer slide film color.'),
 'Kodak E-100 GX Ektachrome 100': ('Neutral Chrome 100', SLIDE, 'Clean, neutral slide color.'),
 'Kodak Ektachrome 100 VS': ('Vivid Chrome 100', SLIDE, 'Saturated slide color.'),
 'Kodak Ektachrome 100 VS Generic': ('Vivid Chrome 100 Alt', SLIDE, 'Saturated slide color, alternative version.'),
 'Kodak Elite Chrome 200': ('Everyday Chrome 100', SLIDE, 'Consumer slide color.'),
 'Kodak Elite 100 XPRO': ('Cross Process Chrome', SLIDE, 'Slide film cross-processed in negative chemistry.'),
 'Kodak Kodachrome 64': ('Heritage Slide 64', SLIDE, 'Deep reds and dense shadows of mid-century slides.'),
 'Kodak Kodachrome 64 Generic': ('Heritage Slide 64 Alt', SLIDE, 'Mid-century slide color, alternative version.'),
 'Kodak Elite Chrome 400': ('Everyday Chrome 400', SLIDE, 'Faster consumer slide color.'),
 'Kodak Elite Color 400': ('Everyday Color 400', NEG, 'A faster consumer print film look.'),
 'Kodak Kodachrome 25': ('Heritage Slide 25', SLIDE, 'Slow mid-century slide color with rich reds.'),
 'Kodak Kodachrome 200': ('Heritage Slide 200', SLIDE, 'Faster heritage slide color, a little warmer.'),
 'Lomography Redscale 100': ('Redscale', CREATIVE, 'Film exposed through its back: fiery orange and red.'),
 'Lomography X-Pro Slide 200': ('Cross Process Slide 200', SLIDE, 'Punchy cross-processed slide color.'),
 'Polaroid 669': ('Instant Peel-Apart', INSTANT, 'Peel-apart instant color with soft contrast.'),
 'Polaroid 669 Cold': ('Instant Peel-Apart Cold', INSTANT, 'Peel-apart instant color, cool.'),
 'Polaroid 690': ('Instant Classic', INSTANT, 'Classic instant color.'),
 'Polaroid 690 Cold': ('Instant Classic Cold', INSTANT, 'Classic instant color, cool.'),
 'Polaroid 690 Warm': ('Instant Classic Warm', INSTANT, 'Classic instant color, warm.'),
 'Polaroid PX-100UV+ Cold': ('Instant Silver Cold', INSTANT, 'Cool, faded instant tones.'),
 'Polaroid PX-100UV+ Warm': ('Instant Silver Warm', INSTANT, 'Warm, faded instant tones.'),
 'Polaroid PX-680': ('Instant Bright', INSTANT, 'Bright modern instant color.'),
 'Polaroid PX-680 Cold': ('Instant Bright Cold', INSTANT, 'Bright modern instant color, cool.'),
 'Polaroid PX-680 Warm': ('Instant Bright Warm', INSTANT, 'Bright modern instant color, warm.'),
 'Polaroid PX-70': ('Instant Square', INSTANT, 'Modern integral instant color.'),
 'Polaroid PX-70 Cold': ('Instant Square Cold', INSTANT, 'Modern integral instant color, cool.'),
 'Polaroid PX-70 Warm': ('Instant Square Warm', INSTANT, 'Modern integral instant color, warm.'),
 'Polaroid Polachrome': ('Instant Slide', INSTANT, 'Instant slide film with muted, grainy color.'),
 'Polaroid Time Zero (Expired)': ('Instant Expired', INSTANT, 'Expired instant film: faded, shifted color.'),
 'Polaroid Time Zero (Expired) Cold': ('Instant Expired Cold', INSTANT, 'Expired instant film, cool.'),
 'Fuji FP-100c': ('Peel-Apart Color', INSTANT, 'Peel-apart instant color.'),
 'Fuji FP-100c Cool': ('Peel-Apart Color Cool', INSTANT, 'Peel-apart instant color, cool.'),
 'Fuji FP-100c Negative': ('Peel-Apart Negative', INSTANT, 'The peel-apart negative, scanned.'),
 # Black & white
 'Agfa APX 25': ('Classic B&W 25', BW, 'Slow, fine-grained classic black and white.'),
 'Agfa APX 100': ('Classic B&W 100', BW, 'Classic general-purpose black and white.'),
 'Fuji FP-3000b': ('Peel-Apart B&W', BW, 'Peel-apart instant black and white.'),
 'Fuji FP-3000b HC': ('Peel-Apart B&W Contrast', BW, 'Peel-apart black and white with more contrast.'),
 'Fuji FP-3000b Negative': ('Peel-Apart B&W Negative', BW, 'The peel-apart negative, scanned.'),
 'Fuji FP-3000b Negative Early': ('Peel-Apart B&W Negative Early', BW, 'The peel-apart negative pulled early.'),
 'Fuji Neopan 1600': ('Night B&W 1600', BW, 'Fast black and white for low light.'),
 'Fuji Neopan Acros 100': ('Fine B&W 100', BW, 'Very fine grain and smooth tones.'),
 'Ilford Delta 100': ('Modern B&W 100', BW, 'Modern fine-grain black and white.'),
 'Ilford Delta 400': ('Modern B&W 400', BW, 'Modern black and white for everyday light.'),
 'Ilford Delta 3200': ('Modern B&W 3200', BW, 'Very fast modern black and white.'),
 'Ilford FP4 Plus 125': ('Medium B&W 125', BW, 'Traditional medium-speed black and white.'),
 'Ilford HP5': ('Press B&W 400', BW, 'The reportage classic.'),
 'Ilford HP5 Plus 400': ('Press B&W 400 Plus', BW, 'Reportage black and white, current version.'),
 'Ilford HPS 800': ('Fast B&W 800', BW, 'Fast traditional black and white.'),
 'Ilford Pan F Plus 50': ('Slow B&W 50', BW, 'Slow, crisp black and white.'),
 'Ilford XP2': ('Chromogenic B&W 400', BW, 'Smooth black and white made in color chemistry.'),
 'Kodak BW 400 CN': ('Chromogenic B&W 400 Warm', BW, 'Smooth, slightly warm chromogenic black and white.'),
 'Kodak HIE (HS Infra)': ('Infrared B&W', BW, 'Glowing foliage and dark skies of infrared film.'),
 'Kodak T-Max 100': ('Sharp B&W 100', BW, 'Sharp modern black and white.'),
 'Kodak T-Max 400': ('Sharp B&W 400', BW, 'Sharp modern black and white, faster.'),
 'Kodak TMAX 3200': ('Sharp B&W 3200', BW, 'Very fast modern black and white.'),
 'Kodak TRI-X 400': ('Gritty B&W 400', BW, 'The gritty street classic.'),
 'Polaroid 664': ('Instant B&W Soft', BW, 'Soft instant black and white.'),
 'Polaroid 665': ('Instant B&W Peel-Apart', BW, 'Peel-apart instant black and white.'),
 'Polaroid 665 Negative': ('Instant B&W Negative', BW, 'The instant negative, scanned.'),
 'Polaroid 665 Negative HC': ('Instant B&W Negative Contrast', BW, 'The instant negative with more contrast.'),
 'Polaroid 667': ('Instant B&W Fast', BW, 'Fast peel-apart black and white.'),
 'Polaroid 672': ('Instant B&W Punchy', BW, 'Punchy peel-apart black and white.'),
 'Rollei IR 400': ('Infrared B&W Deep', BW, 'Deep infrared black and white.'),
 'Rollei Ortho 25': ('Orthochromatic', BW, 'Red-blind film: dark lips and skies, bright blues.'),
 'Rollei Retro 100 Tonal': ('Retro B&W Tonal 100', BW, 'Soft, tonal retro black and white.'),
 'Rollei Retro 80s': ('Retro B&W 80', BW, 'Crisp retro black and white.'),
}
CREATIVE_NAMES = {  # CreativePack-1: already descriptive; tidy spacing and group numbered sets
 'Anime': 'Anime', 'BleachBypass': 'Bleach Bypass', 'CandleLight': 'Candlelight', 'ColorNegative': 'Color Negative',
 'CrispWarm': 'Crisp Warm', 'CrispWinter': 'Crisp Winter', 'DropBlues': 'Drop Blues', 'EdgyEmber': 'Edgy Ember',
 'FallColors': 'Fall Colors', 'FoggyNight': 'Foggy Night', 'FuturisticBleak': 'Futuristic Bleak', 'HorrorBlue': 'Horror Blue',
 'LateSunset': 'Late Sunset', 'Moonlight': 'Moonlight', 'NightFromDay': 'Night from Day', 'RedBlueYellow': 'Red Blue Yellow',
 'Smokey': 'Smokey', 'SoftWarming': 'Soft Warming', 'TealMagentaGold': 'Teal Magenta Gold', 'TealOrange': 'Teal & Orange',
 'TensionGreen': 'Tension Green',
}
CREATIVE_CATEGORY = {'Anime':'Vibrant','BleachBypass':'Cinematic','CandleLight':'Moody','ColorNegative':'Vintage & Faded','CrispWarm':'Vibrant',
 'CrispWinter':'Seasons','DropBlues':'Moody','EdgyEmber':'Moody','FallColors':'Seasons','FoggyNight':'City & Night','FuturisticBleak':'Cinematic',
 'HorrorBlue':'Moody','LateSunset':'Landscape & Nature','Moonlight':'City & Night','NightFromDay':'City & Night','RedBlueYellow':'Creative',
 'Smokey':'Moody','SoftWarming':'Portrait','TealMagentaGold':'Creative','TealOrange':'Cinematic','TensionGreen':'Moody'}

VARIANT_ORDER = {'--': -2, '-': -1, '': 0, '+': 1, '++': 2, '+++': 3}
PUSH = {'--': '−2', '-': '−1', '+': '+1', '++': '+2', '+++': '+3', 'HC': 'High Contrast'}

# ---------------------------------------------------------------------------------------------------------------
def identity(n=SIZE):
    """(n³, 3) grid in .cube order: red fastest."""
    v = np.linspace(0, 1, n)
    b, g, r = np.meshgrid(v, v, v, indexing='ij')
    return np.stack([r.ravel(), g.ravel(), b.ravel()], 1)

def trilinear(table, n, points):
    """Samples table (n³, 3; red fastest) at points in 0…1."""
    t = table.reshape(n, n, n, 3)  # [b][g][r]
    p = np.clip(points, 0, 1) * (n - 1)
    i0 = np.floor(p).astype(int).clip(0, n - 2); f = p - i0
    r0, g0, b0 = i0[:, 0], i0[:, 1], i0[:, 2]; fr, fg, fb = f[:, :1], f[:, 1:2], f[:, 2:3]
    out = 0
    for db in (0, 1):
        for dg in (0, 1):
            for dr in (0, 1):
                w = (fr if dr else 1 - fr) * (fg if dg else 1 - fg) * (fb if db else 1 - fb)
                out = out + w * t[b0 + db, g0 + dg, r0 + dr]
    return out

def read_cube(path):
    n, rows, lo, hi = 0, [], np.zeros(3), np.ones(3)
    for line in path.read_text(errors='replace').splitlines():
        parts = line.split('#')[0].split()
        if not parts or parts[0] == 'TITLE': continue
        if parts[0] == 'LUT_3D_SIZE': n = int(parts[1]); continue
        if parts[0] == 'DOMAIN_MIN': lo = np.array(list(map(float, parts[1:4]))); continue
        if parts[0] == 'DOMAIN_MAX': hi = np.array(list(map(float, parts[1:4]))); continue
        if len(parts) == 3: rows.append([float(x) for x in parts])
    table = np.array(rows)
    assert n >= 2 and table.shape == (n ** 3, 3), path
    assert np.allclose(lo, 0) and np.allclose(hi, 1), f'{path}: unsupported domain'
    return n, table

def read_hald(path):
    im = np.asarray(Image.open(path).convert('RGB'), dtype=np.float64) / 255
    level = round(im.shape[0] ** (1 / 3))
    n = level * level
    assert im.shape[0] == im.shape[1] == level ** 3, path
    table = im.reshape(-1, 3)  # pixel order = red fastest, then green, then blue
    return trilinear(table, n, identity())

# ---- OpenStill Originals: small colour operations applied to the identity grid --------------------------------
def luma(c): return c @ np.array([0.2126, 0.7152, 0.0722])
def smooth_curve(points, x):
    """Monotone cubic (Fritsch–Carlson) through points [[x, y], …] in 0…1."""
    p = np.array(sorted(points), dtype=float); xs, ys = p[:, 0], p[:, 1]
    if len(xs) == 2: return np.interp(x, xs, ys)
    d = np.diff(ys) / np.diff(xs); m = np.zeros_like(ys); m[1:-1] = (d[:-1] + d[1:]) / 2; m[0], m[-1] = d[0], d[-1]
    for i in range(len(d)):
        if d[i] == 0: m[i] = m[i + 1] = 0
        else:
            a, b = m[i] / d[i], m[i + 1] / d[i]; s = a * a + b * b
            if s > 9: t = 3 / np.sqrt(s); m[i], m[i + 1] = t * a * d[i], t * b * d[i]
    x = np.clip(x, xs[0], xs[-1]); k = np.clip(np.searchsorted(xs, x) - 1, 0, len(d) - 1)
    h = xs[k + 1] - xs[k]; t = (x - xs[k]) / h
    return (2*t**3 - 3*t**2 + 1) * ys[k] + (t**3 - 2*t**2 + t) * h * m[k] + (-2*t**3 + 3*t**2) * ys[k+1] + (t**3 - t**2) * h * m[k+1]

def op(c, o):
    kind = o['op']
    if kind == 'curve':
        for i, ch in enumerate('rgb'):
            if ch in o: c[:, i] = smooth_curve(o[ch], c[:, i])
        if 'all' in o: c = smooth_curve(o['all'], c)
    elif kind == 'contrast':  # S-curve around a pivot; amount > 0 adds contrast
        a, p = o['amount'], o.get('pivot', 0.5)
        c = np.where(c < p, p * (c / p) ** (1 + a), 1 - (1 - p) * ((1 - c) / (1 - p)) ** (1 + a))
    elif kind == 'lgg':  # lift / gamma / gain per channel
        lift, gamma, gain = (np.array(o.get(k, d)) for k, d in (('lift', [0, 0, 0]), ('gamma', [1, 1, 1]), ('gain', [1, 1, 1])))
        c = (np.clip(c * gain + lift * (1 - c), 0, 1)) ** (1 / gamma)
    elif kind == 'sat':
        y = luma(c)[:, None]; s = o['amount']
        if 'by_luma' in o: s = s * smooth_curve(o['by_luma'], y)
        c = y + (c - y) * s
    elif kind == 'vibrance':
        y = luma(c)[:, None]; sat = c.max(1, keepdims=True) - c.min(1, keepdims=True)
        c = y + (c - y) * (1 + o['amount'] * (1 - sat))
    elif kind == 'hue':  # rotate hue in YIQ
        a = np.radians(o['degrees']); m = np.array([[0.299, 0.587, 0.114], [0.596, -0.274, -0.322], [0.211, -0.523, 0.312]])
        yiq = c @ m.T; i, q = yiq[:, 1].copy(), yiq[:, 2].copy()
        yiq[:, 1], yiq[:, 2] = i * np.cos(a) - q * np.sin(a), i * np.sin(a) + q * np.cos(a)
        c = yiq @ np.linalg.inv(m).T
    elif kind == 'split':  # tint shadows and highlights towards colours
        y = luma(c)[:, None]; bal = o.get('balance', 0.5)
        ws = np.clip(1 - y / max(bal, 1e-3), 0, 1) ** 1.5; wh = np.clip((y - bal) / max(1 - bal, 1e-3), 0, 1) ** 1.5
        c = c + ws * (np.array(o['shadows']) - 0.5) * o.get('amount', 0.3) * 2 + wh * (np.array(o['highlights']) - 0.5) * o.get('amount', 0.3) * 2
    elif kind == 'mix':
        c = c @ np.array(o['matrix']).T
    elif kind == 'mono':
        w = np.array(o.get('weights', [0.2126, 0.7152, 0.0722])); w = w / w.sum()
        c = np.repeat((c @ w)[:, None], 3, 1)
    elif kind == 'tone':  # map luminance onto a gradient of colours, blended by amount
        y = luma(np.clip(c, 0, 1)); stops = np.array(o['colors'], dtype=float); pos = np.linspace(0, 1, len(stops))
        g = np.stack([np.interp(y, pos, stops[:, i]) for i in range(3)], 1)
        c = c + (g - c) * o.get('amount', 1)
    elif kind == 'fade':  # lift blacks, lower whites
        c = o.get('black', 0.06) + c * (o.get('white', 1.0) - o.get('black', 0.06))
    elif kind == 'warm':  # simple white-balance style shift; negative is cooler
        a = o['amount']; c = c * np.array([1 + a * 0.12, 1 + a * 0.02, 1 - a * 0.12])
    elif kind == 'tint':  # positive is magenta
        a = o['amount']; c = c * np.array([1 + a * 0.04, 1 - a * 0.08, 1 + a * 0.04])
    elif kind == 'exposure':
        c = c * 2 ** o['stops']
    elif kind == 'rolloff':  # soft shoulder above a knee
        k = o.get('knee', 0.75); over = np.maximum(c - k, 0)
        c = np.where(c > k, k + (1 - k) * (1 - np.exp(-over / (1 - k))), c)
    elif kind == 'solarize':
        a = o.get('amount', 0.5); c = c + (np.where(c > 0.5, 1 - c, c) * 2 * 0.5 - c) * a
    elif kind == 'posterize':
        n = o['levels']; soft = o.get('soft', 0.35)
        q = np.round(c * (n - 1)) / (n - 1); c = c + (q - c) * (1 - soft)
    else:
        raise ValueError('unknown op ' + kind)
    return np.clip(c, 0, 1)

def generate(recipe):
    c = identity()
    for o in recipe['ops']: c = op(c.copy(), o)
    return c

# ---------------------------------------------------------------------------------------------------------------
def encode(table, bits=16):
    """(n³,3) floats → (UInt16 planes bytes, compressed blob); values are v / (2^bits − 1)."""
    q = np.round(np.clip(table, 0, 1) * (2 ** bits - 1)).astype('<u2')
    planes = np.concatenate([q[:, 0], q[:, 1], q[:, 2]])
    raw = planes.tobytes()
    deltas = np.diff(planes.astype(np.int64), prepend=0).astype(np.uint16).astype('<u2')  # mod 2¹⁶
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    return raw, comp.compress(deltas.tobytes()) + comp.flush()

def slug(text): return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--openshot', required=True, type=Path); ap.add_argument('--film', required=True, type=Path)
    args = ap.parse_args()
    authors = (args.openshot / 'AUTHORS.md').read_text()
    looks = []  # dicts with table + metadata

    # 1. FreshLUTs (CC0)
    rows = [l.split('|') for l in authors.splitlines() if l.startswith('| ') and 'freshluts.com/luts/' in l]
    assert 'Creative Commons CC0' in authors and len(rows) == 50, 'AUTHORS.md must state CC0 for all 50 entries'
    for r in rows:
        fid, creator, original, filename, category = int(r[1]), r[2].strip(), r[3].strip(), r[9].strip(), r[10].strip()
        n, table = read_cube(args.openshot / filename)
        known = FRESHLUTS.get(filename)
        name = known[1] if known else ' '.join(w.capitalize() if w not in ('&',) else w for w in filename[:-5].replace('_', ' ').split())
        looks.append(dict(id=f'freshluts-{fid}', name=name, category=known[2] if known else FRESHLUTS_CATEGORY[category],
                          creator=known[3] if known else creator, source=f'https://freshluts.com/luts/{fid}', license='CC0-1.0',
                          description=known[4] if known else f'{r[8].strip()} look from the FreshLUTs community.',
                          tags=[t.strip().lower() for t in (r[5], r[6], r[7]) if t.strip() and t.strip() != 'None'],
                          original=f'{original} ({filename})', dimension=n, table=table, group='FreshLUTs (CC0)'))

    # 2. Film Simulation (CC BY-SA 4.0)
    assert 'CC BY-SA 4.0' in (args.film / 'README.txt').read_text()
    families = {}
    for path in sorted(args.film.rglob('*.png')):
        kind, brand = path.relative_to(args.film).parts[:2]
        base = path.stem
        m = re.match(r'^(.*?) (\d)(?: (-+|\++))?(?: (Alt|HC))?$', base)
        family, variant = (m.group(1), (m.group(3) or '') + (' ' + m.group(4) if m.group(4) else '')) if m else (base, '')
        if brand == 'CreativePack-1':
            m = re.match(r'^([A-Za-z]+?)(\d?)$', base); family, variant = m.group(1), m.group(2)
        families.setdefault((kind, brand, family), []).append((variant.strip(), path))
    missing = []
    for (kind, brand, family), items in families.items():
        if brand == 'CreativePack-1':
            name, category, description = CREATIVE_NAMES[family], CREATIVE_CATEGORY[family], 'A creative look from the RawTherapee collection.'
        elif family in FILM:
            name, category, description = FILM[family]
        else:
            missing.append(family); continue
        def order(v):
            s = v[0].split(' ')[0]; return (VARIANT_ORDER.get(s, int(s) if s.isdigit() else 0), v[0])
        items.sort(key=order)
        fam_id = 'film-' + slug(name)
        for variant, path in items:
            label = ' '.join(PUSH.get(w, w) for w in variant.split())
            looks.append(dict(id=fam_id + ('-' + slug(label.replace('+', 'plus').replace('−', 'minus')) if label else ''),
                              name=name, family=fam_id if len(items) > 1 else None, variant=(label or 'Normal') if len(items) > 1 else None,
                              category=category, creator=FILM_CREDIT, source=FILM_SOURCE, license='CC-BY-SA-4.0', description=description,
                              tags=['film'] + (['black and white'] if kind.startswith('Black') else []),
                              original=str(path.relative_to(args.film)), dimension=SIZE, table=read_hald(path), bits=8, group='Film Simulation (CC BY-SA 4.0)'))
    if missing: sys.exit('Name these families first: ' + ', '.join(sorted(missing)))

    # 3. OpenStill Originals (CC0)
    recipes = json.loads((ROOT / 'Resources/LUTs/originals.json').read_text())
    for r in recipes['looks']:
        looks.append(dict(id='openstill-' + slug(r['name']), name=r['name'], category=r['category'], creator=ORIGINALS_CREDIT,
                          source='https://github.com/haon-v2/OpenStill/blob/main/Resources/LUTs/originals.json', license='CC0-1.0',
                          description=r['description'], tags=r.get('tags', []), original='originals.json', dimension=SIZE,
                          table=generate(r), group='OpenStill Originals (CC0)'))

    ids = [l['id'] for l in looks]; dup = {i for i in ids if ids.count(i) > 1}
    assert not dup, dup
    # Pack
    out = bytearray(b'OSLUTPK1'); entries = []
    for l in looks:
        raw, blob = encode(l['table'], l.get('bits', 16))
        entry = {k: l[k] for k in ('id', 'name', 'category', 'creator', 'source', 'license', 'description')}
        entry.update(tags=l['tags'], dimension=l['dimension'], offset=len(out), length=len(blob), checksum=hashlib.sha256(raw).hexdigest())
        if l.get('bits', 16) != 16: entry.update(bits=l['bits'])
        if l.get('family'): entry.update(family=l['family'], variant=l['variant'])
        entries.append(entry); out += blob
    (ROOT / 'Resources/LUTs/Library.lutpack').write_bytes(out)
    (ROOT / 'Resources/LUTs/catalog.json').write_text(json.dumps(dict(version=2, pack='Library.lutpack', entries=entries), indent=1, ensure_ascii=False) + '\n')
    # Provenance
    lines = ['# Bundled look provenance', '',
             'Built by scripts/build-lut-pack.py. Every look below is free to use and redistribute under the license shown.', '',
             '- **FreshLUTs community looks (CC0-1.0).** From OpenShot revision ' + OPENSHOT_REVISION + ', whose src/colors/AUTHORS.md states that every entry is released under Creative Commons CC0. https://github.com/OpenShot/openshot-qt/blob/' + OPENSHOT_REVISION + '/src/colors/AUTHORS.md',
             '- **RawTherapee Film Simulation Collection 2015-09-20 (CC BY-SA 4.0)** by Pat David, Pavlov Dmitry and Michael Ezra. https://rawpedia.rawtherapee.com/Film_Simulation . OpenStill converted the 8-bit Hald CLUT images to 33×33×33 tables at 8-bit precision; the converted tables are shared under the same CC BY-SA 4.0 license (see CC-BY-SA-4.0.txt). Film stock names in the original file names were used by the authors for informational purposes only; OpenStill shows its own descriptive names, and neither OpenStill nor the authors are affiliated with or endorsed by the film makers.',
             '- **OpenStill Originals (CC0-1.0).** Generated from the recipes in Resources/LUTs/originals.json.', '',
             '| OpenStill id | Name | License | Creator | Original |', '|---|---|---|---|---|']
    for l, e in zip(looks, entries):
        lines.append(f"| {e['id']} | {e['name']}{' · ' + e['variant'] if e.get('variant') else ''} | {e['license']} | {e['creator']} | {l['original']} |")
    (ROOT / 'Resources/Licenses/LUTs/PROVENANCE.md').write_text('\n'.join(lines) + '\n')
    groups = {}
    for l in looks: groups[l['group']] = groups.get(l['group'], 0) + 1
    print(f'{len(looks)} looks, {len(out) / 1e6:.1f} MB:', groups)

if __name__ == '__main__':
    main()
