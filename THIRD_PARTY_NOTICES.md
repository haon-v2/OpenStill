# Third-party components

OpenStill source code is MIT licensed. AI weights are downloaded separately and retain their own licenses. Copies of the relevant license texts are bundled in `Resources/Licenses` and the built app. No rights to Luminar software, branding, or proprietary models are implied.

| Tool | Model / source | License |
| --- | --- | --- |
| Sky selection | [Sky Segmentation and Post-processing](https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing); [ONNX distribution](https://huggingface.co/JianyuanWang/skyseg) | MIT, `sky.txt` |
| Object removal | [LaMa](https://github.com/advimman/lama); [OpenCV ONNX distribution](https://huggingface.co/opencv/inpainting_lama) | Apache 2.0, `erase.txt` |
| Noise removal | [SCUNet](https://github.com/cszn/SCUNet); [ONNX distribution](https://huggingface.co/Heliosoph/scunet-onnx) | Apache 2.0, `denoise.txt` |
| Detail restoration, 2× super resolution | [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN); [ONNX distribution](https://huggingface.co/Heliosoph/realesrgan-onnx) | BSD 3-Clause, `detail.txt` |
| Depth estimation | [Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2) (Small); [ONNX distribution](https://huggingface.co/onnx-community/depth-anything-v2-small) | Apache 2.0, `depth.txt` |

Exact download revisions, file sizes, and SHA-256 digests are recorded in `Resources/AI/models.json`. OpenStill adapts inference preprocessing, tiled processing, mask composition, and output sizing in `Resources/AI/engine.py`. Original weights are not trained or modified by this project.

The optional isolated Python environment installs ONNX Runtime 1.23.2 (MIT), NumPy 2.2.6 (BSD), and Pillow 12.0.0 (HPND), plus their dependencies. Their licenses ship with the installed distributions. Python is supplied by the user's existing installation and is not bundled with OpenStill. Apple AppKit, Core Image, and ImageIO are operating-system frameworks.

For local QA, the sky model author's `eval/233129.jpg` was downloaded to a temporary test folder. It is not included with the app or source distribution.

## Local LUT library

BONBOA, Neagh, and Kitaura © Ross McConaghy / rossandhisjpegs are free creator downloads for local use. They are not included in this repository/app bundle and are not relicensed under OpenStill's MIT license. Local provenance lives in `~/Library/Application Support/OpenStill/LUTLibrary/sources.json`. Sources: https://www.rossandhisjpegs.com/lumix/bonboa, https://www.rossandhisjpegs.com/lumix/neagh, https://www.rossandhisjpegs.com/lumix/kitaura.

Apple Vision supplies foreground-instance segmentation and horizon detection through public operating-system APIs. No Apple model weights are redistributed. These are separate from Apple Intelligence / Photos Clean Up.

Additional local-only QA photograph: [Horizon Sea.jpg](https://commons.wikimedia.org/wiki/File:Horizon_Sea.jpg) by Yvessurbano0, CC BY-SA 4.0. A rotated derivative is stored only in the temporary QA folder. Neither is bundled with the source/app.

## Bundled look library

`Resources/LUTs/Library.lutpack` holds OpenStill's bundled looks. `Resources/LUTs/catalog.json` names each look's creator, source, license and SHA-256; `Resources/Licenses/LUTs/PROVENANCE.md` lists every look with its original name and source. OpenStill's categories, names and descriptions are editorial suggestions, not creator endorsements.

- **RawTherapee Film Simulation Collection** (version 2015-09-20) by Pat David, Pavlov Dmitry and Michael Ezra, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) (full text in `Resources/Licenses/LUTs/CC-BY-SA-4.0.txt`). Source: https://rawpedia.rawtherapee.com/Film_Simulation . OpenStill converted the 293 Hald CLUT images to 33×33×33 tables at 8-bit precision with `scripts/build-lut-pack.py`; the converted tables are shared under the same CC BY-SA 4.0 license. Film stock names appear in the collection's file names for information only; OpenStill shows its own descriptive names, and neither OpenStill nor the collection's authors are affiliated with or endorsed by the film makers.
- **FreshLUTs community looks** (50), CC0-1.0, from OpenShot revision `9004af74b02c67e507190e9950b5fc690fb0a900`, whose [src/colors/AUTHORS.md](https://github.com/OpenShot/openshot-qt/blob/9004af74b02c67e507190e9950b5fc690fb0a900/src/colors/AUTHORS.md) states that every entry is released under Creative Commons CC0. Each look links to its creator's FreshLUTs page. No OpenShot application code is included.
- **OpenStill Originals** (77), CC0-1.0, generated from `Resources/LUTs/originals.json`.

The full CC0 dedication is in `Resources/Licenses/LUTs/CC0-1.0.txt`.

## LibRaw 0.22.2

OpenStill's native RAW decoder uses unmodified LibRaw source, distributed under
its CDDL-1.0 option. Copyright LibRaw LLC and the contributors listed in
`Resources/Licenses/LibRaw/COPYRIGHT`. The complete corresponding source archive,
CDDL text, alternative LGPL text, and pinned SHA-256 provenance are bundled in
`Resources/Licenses/LibRaw`. No optional GPL demosaic packs, RawSpeed, Adobe DNG
SDK or GoPro SDK are compiled. zlib is provided by macOS.

## Native lens and proofing dependencies

OpenStill bundles dynamically linked Lensfun 0.3.4 (LGPL-3.0), GLib 2.88.3
(LGPL-2.1-or-later), PCRE2 10.48 (BSD-3-Clause), proxy-libintl 0.5 (LGPL-2.0-or-later),
and Little CMS 2.19.1 (MIT). Unmodified corresponding source archives, including
complete copyright/license files, are in `Resources/Licenses/NativeSources`.
Versions, official download URLs and SHA-256 values are recorded in
`Resources/Licenses/native-dependencies.json`. Build instructions are in
`scripts/build-native.sh`. Libraries are separate in `Contents/Frameworks` and may
be replaced with compatible modified versions; re-sign the modified app locally
using `codesign --force --deep --sign - OpenStill.app`.

Lensfun contributors' profiles are licensed CC BY-SA 3.0. The pinned database
revision, schema compatibility conversion and full license are in
`Resources/LensProfiles`. Its corresponding source is bundled with the native
sources. Unsupported ACM calibrations are omitted during schema conversion;
OpenStill reports the capabilities present in each bundled profile.

## Local watermark layout generation

The bundled `OpenStillLogoInference` helper is built from unmodified llama.cpp,
revision `1ab7e5ad2d4e7295c94c3b966a3e0b70fa365865`, under the MIT license.
The optional official Qwen3-0.6B Q8_0 model is Apache-2.0, revision
`23749fefcc72300e3a2ad315e1317431b06b590a`. It is downloaded separately, not
bundled. Exact URLs, sizes, SHA-256 checksums and both license texts are in
`Resources/Licenses/LogoAI`. Build instructions: `scripts/build-logo-helper.sh`.

The model chooses constrained layout parameters. OpenStill supplies all vector
shapes and renders the photographer's exact text locally using macOS fonts; no
font files are redistributed. Model output cannot execute code or arbitrary SVG.

## Sparkle

In-app updates use [Sparkle](https://github.com/sparkle-project/Sparkle) 2 (MIT-style license, with bundled components under their own permissive licenses). The full text is in `Resources/Licenses/Sparkle/LICENSE`. The built app bundles `Sparkle.framework` without its XPC services.
