# OpenStill

A free, open-source macOS photo viewer and editor. A little space for your photographs.

OpenStill 0.6 combines a native photo browser with nondestructive editing, local AI tools, complete ImageIO-readable metadata, and sharing. Originals are preserved.

## Use

Open **OpenStill.app**, then choose **Open…** or drop a photo or folder onto the viewer. Opening a single photo loads the supported images beside it, sorted naturally by filename (photo2 before photo10). Folder browsing includes that folder only, not its subfolders. Dropping multiple files creates a selection from those files.

| Action | Control |
| --- | --- |
| Open photo or folder | ⌘O |
| Previous / next photo | ← / →, or Option-scroll over the photo |
| Next / previous photo | Space / Shift-Space |
| Fit to window | ⌘0 |
| Actual pixels (100%) | ⌘1 |
| Toggle Fit / 100% | Double-click the photo |
| Zoom in / out | Pinch, mouse wheel, or ⌘+ / ⌘− |
| Pan when zoomed in | Drag the photo |
| Full screen | ⌃⌘F or the full-screen button |
| Photo info | ⌘I |
| Undo / redo edit | ⌘Z / ⇧⌘Z |
| Export edited photo | ⇧⌘E |
| Select multiple photos | ⌘-click to toggle, Shift-click for a range |
| Select all photos | ⌘A |
| Share selected photos | ⇧⌘S or the Share button |
| Move current photo to Trash | Delete, ⌘Delete, or right-click → Move to Trash… |
| Reveal in Finder | ⌘R |
| Leave full screen / return to Fit | Escape |

The filmstrip scrolls horizontally and lets you select any photo directly. Navigation stops at the first and last image. Pinch and wheel zoom anchor to the pointer, from 1% to 1600%. Hold Option while scrolling over the photo to browse images instead. At **100%**, one image pixel occupies one physical display pixel, including on Retina displays. Fit mode shows the entire image without enlarging it beyond 100%.

## Move to Trash

Press **Delete** while browsing, use **File → Move to Trash… (⌘Delete)**, or right-click the photo or a filmstrip thumbnail. Right-clicking a thumbnail selects that photo first. A confirmation names the exact file and its folder; **Cancel** is the default. Only the selected original is moved, leaving paired RAW/JPEG files and sidecars alone. Trash is available when exactly one photo is selected; select a single thumbnail before deleting.

After confirmation, OpenStill uses macOS Trash and advances to a remaining photo. You can recover the file from Finder's Trash. If the device is read-only or does not support Trash, OpenStill shows an error and never falls back to permanent deletion. No files are removed from the viewer until the Trash operation succeeds. Holding Delete does not repeatedly trigger deletion.

## Metadata

The Info panel reads embedded EXIF, TIFF, and auxiliary metadata through Apple's ImageIO framework:

- Camera make and model; lens make and model (or recorded lens specifications).
- Shutter speed, aperture, ISO, focal length, 35mm equivalent, exposure compensation.
- Capture time, oriented pixel dimensions, format, and file size.

The camera, lens, ISO, focal length, aperture, and shutter remain visible above the editing tools. **Info → All recorded metadata** expands every property supplied by ImageIO, including nested EXIF/TIFF/GPS fields when available.

Missing fields say **Not recorded**. Capture time is the camera's recorded local time; its offset is shown when embedded. Images exported without EXIF cannot reveal settings that were removed. Proprietary maker notes, sidecar XMP files, and lens-ID databases are not parsed in this version.

Common formats include JPEG, PNG, HEIC, TIFF, and other formats supported by the installed macOS ImageIO decoders. Sensor RAW development uses bundled LibRaw 0.22.2. Unsupported files show a capability error. Animated/multipage images show the first frame/page. EXIF orientation is applied. Images retain their embedded color space for display, but HDR editing and HDR proofing are outside this release.

## Library and catalog

OpenStill keeps a local SQLite catalog (`Catalog.sqlite`, next to your edit records in Application Support). It indexes every photo you open: file path, size and modification date, capture date, camera, lens, ISO, focal length, aperture, dimensions and GPS position, plus ratings, flags, labels, titles, captions and keywords. Your edit records stay the source of truth. The catalog is an index that is kept in sync as you work, and records saved by earlier versions are indexed the first time you open a photo after updating.

