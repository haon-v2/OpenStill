"""Float image exchange. Models consume bounded sRGB; preserve out-of-range residuals.
No RGB8 conversion is used in this path. Pillow F images resample each float channel.
"""
import pathlib
import struct
import numpy as np
from PIL import Image, ImageFilter


def read(path):
    data = pathlib.Path(path).read_bytes()
    if len(data) < 12 or data[:4] != b'OSF1':
        raise ValueError('Invalid OpenStill float image header')
    w, h = struct.unpack('<II', data[4:12])
    if not 0 < w <= 65535 or not 0 < h <= 65535 or len(data) != 12 + w*h*16:
        raise ValueError('Invalid OpenStill float image dimensions')
    pixels = np.frombuffer(data, dtype='<f4', offset=12).reshape(h, w, 4).copy()
    if not np.isfinite(pixels).all():
        raise ValueError('Non-finite image samples')
    return pixels


def write(path, pixels):
    if not np.isfinite(pixels).all():
        raise ValueError('The model produced non-finite image samples')
    h, w, _ = pixels.shape
    target = pathlib.Path(path)
    temporary = target.with_suffix('.osfloat.pending')
    with temporary.open('wb') as stream:
        stream.write(b'OSF1' + struct.pack('<II', w, h))
        stream.write(np.asarray(pixels, dtype='<f4').tobytes())
    temporary.replace(target)


def resize(data, size, resample=Image.Resampling.LANCZOS):
    if data.ndim == 2:
        return np.asarray(Image.fromarray(data.astype(np.float32)).resize(size, resample), dtype=np.float32)
    return np.stack([resize(data[:, :, c], size, resample) for c in range(data.shape[2])], axis=2)


