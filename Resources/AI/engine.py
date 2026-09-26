#!/usr/bin/env python3
"""OpenStill's local-only model worker. No network access during inference."""
import argparse, hashlib, json, os, pathlib, subprocess, sys, urllib.request, venv
ROOT = pathlib.Path.home() / 'Library/Application Support/OpenStill/AI'
MANIFEST = json.loads(pathlib.Path(__file__).with_name('models.json').read_text())

def say(text): print(text, flush=True)

def setup():
    if not (3, 10) <= sys.version_info[:2] <= (3, 12):
        raise RuntimeError("Local AI setup needs Python 3.10–3.12. Install Python 3.12, then try again.")
    ROOT.mkdir(parents=True, exist_ok=True)
    runtime = ROOT / 'runtime'
    if not (runtime / 'bin/python3').exists(): venv.create(runtime, with_pip=True)
    python = str(runtime / 'bin/python3')
    subprocess.run([python, '-m', 'pip', 'install', '--only-binary=:all:', 'onnxruntime==1.23.2', 'numpy==2.2.6', 'Pillow==12.0.0'], check=True)
    folder = ROOT / 'models'; folder.mkdir(exist_ok=True)
    for kind, files in MANIFEST.items():
        for spec in files:
            target = folder / spec['name']
            if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == spec['sha256']: continue
            say('Downloading ' + kind + ' model…')
            temp = target.with_name(target.name + '.download')
            request = urllib.request.Request(spec['url'], headers={'User-Agent': 'OpenStill/0.2'})
            with urllib.request.urlopen(request, timeout=120) as response, temp.open('wb') as out:
                while block := response.read(1024 * 1024): out.write(block)
            if temp.stat().st_size != spec['size'] or hashlib.sha256(temp.read_bytes()).hexdigest() != spec['sha256']:
                temp.unlink(missing_ok=True); raise RuntimeError('Model verification failed for ' + kind)
            temp.replace(target)
    (ROOT/'ready.json').write_text(json.dumps({'version':1, 'models': MANIFEST}))
    say('Local AI tools are ready.')

MODEL_FOR = {'skymask': 'sky', 'upscale': 'detail'}

def session(kind):
    import onnxruntime as ort
    kind = MODEL_FOR.get(kind, kind)
    path = ROOT/'models'/MANIFEST[kind][0]['name']
    options = ort.SessionOptions(); options.intra_op_num_threads = 4
    options.log_severity_level = 3
    return ort.InferenceSession(str(path), sess_options=options, providers=['CPUExecutionProvider'])

def run(args):
    if pathlib.Path(args.input).suffix == '.osfloat':
        from float_bridge import run as run_float
        return run_float(args, session, say)
    import numpy as np
    from PIL import Image, ImageFilter, ImageOps
    image = Image.open(args.input).convert('RGB')
    w, h = image.size
    model = session(args.tool)
    if args.tool in ('skymask', 'depth', 'upscale', 'denoise', 'detail'):
        from float_bridge import tiled, sky_mask, depth_map
        bounded = np.asarray(image, dtype=np.float32)/255
        if args.tool == 'skymask': sky_mask(bounded, model, w, h).save(args.output)
        elif args.tool == 'depth': depth_map(bounded, model, w, h).save(args.output)
        else:
            result = tiled(bounded, model, args.tool, say, scale=2 if args.tool == 'upscale' else 1)
            Image.fromarray((np.clip(result, 0, 1)*255+.5).astype('uint8')).save(args.output)
        say('Done'); return
    if args.tool == 'sky':
        small = np.asarray(image.resize((320,320),Image.Resampling.BILINEAR),dtype=np.float32)/255
        small = (small - np.array([.485,.456,.406])) / np.array([.229,.224,.225])
        pred = model.run([model.get_outputs()[0].name], {model.get_inputs()[0].name: small.transpose(2,0,1)[None].astype(np.float32)})[0].squeeze()
        # U2-Net publishes a sigmoid mask. Preserve confidence instead of normalizing an empty mask into a false sky.
        pred = np.clip(pred, 0, 1)
        if float((pred > .6).mean()) < .002 or float((pred > .6).mean()) > .98:
            raise RuntimeError('No reliable sky boundary was found. Try a photo with a clearly visible sky.')
        mask = Image.fromarray((np.clip((pred-.25)/.5,0,1)*255).astype('uint8')).resize((w,h),Image.Resampling.BILINEAR)
        mask = mask.filter(ImageFilter.GaussianBlur(max(1, min(w,h)/1200)))
        if not args.sky: raise RuntimeError('Choose a replacement sky photo first.')
        replacement = ImageOps.fit(Image.open(args.sky).convert('RGB'),(w,h),method=Image.Resampling.LANCZOS,centering=(.5,0))
        Image.composite(replacement,image,mask).save(args.output)
        mask.save(str(pathlib.Path(args.output).with_suffix('.mask.png')))
    elif args.tool == 'erase':
        mask = Image.open(args.mask).convert('L').resize((w,h))
        bbox = mask.getbbox()
        if not bbox: raise RuntimeError('Paint over the object you want to remove first.')
        # Use a padded region around the mask, preserving every unpainted pixel at original resolution.
        x0,y0,x1,y1=bbox; pad=max(48,int(max(x1-x0,y1-y0)*.4))
        box=(max(0,x0-pad),max(0,y0-pad),min(w,x1+pad),min(h,y1+pad))
        patch=image.crop(box); pmask=mask.crop(box)
        # OpenCV's LaMa export uses BGR input and outputs values in [0,255].
        arr=np.asarray(patch.resize((512,512),Image.Resampling.LANCZOS),dtype=np.float32)[:,:,::-1]/255
        m=(np.asarray(pmask.resize((512,512),Image.Resampling.NEAREST))>0).astype(np.float32)[None,None]
        pred=model.run(None,{'image':arr.transpose(2,0,1)[None].copy(),'mask':m})[0][0]
        pred=np.clip(pred.transpose(1,2,0)[:,:,::-1],0,255).astype('uint8')
        restored=Image.fromarray(pred).resize(patch.size,Image.Resampling.LANCZOS)
        patch=Image.composite(restored,patch,pmask)
        image.paste(patch,box[:2]); image.save(args.output)
    say('Done')

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('tool',choices=['setup','sky','skymask','erase','denoise','detail','upscale','depth'])
    for flag in ['input','output','mask','sky']: parser.add_argument('--'+flag)
    args=parser.parse_args()
    try:
        if args.tool=='setup': setup()
        else: run(args)
    except Exception as error:
        print(str(error),file=sys.stderr,flush=True); sys.exit(1)