- **Faster opening.** A photo whose path, size and modification date haven't changed is found in the catalog without re-reading the whole file. A moved or renamed file is still recognized by its contents.
- **Include subfolders** (Library sidebar) scans the folders inside the one you open. Hidden folders and packages are skipped.
- **Color labels.** Press **6** red, **7** yellow, **8** green or **9** blue, or use **Label** for purple and Clear. Pressing a photo's current label key again clears it. Labels show as a colored strip on each thumbnail. Filter by label, or show only unlabeled photos.
- **Metadata.** Select photos and choose **Actions → Edit metadata…** to set title, caption, creator, copyright, location, city, state, country and keywords. Keywords can have levels with `>`, for example `Places > France > Paris`; searching for "France" also finds it. With several photos selected, filled-in fields apply to all of them, keywords are added, and **Remove keywords** takes keywords off. Save frequent fields such as creator and copyright as **metadata presets**. Metadata is stored with OpenStill's edits and your original files are not changed. Exports include it as IPTC, with the keyword's last level as the IPTC keyword, when **Keep metadata** is on.
- **Collections.** **Actions → Add to collection…** puts the selected photos in a new or existing collection. Collections list in the sidebar and can hold photos from any folder. Control-click a collection to rename or delete it; deleting a collection never deletes photos. **Actions → Remove from this collection** takes photos out.
- **Smart collections** gather every catalog photo that matches up to six rules: rating, flag, label, keyword, camera, lens, ISO, capture date, filename, edited, or any text. Choose whether all rules or any rule must match. They update themselves.
- **Search** matches filenames, titles, captions, keywords, camera and lens. Every word must match.
- **Preview cache.** Library thumbnails are saved as small JPEGs under `Previews`, keyed by the edit version and revision, so unchanged photos appear without rendering again. An edit makes a new preview and removes the old one.

Moved or deleted files drop out of collections until they're found again. XMP sidecars and Lightroom catalog import come in a later release.

## Lumix S9 and Real Time LUT

For Panasonic `.RW2` files, OpenStill displays the **largest embedded camera JPEG** in both the viewer and filmstrip. This retains the look actually recorded by the camera, including a Real Time LUT, without trying to reproduce Panasonic's processing from the ungraded sensor data. Ordinary camera JPEGs already contain their recorded look.

The S9 files checked locally include both a 1920 × 1280 JPEG and a full-resolution 6000 × 4000 JPEG. OpenStill selects the latter and applies the RAW container's orientation when that JPEG lacks its own rotation metadata. No JPEG recompression or second LUT application occurs. The Info panel and status bar label the displayed camera preview and its actual pixel dimensions.

Some Panasonic files may include only a smaller preview. In that case, 100% refers to that preview's pixels, not invented full-resolution detail. If no usable camera JPEG exists, Camera Look reports that capability limitation; choose RAW when the sensor file is supported. The Presets panel can apply imported 3D `.cube` LUTs to the displayed camera preview. Choose **Photo & Versions → RAW** to develop sensor data separately. It does not import `.vlt` files. It does not infer a LUT name from the image's colors.

