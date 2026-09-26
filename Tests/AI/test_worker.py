"""Checks the AI worker's image plumbing with stand-in models (no downloads): seamless tiling, 2x output, depth and sky maps.
Run: python3 Tests/AI/test_worker.py (needs numpy and Pillow)."""
import pathlib, sys, tempfile
import numpy as np
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Resources/AI'))
import float_bridge as fb

class Input:
    def __init__(self, name): self.name = name
class Identity:
    """Returns its input: tiling must then reproduce the image exactly."""
    def get_inputs(self): return [Input('x')]
    def get_outputs(self): return [Input('y')]
    def run(self, names, feeds): return [next(iter(feeds.values()))]
class Brighten(Identity):
    """A per-tile offset would show as seams if overlaps weren't blended."""
    def __init__(self): self.calls = 0
    def run(self, names, feeds):
        self.calls += 1; x = next(iter(feeds.values()))
        return [np.clip(x + (0.02 if self.calls % 2 else -0.02), 0, 1)]
class Upscale4(Identity):
    def run(self, names, feeds):
        x = next(iter(feeds.values())); return [x.repeat(4, axis=2).repeat(4, axis=3)]
class Depth(Identity):
    def run(self, names, feeds):
        x = next(iter(feeds.values()))[0]; return [x.mean(axis=0)[None]]   # brighter = nearer

say = lambda text: None
rng = np.random.default_rng(1)
image = rng.random((300, 517, 3)).astype(np.float32)

out = fb.tiled(image, Identity(), 'denoise', say)
assert out.shape == image.shape and np.abs(out - image).max() < 1e-5, 'identity tiling changed pixels'

smooth = np.tile(np.linspace(0, 1, 517, dtype=np.float32)[None, :, None], (300, 1, 3))
blended = fb.tiled(smooth, Brighten(), 'denoise', say)
steps = np.abs(np.diff(blended[:, :, 0], axis=1)).max()
assert steps < 0.01, f'visible seam between tiles ({steps:.3f})'

big = fb.tiled(smooth, Upscale4(), 'upscale', say, scale=2)
assert big.shape == (600, 1034, 3), big.shape
assert np.abs(big[::2, ::2] - smooth).max() < 0.02, '2x output does not match the source'

gradient = np.tile(np.linspace(0, 1, 200, dtype=np.float32)[:, None, None], (1, 120, 3))
depth = np.asarray(fb.depth_map(gradient, Depth(), 120, 200), dtype=np.float32) / 255
assert depth.shape == (200, 120) and depth[-5:].mean() > 0.9 and depth[:5].mean() < 0.1, 'depth map not stretched to 0…1'

class Sky(Identity):
    def run(self, names, feeds):
        pred = np.zeros((1, 1, 320, 320), dtype=np.float32); pred[..., :120, :] = 1; return [pred]
mask = np.asarray(fb.sky_mask(image, Sky(), 517, 300), dtype=np.float32) / 255
assert mask.shape == (300, 517) and mask[:60].mean() > 0.9 and mask[-60:].mean() < 0.05, 'sky mask misplaced'

with tempfile.TemporaryDirectory() as folder:
    path = pathlib.Path(folder) / 'x.osfloat'
    pixels = np.concatenate([image * 1.5 - 0.2, np.ones((300, 517, 1), np.float32)], axis=2)
    fb.write(path, pixels); assert np.array_equal(fb.read(path), pixels.astype('<f4'))
print('AI worker checks passed')