def tiled(bounded, model, tool, say, scale=1, tile=256, border=32):
    """Runs a restoration model over overlapping tiles and blends the overlaps with linear ramps, so no seams show.
    `scale` 2 returns an image twice the size (from the 4x detail model)."""
    h, w = bounded.shape[:2]
    out = np.zeros((h*scale, w*scale, 3), dtype=np.float32)
    weight = np.zeros((h*scale, w*scale, 1), dtype=np.float32)
    total = ((w+tile-1)//tile)*((h+tile-1)//tile); done = 0
    def ramp(n, lead, trail):
        r = np.ones(n, dtype=np.float32)
        lead, trail = min(lead, n), min(trail, n)
        if lead: r[:lead] = (np.arange(lead, dtype=np.float32)+1)/(lead+1)
        if trail: r[n-trail:] = np.minimum(r[n-trail:], ((np.arange(trail, dtype=np.float32)[::-1])+1)/(trail+1))
        return r
    for y in range(0, h, tile):
        for x in range(0, w, tile):
            x0, y0 = max(0, x-border), max(0, y-border)
            x1, y1 = min(w, x+tile+border), min(h, y+tile+border)
            patch = bounded[y0:y1, x0:x1]; ph, pw = patch.shape[:2]
            padded = np.pad(patch, ((0, (-ph) % 64), (0, (-pw) % 64), (0, 0)), mode='reflect')
            pred = model.run(None, {model.get_inputs()[0].name: padded.transpose(2, 0, 1)[None].astype(np.float32)})[0][0]
            rendered = np.clip(pred.transpose(1, 2, 0), 0, 1)
            target = (padded.shape[1]*scale, padded.shape[0]*scale)
            if rendered.shape[1] != target[0] or rendered.shape[0] != target[1]: rendered = resize(rendered, target)
            rendered = rendered[:ph*scale, :pw*scale]
            # Ramps only where this tile overlaps a neighbour; image edges keep full weight.
            wy = ramp(ph*scale, (y-y0)*scale*2 if y0 > 0 else 0, (y1-min(h, y+tile))*scale*2 if y1 < h else 0)
            wx = ramp(pw*scale, (x-x0)*scale*2 if x0 > 0 else 0, (x1-min(w, x+tile))*scale*2 if x1 < w else 0)
            wt = (wy[:, None]*wx[None, :])[:, :, None]
            out[y0*scale:y1*scale, x0*scale:x1*scale] += rendered*wt
            weight[y0*scale:y1*scale, x0*scale:x1*scale] += wt
            done += 1; say(f'Processing {done} of {total} tiles')
    return out/np.maximum(weight, 1e-6)


def sky_mask(bounded, model, w, h):
    small = resize(bounded, (320, 320), Image.Resampling.BILINEAR)
    small = (small - np.array([.485, .456, .406])) / np.array([.229, .224, .225])
    pred = model.run([model.get_outputs()[0].name], {model.get_inputs()[0].name: small.transpose(2, 0, 1)[None].astype(np.float32)})[0].squeeze()
    pred = np.clip(pred, 0, 1)
    if float((pred > .6).mean()) < .002 or float((pred > .6).mean()) > .98:
        raise RuntimeError('No reliable sky boundary was found. Try a photo with a clearly visible sky.')
    mask = np.clip(resize(np.clip((pred-.25)/.5, 0, 1), (w, h), Image.Resampling.BILINEAR), 0, 1)
    return Image.fromarray((mask*255).astype('uint8')).filter(ImageFilter.GaussianBlur(max(1, min(w, h)/1200)))


def depth_map(bounded, model, w, h):
    """Depth Anything V2: relative inverse depth, stretched to 0…1 with near = white."""
    size = 518
    small = resize(bounded, (size, size), Image.Resampling.BICUBIC)
    small = (small - np.array([.485, .456, .406])) / np.array([.229, .224, .225])
    pred = model.run(None, {model.get_inputs()[0].name: small.transpose(2, 0, 1)[None].astype(np.float32)})[0].squeeze()
    low, high = np.percentile(pred, 1), np.percentile(pred, 99)
    if not np.isfinite([low, high]).all() or high - low < 1e-6:
        raise RuntimeError('Depth could not be estimated for this photo.')
    depth = np.clip((pred-low)/(high-low), 0, 1)
    depth = np.clip(resize(depth.astype(np.float32), (w, h), Image.Resampling.BICUBIC), 0, 1)
    return Image.fromarray((depth*255).astype('uint8')).filter(ImageFilter.GaussianBlur(max(1, min(w, h)/900)))


def run(args, session, say):
    original = read(args.input)
    h, w = original.shape[:2]
    rgb = original[:, :, :3]
    bounded = np.clip(rgb, 0, 1)
    residual = rgb - bounded
    result = bounded.copy()
    model = session(args.tool)
    if args.tool == 'sky':
        small = resize(bounded, (320, 320), Image.Resampling.BILINEAR)
        small = (small - np.array([.485, .456, .406])) / np.array([.229, .224, .225])
        pred = model.run([model.get_outputs()[0].name], {model.get_inputs()[0].name: small.transpose(2, 0, 1)[None].astype(np.float32)})[0].squeeze()
        pred = np.clip(pred, 0, 1)
        if float((pred > .6).mean()) < .002 or float((pred > .6).mean()) > .98:
            raise RuntimeError('No reliable sky boundary was found. Try a clearly visible sky.')
        mask = np.clip(resize(np.clip((pred-.25)/.5, 0, 1), (w, h), Image.Resampling.BILINEAR), 0, 1)
        # Masks may be 8-bit; photograph samples never are.
        mask_image = Image.fromarray((mask*255).astype('uint8')).filter(ImageFilter.GaussianBlur(max(1, min(w,h)/1200)))
        mask = np.asarray(mask_image, dtype=np.float32)[:, :, None]/255
        replacement = read(args.sky)[:, :, :3]
        sh, sw = replacement.shape[:2]
        scale = max(w/sw, h/sh)
        replacement = resize(replacement, (int(np.ceil(sw*scale)), int(np.ceil(sh*scale))))
        left = max(0, (replacement.shape[1]-w)//2)
        result = rgb*(1-mask) + replacement[:h,left:left+w]*mask
        mask_image.save(str(pathlib.Path(args.output).with_suffix('.mask.png')))
    elif args.tool == 'erase':
        mask_image = Image.open(args.mask).convert('L').resize((w, h))
        box = mask_image.getbbox()
        if not box: raise RuntimeError('Paint over the object first.')
        x0,y0,x1,y1 = box; pad = max(48, int(max(x1-x0,y1-y0)*.4))
        x0,y0,x1,y1 = max(0,x0-pad),max(0,y0-pad),min(w,x1+pad),min(h,y1+pad)
        patch = bounded[y0:y1,x0:x1]
        mask = np.asarray(mask_image, dtype=np.float32)[y0:y1,x0:x1]/255
        arr = resize(patch, (512,512))[:,:,::-1]
        m = (resize(mask,(512,512), Image.Resampling.NEAREST)>0).astype(np.float32)[None,None]
        pred = model.run(None, {'image':arr.transpose(2,0,1)[None].copy(), 'mask':m})[0][0]
        restored = resize(np.clip(pred.transpose(1,2,0)[:,:,::-1]/255,0,1),(x1-x0,y1-y0))
        result = rgb.copy()
        # Exact untouched pixels; model output replaces only the painted region.
        result[y0:y1,x0:x1] = rgb[y0:y1,x0:x1]*(1-mask[:,:,None]) + restored*mask[:,:,None]
    elif args.tool in ('skymask', 'depth'):
        image = sky_mask(bounded, model, w, h) if args.tool == 'skymask' else depth_map(bounded, model, w, h)
        image.save(args.output); say('Done'); return
    elif args.tool == 'upscale':
        big = tiled(bounded, model, args.tool, say, scale=2) + resize(residual, (w*2, h*2))
        alpha = resize(original[:, :, 3], (w*2, h*2))
        output = np.concatenate([big, alpha[:, :, None]], axis=2)
        write(args.output, output); say('Done'); return
    else:
        result = tiled(bounded, model, args.tool, say) + residual
    output = original.copy(); output[:,:,:3] = result
    write(args.output,output); say('Done')