References: [Panasonic S9 Photo Style / RAW limitations](https://eww.pavc.panasonic.co.jp/dscoi/DC-S9/html/DC-S9_DVQP3138_eng/0071.html), [Panasonic RAW container tags](https://exiftool.org/TagNames/PanasonicRaw.html).

## Sharing

Select photographs in the filmstrip with **⌘-click** to add or remove individual photos, **Shift-click** to select a range, or **⌘A** to select all. Shift-arrow keys extend or shrink a range while the filmstrip is focused. A plain click or normal arrow navigation returns to a single selection. The header shows the selection count, and selected thumbnails have blue borders.

Click **Share**, press **⇧⌘S**, or right-click a selected thumbnail and choose **Share Photos…**. The share window captures that selection in filmstrip order. **Messages (including iMessage), AirDrop**, and **More…** receive all prepared files as separate attachments. You choose the recipient and send from the system sharing interface. Provider attachment/size limits still apply.

**JPEG — as viewed** renders each selected photo's active saved version, including RAW development, edits, cropping and LUTs. It produces sRGB JPEG copies with camera/lens/copyright metadata and removes GPS by default. Camera Look retains the embedded preview's recorded appearance; sensor RAW uses its separate version. **Original file** copies the source unchanged, including original metadata and GPS. RAW appearance in another app depends on its renderer. Originals and edit histories are never modified by sharing.

For **Google Drive, Dropbox, WeTransfer, Pixieset, and Pic-Time**, choose the website, open it in your default browser, and drag the prepared photo stack into its upload area. Browser sign-in is handled by that website. These are manual browser handoffs, not connected accounts or automatic uploads. You can also use **Show in Finder** to locate all prepared files, or **Save copies…** to save into a local folder or an existing synced cloud folder. Your cloud provider's app handles synchronization. Saving never overwrites an existing file.

Sharing copies are kept in OpenStill's temporary sharing folder so other apps can finish reading them; copies older than seven days are cleaned up when preparing another share. Source photos are never changed. Batch preparation shows progress and keeps same-named photos as separate files. If any photo cannot be prepared, sharing is disabled and the failed filename is shown; no incomplete batch is silently sent. Saving to a folder reports how many copies succeeded if a later copy fails. No Google or Dropbox developer registration is required.

## Build

Requires macOS 13+ to run and the macOS 26 SDK with Swift 6+ to build (Xcode or Apple's Command Line Tools). Build tools: CMake, Ninja, Meson, pkg-config and Python 3. Native dependency sources and logo helper revisions are pinned; the build scripts download and compile missing dependencies. The built app bundles its native libraries and helper, requiring no Homebrew at runtime. Optional AI uses a separate Python runtime described below. Browsing and editing are local; optional sharing uses macOS services or your browser. The only other network request is the update check described below.

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open dist/OpenStill.app
```

In a build environment that cannot nest the Swift Package Manager sandbox, pass `--disable-sandbox` to those Swift commands or the build script. This only affects the build process.

The build script creates an ad-hoc-signed app for the current Mac architecture. A public downloadable release will need a distribution/signing decision and testing on supported macOS versions. You can also open `Package.swift` in Xcode.

## Structure

- `OpenStillCore`: file discovery, orientation-aware decoding, metadata extraction, Retina display geometry, sharing exports.
- `OpenStill`: native AppKit window, photo canvas, asynchronous image cache, virtualized filmstrip, Info and Share panels.
- `Tests`: temporary image fixtures, metadata parsing, file ordering, pixel geometry.

All browsing stays on your Mac. OpenStill never edits original image contents; moving an original to Trash requires confirmation. Full-resolution images and thumbnails use bounded memory caches; very large single images still require enough memory to decode.

## Appearance

OpenStill uses native Liquid Glass on macOS 26, with a system toolbar, floating inspector and filmstrip, thin SF Symbols, and green accents for selections, sliders, and primary actions. It follows the system light/dark appearance and accessibility transparency settings. Earlier macOS versions use native visual-effect materials. The photograph canvas stays opaque and color-neutral. Export, shoot, comparison, batch and logo windows share the same materials and spacing.

## Editing

The Lightroom-desktop-inspired workspace has a slim local-library rail on the left, the photograph or library grid in the center, and an editing rail on the right. **Library / Edit** switches views in the same window. Library includes current/recent folders, search, ratings, color labels, pick/reject filters, collections, comparison and batch actions (see **Library and catalog** below). Double-click a photo to edit it; its filtered selection becomes the bottom filmstrip. The right rail opens **Edit**, **Crop**, **Retouch**, the current tool’s **Mask**, **Presets**, **History**, and **Info**. Use the toolbar’s inspector button for more image space; ⌘I opens camera and lens information. ⌥⌘G opens Library and ⌥⌘E returns to Edit. Click a tool name to expand its controls; scroll to reach the remaining tools.

- Profile & calibration: start from **Standard**, **Neutral**, **Vivid**, **Portrait**, **Landscape** or **Monochrome**, OpenStill's own looks, or **Import DCP profile…** to use a DNG Camera Profile you already have. **Profile amount** blends from none (0) to twice the look (2). OpenStill applies a DCP's hue/saturation map, look table and tone curve in linear ProPhoto RGB; its color matrices are not used because RAW files are decoded with LibRaw's camera matrices. Profiles work on about two stops of light above white; anything brighter is clipped at that point. **Calibration** moves the red, green and blue primaries around the color wheel (red toward yellow, green toward cyan, blue toward magenta) and changes their saturation, with a shadows green/magenta tint. Neutral grays stay neutral.
- RAW decoding (in Profile & calibration, for RAW sources): choose the demosaic method (AHD by default, or AAHD, DCB, DHT, VNG, PPG, or fast bilinear), LibRaw's wavelet noise reduction, color-noise median passes and hot-pixel (FBDD) reduction. Each change decodes the RAW again.
- Develop: exposure, contrast, highlights, shadows, whites, blacks, temperature, and tint. **Auto** reads the photo's tonal range and sets exposure, contrast, highlights, shadows, whites, blacks and vibrance as one undoable step you can keep refining. (Whites and Blacks are shared with Black & white and follow its mask.)
- Dehaze: positive removes atmospheric haze using a dark-channel estimate; negative adds haze.
- Clarity: broad midtone contrast (negative softens). Texture: medium-sized detail such as skin, foliage or fabric (negative smooths).
- Color grading: Shadows, Midtones, Highlights and Global wheels. Drag in a wheel to set hue and strength, set each range's luminance, and use Blending and Balance to control how the ranges overlap. Double-click a wheel to reset it.
- Grain: film-like grain with Amount, Size and Roughness. Grain size scales with the photo, so previews and full-size exports match.
- Defringe (in Lens corrections): removes purple and green fringes along high-contrast edges, with adjustable hue ranges. Evenly colored purple or green areas are left alone.
- Clipping and comparison: click the histogram, press **J**, or choose **View → Show / Hide Clipping** to show clipped highlights in red and clipped shadows in blue. Press **Y** (or **View → Before / After Split**) for a side-by-side split with a draggable divider; press **\\** to toggle the full before view.
- Dehaze, Clarity, Texture, Color grading, Grain and Defringe are OpenStill's own algorithms. They are designed to feel familiar to Lightroom users but are not pixel-identical to Adobe's.
- Enhance: automatic tonal/color correction. Structure, sharpening, and noise reduction.
- Color: global saturation/vibrance plus eight visible swatches for red, orange, yellow, green, aqua, blue, purple, and magenta. Each color remembers its Saturation or HSL view. HSL provides Hue, Saturation, and Lightness with shade-gradient tracks and a live color indicator; switching views keeps your adjustments. Reset this color clears only the selected band.
- Black & white: monochrome strength plus separate Blacks and Whites tonal sliders.
- Vignette: negative darkens the edges, zero is neutral, positive lightens them.
- Glow (Creative): choose **Glow**, **Soft Focus**, **Orton Effect**, or **Orton Effect Soft**. Amount controls strength; expand Advanced for Softness, Brightness, Contrast, and Warmth. Starts disabled at Amount 0. Glow blooms around highlights; Soft Focus gently diffuses the photograph. All four looks support their own brush, gradient, radial, and object mask. Reset Glow keeps its mask and all other edits. Settings are included in saved presets and edit history, and render locally in previews and exports without a model download. These are OpenStill's own photographic diffusion algorithms, not pixel-identical copies of Luminar's filters.
- Transform: **Upright** buttons find long straight edges in the photo and correct them. **Level** rotates only; **Vertical** also makes vertical lines parallel; **Full** corrects vertical and horizontal perspective; **Auto** is a gentler balance of the three; **Guided** lets you drag 2–4 lines on the photo along edges that should be vertical or horizontal (Escape finishes, **Clear guides** removes them). Manual **Vertical**, **Horizontal**, **Rotate**, **Aspect**, **Scale** and **X/Y offset** sliders add to Upright. **Constrain crop** (on by default) enlarges the photo just enough that no empty edges show; turned off, empty edges export as white in JPEG and transparent in PNG and TIFF. The correction runs after lens corrections and before straighten and crop, and masks, retouching and the white balance eyedropper follow it. Upright finds lines itself, on this Mac; it is not Adobe's algorithm and can pick different lines, so check the result and switch modes or use Guided when it misjudges a scene.
- Crop: draw a rectangle and Apply crop; rotate, flip, or reset. **Crop preset** offers Freeform, Original proportions, Square, and separate **Horizontal** and **Vertical** groups: photo ratios (3:2, 4:3, 5:4, 16:9, 21:9 and their vertical versions) and common resolutions (720p, Full HD, QHD, 4K UHD, 1080 × 1350 portrait posts, 1080 × 1920 stories/reels). **Swap horizontal ↔ vertical** turns the chosen preset 90°. While cropping, the frame and the panel show the crop's aspect ratio and pixel size (for example `16:9 · 3840 × 2160`); with a resolution preset, the panel warns when the crop is smaller than that resolution. Straighten manually (−20° to +20°), choose **Auto straighten from lines** to level the photo from its long straight edges, or choose **AI align horizon** for local Apple Vision detection. Straightening automatically fills the frame without empty corners. If no confident tilted horizon is found, the photo stays unchanged. Escape ends a drawing tool.
- Layers: one image overlay with opacity and normal/screen/multiply blending; edit-strength control blends tonal adjustments with their input.
- Sunrays: Amount, Overall Look, Sunrays Length, Penetration, Sun Radius, Sun Glow Radius/Amount, Number of Sunrays, Randomize, and separate Sun/Sunrays Warmth controls, following [Luminar Neo’s documented layout](https://support.skylum.com/editing-tools/landscape-tools/sunrays). OpenStill uses its own local algorithm, not pixel-matched Skylum processing. Click **Place Sun Center**, then click or repeatedly drag inside or outside the photo; Escape finishes. Placement adds workspace margins, and arrow keys nudge the center (Shift for larger steps). Amount starts at zero. The final light blend uses the tool’s independent mask. Old saved Sunrays effects retain the legacy renderer until this tool is adjusted. New centers follow source geometry through crop, rotation, flip, and straightening; each drag is one undo step.
- Presets: six starting looks, save/load `.openstillpreset` files, and a categorized 3D `.cube` LUT library with photo previews, intensity, and its own mask. Saved portable presets include tonal/color settings, but exclude masks, LUT asset references, geometry, and AI/image assets; loading preserves those from the current photo.
- Edits: undo, redo, click a previous history step, compare with the original, or reset. A new change after undo replaces the redo branch.

### Per-feature masks

Each adjustment group has Adjustments and Masking tabs, including AI tools. Choose Masking, then Brush, Linear, Radial, or Object AI. LUTs have a Mask this LUT button. Crop/rotation always changes the whole canvas.

Masks belong to their individual tool. Switching tools ends the active brush/selection and hides its overlay; a tool without a saved mask starts with the entire photo. Returning to a tool keeps its own saved mask. A pending AI object selection is discarded when you leave its tool, and clearing a mask affects only that tool.

- **Brush**: choose Paint or Erase and adjust Size, Softness, and Strength. The red brush outline shows its size; [ and ] resize it. Brush strokes can refine linear, radial, and AI object masks without replacing them.
- **Linear**: a live red gradient previews the fade while dragging, with boundary guides and a half-strength center line. New gradients fade across the full drag distance; Feather narrows the transition. Drag from the unaffected side toward the fully adjusted side.
- **Radial**: drag from the center to the edge of an ellipse.
- **AI object**: click inside a distinct foreground subject. Uses Apple's on-device Vision instance segmentation on macOS 14+; it is not arbitrary text-prompt/background-object selection.
- **Feather**, **Invert**, and **Show/hide** control the mask. The red overlay is never exported. **Back to adjustments** or Escape ends drawing and keeps the mask; **Mask actions → Clear mask** restores the adjustment to the whole photo. Choosing a new shape updates the selected component. Add another named component to combine selections.

Masks, strokes, and history persist between launches. Coordinates stay attached to the source through crop/rotate/flip/straighten. Edits made before running an AI tool become its input; the latest AI result's blend mask remains editable, and undo restores earlier settings and masks. Erase cannot remove a new object merely by expanding the result's blend mask: select the new region and run removal again.

### Free LUT library

**Presets → LUT Library** includes 12 free CC0 looks in every installation, ready offline:

| Category | Included looks |
| --- | --- |
| Portraits | Vintage 400 Film, Romantic Cinema, Golden Years Film |
| Cityscape & Street | City Neon Cinema, City Night Film, Night Glow |
| Automotive | Cool Cinema, Teal Punch, Noir Era |
| Nature & Landscape | Emerald Film, Woodland Drama, Tropical Teal |

Choose a category, then click a photo preview to apply a look at 70% intensity. The intensity slider, LUT mask, Remove LUT, and Undo remain available. Preview cards use the current photo and its other adjustments, including the LUT mask; browsing them does not add history steps. New looks preview at 70%; the selected look previews at its current intensity. Thumbnails use reduced resolution; inspect the main canvas at 100% for fine detail. All processing is local.

Categories are OpenStill recommendations, not automatic subject detection or exclusive uses. These are stylized, display-referred creative looks, not LOG conversions or sensor-RAW development. They add to the appearance already recorded in a JPEG or S9 embedded preview and cannot remove a baked-in LUT. Lower the intensity if the recorded camera look is already strong.

Files are pinned to OpenShot revision `9004af74b02c67e507190e9950b5fc690fb0a900`. `Resources/LUTs/catalog.json` records creator-page CC0 verification, source links, and SHA-256 digests. License and provenance records are in `Resources/Licenses/LUTs`. The optional maintainer script `scripts/fetch-luts.py` re-downloads this pinned collection and verifies creator-page license notices; the app makes no download requests. Credits: [OpenShot LUT authors](https://github.com/OpenShot/openshot-qt/blob/9004af74b02c67e507190e9950b5fc690fb0a900/src/colors/AUTHORS.md).

**Imported** preserves existing files in `~/Library/Application Support/OpenStill/LUTLibrary`. BONBOA, Neagh, and Kitaura by Ross McConaghy remain local imports on this Mac and are not bundled or relicensed. Use **Import .cube LUT…** to add compatible 3D LUTs (2–65 points per dimension). Applied LUTs are copied into the edit asset store so saved edits survive library updates.

Local Lumix import sources: [BONBOA](https://www.rossandhisjpegs.com/lumix/bonboa), [Neagh](https://www.rossandhisjpegs.com/lumix/neagh), [Kitaura](https://www.rossandhisjpegs.com/lumix/kitaura).

History saves automatically in `~/Library/Application Support/OpenStill/PhotoRecords`, with ten rotating recovery snapshots. Existing `Edits` histories migrate without changing legacy rendering. Stable IDs, file bookmarks and full-content fingerprints relink moved originals; filename alone never transfers edits. Existing versions and imported LUT assets remain available. The filmstrip displays originals; the Shoot grid displays saved edits.

**Export** writes a separate JPEG, PNG, or TIFF with compatible recorded camera/lens metadata. An export cannot overwrite its source, including through a symbolic link. Export offers JPEG or 8/16-bit PNG/TIFF with sRGB, Display P3, Adobe RGB or ProPhoto RGB profiles. New edits use floating-point extended-linear Rec.2020 processing; display output is color managed. LUTs are interpreted in sRGB. Legacy versions keep their earlier renderer until explicitly upgraded or a new feature requires an upgraded copy. Proprietary maker notes are not copied into newly rendered exports because their offsets and processing data may no longer be valid.

## Photographer workflow

- **Photo & Versions:** named alternatives, rename/delete, renderer upgrade, and separate Camera Look / RAW versions. S9 defaults to Camera Look; other supported RAW cameras default to RAW. Switching source mode preserves the previous version and starts fresh geometry. RAW exposes highlight recovery and camera-WB-based adjustment. The temperature control is a relative adaptation around the as-shot balance, not a calibrated absolute sensor Kelvin readout.
- **Exposure:** RGB/luminance histogram, rendered clipping, separate RAW sensor saturation, master/RGB tone curves, and a neutral WB eyedropper. Sampling excludes overlays and watermarks. RAW WB changes decoding.
- **Lens corrections:** bundled Lensfun profiles; unique reliable RAW matches are enabled automatically. Camera Look/JPEG start with corrections off. Manual profile selection and fine tuning remain available. Missing profile capabilities stay disabled.
- **Masks:** per-tool named components with visibility, opacity, rename, duplicate/delete, independent copying, and add/subtract/intersect. Color and luminance ranges sample that tool's input; brush, gradient, radial and object selection remain available. Image and selections share optical/geometry transforms.
- **Retouch:** choose Heal or Clone, choose a source point (or Option-click), then paint. Size, feather, opacity and aligned cloning are nondestructive; each stroke has undo. AI Erase is separate.
- **Shoot:** grid, 0–5 stars, Pick/Reject/Unflagged, filters and sorting. Select two photographs for synchronized comparison with separate metadata. Reject flags do not delete files. Copy adjustments, select targets and Paste to review the exact affected files/groups before applying. Masks, geometry, retouching, lens settings and AI assets are excluded by default; compatible geometry/masks require opt-in. Undo Batch protects later edits.
- **Export:** reusable presets, selected-photo queue, dimensions, quality, profiles, bit depth, sharpening and filename templates. Default JPEG/sRGB/90%, original size, no upscale/watermark, camera/lens/copyright retained and GPS removed. Output sharpening follows resize and precedes the watermark. Unique names protect existing files. Completed files remain when another job fails; retry unfinished jobs. Proofing accepts a printer/paper ICC profile with intent, paper simulation and gamut warnings, changing only the preview.
- **Portable edits:** explicitly export/import `.openstilledits` packages from File or Version options. They include all versions, ratings, masks and referenced assets with checksums, optionally copying the original. Packages without originals require verified relinking. Imports create additional versions and never silently replace existing versions. Automatic saves remain local.

### Photographer watermark designer

In **Export → Watermarks**, choose **Import logo** or **Create logo**. Import transparent PNG/TIFF, JPEG, PDF, or static SVG; OpenStill stores a private asset copy. SVG paths, shapes, solid fills/strokes and transforms are supported. Active content, external references, text, filters and other unsupported SVG features produce an actionable error; export those files as outlined SVG or transparent PNG first.

Manual design needs no model. Enter your exact name/initials and optional tagline, then adjust typography, symbol, layout, spacing and colors. Save reusable designs or export outlined SVG, vector PDF or transparent PNG. Emoji or glyphs without outlines are rejected rather than silently omitted.

The optional **Download local model · 639 MB** installs checksum-verified official Qwen3-0.6B Q8_0. It generates three editable layout suggestions using the bundled llama.cpp helper. Metal is used on Apple silicon; CPU mode is available and is the Intel default. Download/generation can be cancelled and the model removed. Inference stays offline; the model cannot execute code, supply arbitrary SVG, or change your exact text. This designer affects photographer watermarks only, not OpenStill's app icon.

Export placement offers nine anchors, percentage width, margin and opacity with a live preview. Watermarks belong to export presets and never enter editing masks or original files.

## Local AI tools

Four real local models are integrated: sky segmentation/replacement (U2-Net), object removal (LaMa), noise removal (SCUNet), and detail restoration (Real-ESRGAN). These are independent open-source implementations, not Luminar's proprietary engines. Results depend on the photograph and mask; review fine texture at 100% and undo when needed.

Choose **Set up local AI tools…** once. This downloads approximately 350 MB of pinned, SHA-256-verified model files plus the Python packages; no account or API key is needed. This Mac has already been set up. For a fresh installation, install Python 3.11 or 3.12 at a supported Homebrew or `/usr/local/bin` location, then run setup. AI's pinned NumPy wheels require macOS 14+ on Apple Silicon; the native viewer/editor targets macOS 13+. Other architectures/macOS versions have not been validated for AI.

- **Erase AI**: create a brush, linear, radial, or AI object mask over the unwanted area, then **Remove selected area**. LaMa processes a padded region around the mask. Cover the object including its edges. Brush refinement and feathering are available.
- **Sky replacement AI**: choose your own replacement sky photograph. The model detects a sky boundary, blends the replacement into that area, and rejects masks with no reliable boundary. There is no automatic foreground relighting or reflection replacement.
- **Noise removal AI** and **Detail restoration AI** process overlapping tiles to bound memory. Detail restoration keeps the original dimensions; it is not an upscale export.

Apple’s public Apple Intelligence developer APIs do not expose the Photos **Clean Up** removal model. OpenStill uses Apple **Vision** for object masks/horizon detection and **LaMa** for local removal, not Apple Intelligence Clean Up. References: [Apple Intelligence for developers](https://developer.apple.com/apple-intelligence/), [Vision foreground instances](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest), [Vision horizon detection](https://developer.apple.com/documentation/vision/vndetecthorizonrequest).

Processing stays on this Mac. The worker does not upload images or access the network during inference. Full-resolution AI jobs can take several minutes on CPU; Cancel AI processing stops the worker. Navigating away cancels the current job. Each finished AI result becomes a reversible history step and a new base for subsequent adjustments. Earlier adjustments are baked into that step; undo returns to their editable settings.

The modern AI bridge exchanges float32 extended-sRGB pixels without whole-image 8-bit quantization. Models themselves accept bounded [0,1] sRGB input; out-of-range residuals are preserved around that boundary. Their training limits still apply to HDR/extreme-gamut content. Legacy histories retain their original bridge.

The Python runtime and models are stored in `~/Library/Application Support/OpenStill/AI`. Developer setup: `bash scripts/setup-ai.sh`. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `Resources/Licenses` for model sources and licenses.

## Updates

**OpenStill → Check for Updates…** uses [Sparkle](https://sparkle-project.org) to read the update feed, [`appcast.xml`](appcast.xml) on `main`. When a newer version is listed, OpenStill shows **What's new** in that version before you install it, and can download, verify, install and relaunch it for you. You can also skip that version or be reminded later. **Check for Updates Automatically** (on by default) checks once a day. **OpenStill → Settings… (⌘,)** shows the installed version, how updates are delivered, when OpenStill last checked, and has the same automatic-check switch, **Check Now** and a link to all releases. Edits and the library live in Application Support and are kept. The check sends no information about your photos. Sparkle sends only the request for the feed.

Until `SUPublicEDKey` is set in `Resources/Info.plist`, and in builds run with `swift run`, the app falls back to the older check. That check compares the installed version with the public [GitHub releases](https://github.com/haon-v2/OpenStill/releases) and opens the release page, and you replace OpenStill in Applications yourself.

### Publishing an update

**Automatic (recommended):** on GitHub, open **Actions → Release → Run workflow**, keep the branch on `main`, and enter the new version (for example `0.0.2`). The visible version can be any number not released before; the hidden build number (`CFBundleVersion`) goes up by one every release, and that is what Sparkle uses to decide what is newer. The workflow:
- raises the version and build number in `Resources/Info.plist` (tick **Run tests** to run the test suite first; it's off by default because merged code was already tested on its pull request);
- builds the app, zips it and signs it for Sparkle;
- creates the `v<version>` release with the zip;
- adds the release to `appcast.xml` on `main`, with its **What's new** list.

**What's new** is shown in the update window before anyone installs. Type it in the **notes** box, separating points with `;` (for example `Faster library;Fixed crop presets`). Leave it empty to list the titles of the pull requests merged since the last release that changed the app (pull requests that only touch workflows or docs are left out).

Installed copies see the update on their next check. Tick **Dry run** to build and sign with a throwaway key without publishing anything.

The workflow signs with the repository secret `SPARKLE_PRIVATE_KEY`. One-time setup, on the Mac whose keychain holds the key (see below):
1. In the repository folder, export the private key to a file: `"$(find .build/artifacts -type f -name generate_keys | head -1)" -x ~/Desktop/sparkle-private-key`.
2. On GitHub, open **Settings → Secrets and variables → Actions → New repository secret**, name it `SPARKLE_PRIVATE_KEY`, and paste the file's contents.
3. Delete the file: `rm ~/Desktop/sparkle-private-key`. Keep your own backup somewhere safe, such as a password manager.

**By hand:** raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` (Sparkle compares `CFBundleVersion`, so it must always go up). Run `bash scripts/release.sh` (optionally with `NOTES`, one point per line), which builds, zips, signs with the key in your keychain and adds the entry to `appcast.xml`. Then create the GitHub release `v<version>`, attach the zip, and push `appcast.xml` and `Info.plist` to `main`.

**Signing key:** created once with `generate_keys` (in `.build/artifacts/sparkle/Sparkle/bin/` after a build). It stores the private key in your login keychain and prints the public key, which goes in `Resources/Info.plist` as `SUPublicEDKey`. Every update must be signed with that same private key, because installed apps reject anything else.

Builds are made for Apple silicon (the GitHub runner and current Macs). An Apple silicon build is marked as arm64-only in the feed, so Intel Macs aren't offered it.

## Coverage

See [WORKFLOW_IMPLEMENTATION.md](WORKFLOW_IMPLEMENTATION.md) for actual validation and hardware coverage. Public distribution still needs Developer ID signing/notarization and broader camera, Intel and macOS-version testing. Current builds are locally ad-hoc signed.

## License

MIT. See [LICENSE](LICENSE). The name is a working project name; trademark/domain availability has not been established.
