# Version 0.1.4 verification

Verified locally on an Apple Silicon Mac running macOS 26.6.2.

- Version 0.1.4: all 33 automated tests pass. Six additional tests cover individual selection toggles, range expansion/contraction, Select All and plain-click reset, batch ordering and filename collisions, unchanged mixed RAW/JPEG originals, and failed-batch cleanup without touching existing files.
- Native UI verified with three generated test photographs: ⌘A highlights all and reports three selected; right-click keeps the selection and offers Share 3 Photos; the sharing panel prepares three files and the native macOS picker reports “3 Images.” Save copies writes all three, with exact SHA-256 equality to the source JPEGs. Plain click resets to one selection; Shift-Right extends to two and Shift-Left shrinks to one. Delete while multiple photos are selected does nothing, and the Trash menu explains to select one photo. Command-click and Shift-click transitions are covered by the selection-model tests; this automation interface cannot hold a modifier during a mouse click. No messages were sent and no cloud uploads were performed.

- Version 0.1.3 adds confirmed Move to Trash through the photo context menu, filmstrip context menu, Delete/forward Delete, and File → Move to Trash (⌘Delete). Cancel is the default confirmation action; key repeats and duplicate requests are ignored.
- Native UI verification used two disposable generated JPEG copies in `/tmp/OpenStill-Trash-QA`. Delete opened the correct filename confirmation; Return cancelled without changing the file (SHA-256 unchanged). Right-click on the unselected second thumbnail selected and targeted that photo. Confirming moved it to Trash and selected the remaining image. The main photo context menu was verified, then Delete and confirmation moved the final test photo and cleared the viewer, metadata, and filmstrip. Both disposable filenames were verified in Finder's Trash. No real user photographs were deleted. Physical external-volume/read-only failures have not been exercised; the implementation uses `FileManager.trashItem` and has no permanent-deletion fallback.

- Release build succeeds and the installed app passes `codesign --verify --deep --strict`.
- The earlier 27-test baseline covers: 14 viewer/core tests, eight Panasonic camera-preview tests, and five sharing-export tests. Camera checks cover largest-preview selection, exact decoded-pixel equality, all eight EXIF orientation transforms, avoiding double rotation, filmstrip consistency, fallback to smaller previews, big-endian containers, and malformed/truncated offsets and lengths. Sharing checks cover exact JPEG preservation, oriented full-resolution camera-look export, unchanged original RAW bytes, duplicate filenames without overwriting, invalid exports, and full-resolution PNG conversion with white transparency flattening.
- Native UI checked with generated JPEG fixtures: file and folder opening, thumbnail selection state, arrow navigation, correctly rotated portrait, live wheel zoom, 100% mode, full screen, Info visibility, and continued navigation after an unreadable file.
- Physical trackpad pinch is implemented through AppKit magnification events; the UI automation interface cannot generate a physical pinch gesture. Its shared zoom geometry is covered by the tests.
- Real Lumix S9 RW2 files PS9_2716, PS9_2720, PS9_2721, and PS9_2722 were checked read-only on the connected card. All four contain 1920 × 1280 and 6000 × 4000 embedded JPEGs. The viewer's oriented 4000 × 6000 output matches the decoded full-size camera JPEG exactly (SHA-256 comparison of decoded pixel data), and camera/lens metadata is retained. These files report firmware 1.8; other firmware versions and cameras still need coverage.
- Version 0.1.1 was checked in the native UI with PS9_2716.RW2: correct camera look, matching filmstrip, camera-preview label, 4000 × 6000 dimensions, and 100% inspection.
- Installed version 0.1.2 checked with PS9_2712.RW2: Share button enabled, ⇧⌘S opens the sharing panel, camera-look JPEG prepared successfully (5.2 MB), and native More… picker exposes Messages, AirDrop, and installed extensions. The panel shows explicit browser-upload instructions and has no OAuth account requirement. Google Drive browser handoff reports that nothing has been uploaded. Actual message sending, AirDrop delivery, and website uploads were not performed.
- The real PS9_2712 sharing JPEG matches the extracted camera JPEG byte-for-byte (SHA-256) and decodes to the correctly oriented 4000 × 6000 image. It is kept only in the temporary sharing cache, not the repository.
- Intel Macs and macOS 13–25 have not yet been tested. General RAW development support follows the decoders available in the installed macOS; Panasonic embedded-JPEG extraction is handled directly.

Automated fixtures are generated and contain no user photographs. The real S9 files were read in place and were not copied into the repository. No source photos were modified or uploaded. `scripts/check-photo.swift` can be compiled with the core sources to repeat the local embedded-preview comparison.

## 0.2.0 editor — September 24, 2026

- Release build succeeded and ad-hoc signature verified; installed in `~/Applications/OpenStill.app` (version 0.2.0, build 6).
- 37 Swift tests pass, including exposure/monochrome pixel changes, crop/rotation dimensions, every standard filter, edit-history branching/persistence/source replacement, original/symlink overwrite protection, edited batch sharing, metadata retention, and all previous viewer/Lumix/selection regressions.
- Core Image tests require normal macOS graphics service access. The restricted agent sandbox cannot create the graphics context; tests were rerun outside that sandbox and passed. This does not affect the installed app.
- Local inference smoke-tested all four pinned models. LaMa preserved every unmasked test pixel; SCUNet and Real-ESRGAN produced changed, nonempty output at original dimensions. Test image 256×192: roughly 3.1 s, 0.8 s, and 0.3 s respectively on this Mac. These are smoke timings, not full-resolution benchmarks.
- Sky model tested against its author's public `eval/233129.jpg`: 54.4% mask coverage, unchanged dimensions, 4,763,380 zero-mask pixels preserved exactly. The synthetic replacement was chosen to make mask boundaries obvious, not to assess aesthetic realism.
- Native app verified: exposure updates the canvas and history; Undo returns to Original; drag crop produced 2637×1590 output from 3600×2400; reset crop restores full dimensions; painted local AI removal finishes as a reversible edit; full recorded metadata expands correctly.
- Exported a disposable edited fixture through the native Save panel. Independently reopened JPEG: 3600×2400, Canon EOS R5, RF24-70mm F2.8 L IS USM, ISO 100 preserved.
- Final sidebar visually checked after layout refinement. Reopened real S9 photo read-only: Panasonic DC-S9, MEKE SL 35mmF2.0 STM SE, ISO 800, 35 mm, f/5.6, 1/125 s, camera JPEG 4000×6000. Left app displaying its Tools overview. No edits, uploads, messages, or deletions were performed on user photographs.
- AI runtime installed locally; models verified against pinned SHA-256 digests. Inference uses ONNX Runtime CPU and no network. Full-resolution quality across diverse photos, Intel Macs, older macOS versions, and AI cancellation during package installation remain unvalidated. AI tools are early implementations; masking, fine texture, and replacement lighting require visual review.

## 0.2.1 interface polish — September 24, 2026

- Native behind-window NSVisualEffectView materials added to the window chrome, inspector, and Share panel, with a restrained dark wash. Full-size content coverage keeps title-bar translucency continuous. The canvas remains opaque neutral gray.
- Shared light-weight SF Symbols, aspect-preserving icon drawing, aligned tool icons/titles/chevrons, separate AI indicators, consistent 32-point toolbar/tool rows, 56-point sidebar tabs, hover/selection feedback, and hairline separators.
- Compact thumbnail placeholders and thinner selection borders; toolbar/filmstrip/metadata padding regularized. Tool groups start collapsed for a clean overview.
- Release build and signature verification passed. Native UI visually checked at 1512×950 and approximately 1123×784, including opening a real S9 image and expanding Develop controls. Camera/lens details remain visible. No photograph edits were made during this styling pass.
- This release changes presentation only; image-processing code is unchanged. No new unit tests added for visual styling.

## 0.3.0 selective editing — September 24, 2026

- 48 Swift checks pass: 46 self-contained regressions plus two opt-in local Vision integration checks. The full 47-check suite passed, then the added mask-refinement/sunrays regression passed. Render tests ran with macOS graphics-service access.
- Pixel checks cover monochrome strength, independent Blacks/Whites, signed vignette with unchanged center, selective color bands and neutral preservation, per-feature masks, brush subtraction, radial/inverted masks, source/display coordinate round trips through crop/rotate/flip/straighten, opaque straightening corners, mask/history serialization, identity/malformed .cube files, and legacy vignette/monochrome migration.
- Latest AI-result blend masks remain editable; regression verifies inverting a mask switches between the saved input and AI result. Brush refinement of raster/object masks and dark-pixel preservation under sunrays are tested.
- Apple Vision object selection succeeded on a read-only S9 sample, with foreground/background coverage and selected-center coverage checked. Native UI separately verified on an 800×1200 disposable preview copy: click-to-select produced an aligned car mask and a localized monochrome adjustment. Original RW2 and its existing edit history were not modified by QA.
- Horizon integration: a freely licensed seascape was rotated +7° and Vision returned −7.125°. Native Crop → AI align horizon applied −7.13° and visibly leveled the image without empty corners. Level/synthetic scenes can return no observation; those leave edits unchanged and explain the manual Straighten fallback.
- Native UI verified brush, linear, radial, and AI-object mask creation, cyan overlay toggling, partial monochrome rendering, feather controls, LUT-library selection, and retained edit history. Switching tools/tabs ends active mask drawing.
- Free local .cube LUTs BONBOA, Neagh, and Kitaura downloaded from Ross McConaghy's public creator pages. Native Presets verified all three appear; BONBOA was applied at 70% and changed the photo. Creator LUTs are stored in local Application Support, not redistributed with the app/repository.
- Native radial-mask LaMa erase completed on a disposable 256×192 test image, removed its red rectangle, preserved dimensions, and retained the result's blend mask. Existing AI worker inference remains local. No photos were uploaded or shared.
- New highlight-based sunrays reviewed visually on a landscape at 80% amount/70% length: soft highlight spread, with no synthetic sun disk/starburst. This remains an artistic filter; scene-dependent quality is not guaranteed.
- Release build and installed ad-hoc signature verified. Camera/lens summary and full recorded metadata remain available. Missing metadata now uses compact dashes in the top settings row so Export remains visible.
- Only this Apple Silicon macOS 26.6.2 machine has been exercised. AI object selection requires macOS 14+; physically accurate relighting, arbitrary background-object segmentation, and Apple Photos Clean Up integration are not provided.

## 0.3.1 color and masking workflow — September 24, 2026

- Release build succeeded; installed in `~/Applications/OpenStill.app` (0.3.1, build 9), with ad-hoc signature verified.
- 49 self-contained tests passed; the two opt-in Vision integration tests were skipped on this run. Added checks cover selective HSL lightness, per-color view persistence, legacy decoding, paint strength/softness, gradient refinement, full-distance linear gradients, inversion, and the shared endpoints used by live preview and final rendering. Gradient weights are checked in linear light rather than gamma-encoded screenshot values.
- Native UI verified on disposable `/tmp/OpenStill-QA/Coast-10.jpg`: eight visible color swatches, gradient slider tracks, independent Saturation/HSL choices, retained Aqua hue/lightness after switching colors and restarting, and camera/lens information above the controls.
- Masking now uses Adjustments/Masking tabs and contextual controls. Verified red overlays and brush outline, explicit Paint/Erase modes, Size/Softness/Strength, bracket-key resizing, and erasing a local region while retaining the linear gradient. Back to adjustments hides the overlay and retains the mask.
- Linear drag preview draws directly on the canvas with a red alpha gradient, endpoint boundaries, and a half-strength guide. It shares feather endpoint math with the rendered mask. Native drag creation and the saved red gradient were checked; the automation screenshot captures the completed drag rather than a held intermediate frame. Redrawing a gradient replaces prior brush refinements for that feature. Existing saved gradients retain their feather value; new gradients default to a full-distance fade.
- Expanded tools scroll into view so their controls are easier to reach. Full camera/lens metadata remains available. No user photographs were changed, shared, uploaded, or deleted during these checks.

## 0.4.0 free photography LUT library — September 24, 2026

- Bundled 12 CC0 `.cube` assets from OpenShot revision `9004af74b02c67e507190e9950b5fc690fb0a900`. Verified all 12 individual FreshLUTs creator pages explicitly label the LUT CC0 and free for commercial use. Pinned URLs, creator credits, and hashes are recorded in the catalog; full CC0 text and provenance ship in the app.
- 53 automated tests passed; two opt-in Vision checks were skipped. New checks cover a clean library with no imports, exactly three entries per category, file integrity, malformed/tampered files, 12 distinct renders, imported provenance and legacy name matching, preview replacement rather than stacking, mask/rotation/exposure preservation, zero intensity, undo/redo, PNG export, read-only preview behavior, and stale-generation rejection.
- The release build and installed ad-hoc signature passed. Independently verified all 12 installed asset hashes. App is installed at `~/Applications/OpenStill.app`, version 0.4.0/build 10; the bundled catalog has no runtime network dependency.
- Native UI checked All, Automotive, and Imported; two-column thumbnails use the current photo. Fixed NSButton coordinate flipping found during visual QA and verified upright thumbnails in the final installed app. Applying Teal Punch defaults to 70%, changing intensity creates a separate history step, Undo restores 70%, and relaunch restores the selected LUT. Existing BONBOA, Kitaura, and Neagh imports remain available, with creator provenance.
- Reviewed comparison sheets rendered by the actual Core Image pipeline at 70% on two portraits with different skin tones, red-car and teal S9 car-detail samples, an illuminated night skyline, a coastal landscape, and a night tree scene. Looks are visibly distinct; City Night Film and Woodland Drama intentionally deepen shadows, and Golden Years adds pronounced warmth. No unintended geometric changes or obvious posterization were seen at review size. This is a representative visual check, not a claim of universally accurate skin or paint color. Full-resolution appearance remains scene-dependent.
- QA uses temporary downloaded/licensed samples and existing disposable previews only. No user originals were edited, shared, uploaded, or deleted. Temporary samples and comparison sheets are not bundled. Portrait sources: Pete Souza's public-domain official Obama portrait on Wikimedia Commons; NASA's public-domain Eileen Collins portrait from scikit-image. Additional sources: Wikimedia Commons `Red Ferrari F355 berlinetta.jpg` and public-domain `Downtown skyline at night.jpg`, plus the previously documented landscape fixtures. Comparison sheets remain under `/tmp/OpenStill-LUT-QA`.

## Photographic Glow — 0.5.0 (build 11)

- Added four local Core Image diffusion modes: Glow, Soft Focus, Orton Effect, and Orton Effect Soft. Defaults are Amount 0, Softness 50, neutral advanced controls. Opening the panel does not mutate history; mode switches preserve strength. Optional nested settings keep old edits and portable presets decodable.
- Full suite: 59 tests passed; 2 opt-in Vision integration tests skipped (runner reports 61). Six new Glow tests cover zero-amount exact identity, finite clamping, distinct modes, highlight bloom without distant shadow wash, slider behavior, opaque clean borders, all four mask types, complementary inverted masks through crop/rotate/flip/straighten, scale-consistent preview/export, history and preset roundtrips, legacy decoding, and reset preserving unrelated edits/masks. Existing metadata/original-preservation export test now includes Soft Focus.
- Final targeted run: all 10 Glow/LUT tests passed. The LUT preview replacement/export test now includes Soft Focus and a separate Glow radial mask, proving preview replacement preserves both adjustments and per-feature masks without writing assets/history.
- Native installed-app checks: disabled controls before opening a photo, neutral defaults, all four type choices, expanded advanced controls with bipolar center ticks, Soft Focus retaining Amount 70, red linear gradient with 100% feather, Reset Glow retaining the mask, undo restoring Soft Focus and its mask, saved history entries, camera/lens readout, and switching to an unedited photo immediately after changing Amount correctly restoring that photo's neutral settings. Slider values were exercised via accessibility; physical continuous dragging was not successfully driven by the automation tool and remains a manual acceptance check. The slider uses mouse-tracking to emit a final commit once on release.
- Visual review on disposable portrait copies (Barack Obama/Pete Souza and Eileen Collins/NASA), a public-domain night skyline, a coastal landscape, and a NOAA sunset showed visible diffusion, retained facial detail, preserved dark areas in Glow, and distinct Orton treatments. Comparison sheets are local QA artifacts in `/tmp/OpenStill-Glow-QA`, not bundled. Sunset source: https://commons.wikimedia.org/wiki/File:Sunset_over_an_ocean_(Corp2739).jpg (Commander John Bortniak / NOAA; public domain).
- Forced bitmap rendering at 6000×4000 on this Mac took approximately 0.07–0.14 s for Glow and 0.12–0.15 s for Soft Focus after warm-up; first kernel initialization in an earlier preview was approximately 0.8 s. The 24MP fixture was resized for load testing, not an actual S9 capture. The LUMIX camera volume was not mounted for a full-resolution S9 recheck; existing Panasonic decoding tests passed.
- Source photo copies retained exact SHA-256 equality after native editing. Release built, installed to `~/Applications/OpenStill.app`, strict/deep ad-hoc signature verification passed, and installed/release executable checksums match. The runtime Core Image kernel constructor emits Apple's deprecation warning; it works on the tested Mac, but is a future modernization point. Existing 8-bit sRGB export limits remain.

## Per-tool mask ownership — 0.5.1 (build 12)

- Switching tools/tabs now ends the transient masking session, clears its active owner, drawing mode and overlay, and resets mask-control interaction indicators. Each tool's saved mask stays in its own dictionary entry and is restored only for that tool. Mask status now names the owning tool.
- AI object-selection completions require the originating session token and tool as well as the photo/edit token. Leaving a tool cancels its pending selection, releases the busy state, and discards any late generated mask asset. Overlay completions also verify their current owner and visibility. Escape and history changes end the session too.
- Three new regressions cover stale selections across tool switches (including leaving and returning to the same tool), completion/cancellation ownership, saved-mask persistence, whole-image defaults for a newly used tool, and clearing one tool's mask without changing Glow's mask.
- Full sequential suite passed: 62 executed tests, 2 optional Vision skips (64 reported). An initial parallel run hit the existing LUT asset-folder inventory test's shared-folder race with other image-asset tests; running the suite with `--no-parallel` avoids that fixture interference.
- Native UI verified on `/tmp/OpenStill-Mask-QA/Portrait.jpg`: draw Glow linear gradient, switch to Color, inspect `Color · No mask · Entire photo` with overlay disabled, return to Glow and inspect `Glow · Linear mask` with drawing tools and overlay inactive. Original camera/lens readout remains present.
- Release built and installed in `~/Applications/OpenStill.app`; strict/deep ad-hoc signature verification passed. Version 0.5.1, build 12.

## 0.7.2 Sunrays — September 25, 2026

- Added the eleven controls and four groups documented by Skylum, with a persistent source-placement handle and off-photo coordinates. This is an independent local rendering algorithm; exact Skylum numeric defaults or pixel matching are not claimed.
- 115 automated tests in 21 suites pass using the isolated test-storage script. Five new Sunrays tests cover disabled identity, finite limits, Codable compatibility, each control, deterministic variation, off-photo rays without a visible disk, output bounds/alpha, geometry round trips after crop/rotation/flip/straightening, independent masks, selective batch copying, and preview/full-resolution agreement.
- Native inspection on macOS 26.6.2 / Apple silicon: source placement creates workspace margins; successive drags place the source both beyond the image and back inside without reopening the tool. Escape exits placement. History contains exactly one entry per drag; undo selects the preceding placement. Tested with a separate 24MP JPEG fixture; original bytes are unchanged. Existing test fixture and camera metadata limitations remain as recorded above.
- Softened overly sharp ray lobes after visual review. Existing saved Sunrays render paths remain intact until the new controls are used; no history migration or original-file rewrite occurs.
- Release 0.7.2 (build 16) built and installed with a valid ad-hoc deep signature. No network image processing or additional assets are required.

## Develop essentials — September 25, 2026

- Added Dehaze, Clarity, Texture, Color grading, Grain, Defringe, Whites/Blacks in Develop, Auto tone, a clipping overlay (J) and a before/after split view (Y). These are OpenStill's own algorithms; no Adobe pixel matching is claimed.
- 138 automated tests in 24 suites pass on a GitHub `macos-26` runner (`bash scripts/test.sh`), including 13 new DevelopTools tests: zero-amount identity, sanitizing, edge contrast for Clarity, medium-detail amplitude for Texture, contrast recovery and added haze for Dehaze (legacy and modern renderers), tonal-range tinting for Color grading, deterministic Grain with an unchanged mean, fringe removal that leaves evenly colored areas alone, Auto tone proposals, clipping overlay colors, before-frame geometry, JSON compatibility with older edits, history and batch copying.
- Not yet verified by hand in the native app on a Mac: the Color grading wheel interaction, the split-view divider drag and the J/Y/\ shortcuts.

## Transform, profiles and RAW options — September 25, 2026

- Added Transform (manual perspective sliders, Constrain crop) and Upright Auto, Level, Vertical, Full and Guided, plus Auto straighten from lines. The perspective is composed into the lens-correction coordinate maps, so masks, retouching and the eyedropper follow it.
- Added Profile & calibration: six built-in looks (OpenStill's own), DNG Camera Profile import (hue/saturation map, look table and tone curve; color matrices are not used), profile amount, and red/green/blue primary hue and saturation with a shadows tint.
- Added RAW decoding options: demosaic method and LibRaw's wavelet, median and FBDD noise reduction.
- Automated tests: new TransformTests and CameraProfileTests suites cover identity at defaults, sanitizing, JSON compatibility, orientation and homography round trips, constrained crops without empty edges, rendered pixels matching point mapping in all four orientations, Newton inversion of the optics, masks following the perspective, Upright solving for converging verticals, level and guided lines, line detection on a synthetic photo, neutral-preserving calibration, each built-in look, DCP parsing and application, RAW options reaching the decode recipe, portable packages carrying imported profiles, and batch copying.
- Not yet verified by hand in the native app on a Mac: Guided line drawing, the Upright buttons on real architecture photos, DCP import with a real camera profile, and the RAW decoding popups on a RAW file.

## Library catalog — September 26, 2026

- Added a local SQLite catalog, with fast lookup of unchanged files by path, size and modification date and a one-time index of existing records. Also added Include subfolders, color labels (6–9), IPTC metadata editing with hierarchical keywords, metadata presets, batch apply, IPTC in exports, collections, smart collections, metadata search and a disk preview cache.
- Automated tests: the new LibraryCatalogTests suite covers:
  - indexing and fast lookup, moved and changed files, and one-time migration of existing records;
  - mirroring of ratings, flags, labels and metadata into the catalog;
  - metadata sanitizing and loading records saved before this version;
  - free-text search and every smart-rule field;
  - collections and smart collections, with rename and delete;
  - subfolder scanning that skips hidden folders;
  - IPTC fields read back from an exported JPEG;
  - preview cache replacement;
  - library filtering by label and keyword.
- Not yet verified by hand in the native app on a Mac: the label keys, the metadata window, the collection sidebar, the smart collection editor, and first-launch indexing of a large existing library.

## XMP sidecars and Lightroom import — September 26, 2026

- Added:
  - XMP sidecar reading (on first open and on demand) and writing, with an automatic-write preference; unknown tags and Camera Raw settings are kept;
  - Camera Raw (`crs:`) develop settings import as a new version, with a report of what isn't carried over;
  - Lightroom Classic catalog import (read-only), covering ratings, picks, labels, hierarchical keywords, metadata, collections and develop settings, with relinking of moved folders.
- Automated tests: the new XMPImportTests suite covers:
  - a round trip of every library field through XMP, including hierarchical keywords and alternative-language text;
  - preserving Camera Raw settings and other tags when writing, and removing cleared fields;
  - Bridge's reject rating and unknown label names;
  - reading sidecars into new records, and writing them only when the preference is on and a library field changed;
  - the mapping of about 30 Camera Raw settings, relative and absolute white balance, and unsupported-setting reports;
  - import of a Lightroom catalog built by the test (keyword tree, picks, labels, virtual copies, smart collections and sets, missing photos, relink), which leaves the catalog file unmodified, and running the same import twice.
- Not yet verified by hand on a Mac: a real Lightroom Classic catalog and Camera Raw sidecars from recent Lightroom versions. How close imported develop settings look to Lightroom's rendering has not been checked.

## Import and duplicates — September 26, 2026

- Added:
  - card and folder import, with detection of photos already imported (size + SHA-256);
  - folder and name templates, and verified copies that never overwrite;
  - an optional verified backup copy and copying of sidecars;
  - metadata, keyword and develop presets applied on import, and ejecting the card;
  - exact and similar duplicate finding (Vision feature prints), with the extras flagged as rejects.
- Automated tests: the new PhotoImportTests suite covers:
  - template expansion and rejection of invalid names;
  - a full import from a nested card layout (duplicate file names, a sidecar, a hidden file, a backup, metadata and a develop preset);
  - that the source is unchanged, no partial files are left behind, and re-importing skips everything;
  - that copies never overwrite, and that cancelling keeps finished copies;
  - exact duplicates from files and from the catalog, and choosing the best copy;
  - similar-photo grouping.
- Not yet verified by hand on a Mac: a real camera card (mounting, ejecting, large RAW files), and similar-photo grouping on real bursts.

## AI masks, Lens blur and AI worker — September 26, 2026

- Added:
  - Vision mask components: subject, background, people, person 1–4, face, eyes, eyebrows, lips and skin;
  - worker sky masks, depth maps (Depth Anything V2 Small) and depth-range mask components;
  - the Lens blur tool, with the photo's depth data, an AI estimate or the subject as the depth source;
  - feathered tile blending, 2× super resolution as a new version, and RAW-stage denoise that keeps edits live;
  - a prompt to run setup again when a new model is needed.
- Automated tests:
  - The new AIMaskTests suite covers:
    - depth-range coverage, inversion, and following rotation;
    - Lens blur sharpness inside and outside the focus band, and identity at zero;
    - Lens blur in the pipeline and in saved edits, and sanitizing;
    - convex hull, depth stretching and the skin-tone range;
    - "nothing found" on empty photos, and JPEGs without depth data;
    - RAW denoise keeping edits and relative white balance.
  - `Tests/AI/test_worker.py` checks the worker with stand-in models:
    - identical output from tiling;
    - no seams under per-tile differences;
    - 2× output size and content;
    - depth stretching and sky-mask placement;
    - the float file round trip.
- Not yet verified by hand on a Mac: Vision masks on real portraits and groups, Lens blur on iPhone Portrait photos, and the downloaded depth, sky and Real-ESRGAN models producing good results in the app.


## HDR and merges — September 26, 2026

- Added:
  - HDR editing (Edit in HDR, highlight headroom) with an extended-range preview on HDR displays;
  - HEIF export, and HDR export as 10-bit PQ or HLG HEIF, or SDR with an HDR gain map (macOS 15);
  - Merge to HDR with alignment and deghosting, Merge to panorama (cylindrical or perspective, auto crop) and Focus stack, written as float TIFFs next to the originals.
- Automated tests:
  - HDRTests:
    - highlight expansion and the SDR tone map;
    - sanitizing, the pipeline with HDR on and off, the SDR rendition of a recipe, legacy decoding;
    - export settings (which formats allow which HDR modes), old presets, `.heic` names;
    - PQ HEIF bit depth, SDR HEIF, and a gain map in a JPEG (macOS 15).
  - MergeTests:
    - HDR merge recovering clipped highlights and shadows, and deghosting;
    - alignment of a shifted and of a rotated frame (OpenStill's own search, no Vision);
    - a three-frame panorama, and refusing frames that don't overlap;
    - focus stacking keeping the sharp half of each frame;
    - largest covered rectangle, cylindrical projection, output names, float TIFF values above white.
- Not yet verified by hand on a Mac: the HDR preview on an XDR display, HDR exports viewed on HDR screens, and merges of real hand-held brackets, panoramas and focus stacks.

## Print, slideshow, web gallery and publish — September 26, 2026

- Added:
  - Print (single, contact sheet, custom grid) to the print dialog, PDF or JPEG, with print sharpening, resolution and RGB printer profiles;
  - full-screen slideshows with transitions, slow zoom, music, and H.264 video export;
  - self-contained web galleries (grid and lightbox);
  - publish collections for a folder, Flickr and SmugMug, with new/modified/published tracking and keychain sign-in.
- Automated tests (OutputTests):
  - page cells, fitting, pagination, orientation, sanitizing;
  - a two-page PDF and JPEG pages with the photo and white paper where expected;
  - print sharpening and scaling to the printed size;
  - a gallery with escaped titles, numbered images and thumbnails, no outside resources, and rebuilds replacing images;
  - slideshow frames: pillarboxing, crossfade, fade through black, cut, no fade after the last slide;
  - video export with the right size, length and looped music;
  - the OAuth 1.0 specification's example signature and header encoding;
  - collection state (new, published, modified, pending removal) and saving;
  - folder publishing that replaces edited photos and removes ones taken out.
- Not yet verified by hand on a Mac: printing to a real printer, slideshow playback on a display, and Flickr/SmugMug with real accounts.

## People, map, timeline and tethered capture — September 27, 2026

- Added:
  - face detection (Vision) with local grouping, naming, suggestions and "not this person", stored in the catalog, with `People > Name` keywords;
  - a map of photo locations with drag-to-place, draggable pins and GPX track matching (the file's time zone, or a chosen one plus a clock correction);
  - locations saved with the photo record, mirrored to the catalog, written to XMP (`exif:GPSLatitude`/`GPSLongitude`) and to exports that keep GPS;
  - a year/month/day timeline;
  - tethered capture with ImageCaptureCore into a numbered session folder, with metadata and develop presets, opening each shot.
- Automated tests (PlacesPeopleTests):
  - location validation, distance, EXIF GPS and XMP coordinate round trips;
  - capture times with and without EXIF time-zone offsets;
  - GPX parsing (namespaces, fractional seconds, bad points), interpolation, the ends of the track, gaps, the date line, and matching with a time zone and a clock correction;
  - geotags reaching the catalog, XMP and exports (and not exports without Keep GPS), and old records without a location still loading;
  - timeline grouping across a year boundary, undated photos, ordering;
  - face grouping of synthetic descriptions, and catalog storage: groups, naming, suggestions, rejections, rescans keeping names, deleting people, removing photos;
  - People keywords following names and renames;
  - no faces in a plain image;
  - session folder and file naming, and presets applied to tethered shots.
- Not yet verified by hand on a Mac:
  - face grouping quality on real portraits;
  - the MapKit window;
  - tethering with a real camera.

## Performance — September 27, 2026

- **Changed:**
  - Shared Metal-backed Core Image contexts, with no throwaway contexts.
  - Accelerate for the RAW RGB→RGBA expansion, float un/premultiplication and face distances.
  - Batch catalog indexing and a capture-date index.
  - The library reads capture dates from the catalog.
  - The library filter skips text matching when there's no search.
  - Two thumbnail renders at a time on Macs with 8 or more cores.
- **Automated tests (PerformanceTests):**
  - A 50,000-photo catalog: indexing, reading, text search, smart rules, keyword counts, timeline, lookups by file, fetching by ID, and the library filter and sort by date and by name, each with a time limit.
  - Grouping 5,000 faces of 50 people.
  - Pixel conversions matching the simple loops, including NaN rejection and huge values.
  - Renders reusing the shared contexts.
- **Not done:** moving the Core Image kernels to precompiled Metal, and an MTKView canvas (see README → Performance).

## Layouts and customizable shortcuts — September 27, 2026

- **Added:**
  - A Lightroom Classic layout alongside the Luminar Neo one, chosen in Settings → Layout (with illustrated cards) or from the View menu, and remembered.
  - Every menu command and single-key shortcut can be changed in Settings → Shortcuts: a searchable list with a keycap-style recorder, conflict prompts, per-command reset and Restore All Defaults.
  - Settings is now in three tabs: General, Layout and Shortcuts.
- **Automated tests (ShortcutTests):**
  - Key combos: display, spoken form, text form and JSON round trip, including rejected input.
  - Saving, reloading, removing and resetting shortcuts.
  - Conflicts, including the ⌘O→⌘P example and single-key scopes.
  - Looking up a key press in the library and on the photo.
  - Search by name, group or keys.
  - The layout choice being remembered.
- **Not yet verified by hand on a Mac:**
  - Both layouts in the library and while editing.
  - Recording shortcuts, including ⌘ combos that already belong to a menu.

## Lightroom Classic layout, rebuilt — September 27, 2026

- **Added (Lightroom Classic layout only):**
  - Module picker: Library | Develop | Map | Slideshow | Print | Web.
  - Navigator, with FIT / 100% / 200% and click-to-move.
  - Collapsible panels in Lightroom's order and names, with solo mode and Expand / Collapse All.
  - Develop's Crop / Remove / Masking tool strip; the Masking drawer picks which adjustment the mask limits.
  - Library's Histogram, Keywording and Metadata follow the grid selection.
  - Bottom buttons: Import… / Export…, Copy… / Paste, Previous / Reset, Sync Metadata… / Sync Settings….
  - The filmstrip bar with source info, the filmstrip in Library too, the Develop toolbar, and the edge triangles.
  - Lights Out, flat dark-gray panels, no window toolbar.
  - Workspace keys G, D, R, Q, Shift-W, L, T, Tab and Shift-Tab (changeable in Settings), and the Window menu's F5–F8 and ⌥⌘3/5/6/7.
  - Previous also works from the Luminar layout's editing commands.
- **Automated tests (LightroomWorkspaceTests):**
  - The module list.
  - Tab and Shift-Tab panel toggling.
  - Solo mode.
  - Saving and reloading panel state, including corrupt data.
  - The Lights Out cycle.
  - Workspace key conflicts with library and photo keys.
  - Previous copying settings without crop.
- **Not yet verified by hand on a Mac:**
  - Every panel with a real photo, in both modules.
  - Switching layouts back and forth.
  - Crop / Masking drawers, Lights Out, Sync and Copy / Paste.
  - Panel memory after relaunching.

## Lightroom layout drawing fix — September 27, 2026

- **Fixed:** in 0.0.6 the Lightroom Classic layout showed an empty gray window with only the edge triangles and the toolbar. Since macOS 14, views don't clip their drawing to their own frame, and the flat panel background filled the whole area being redrawn, painting over everything. It now fills only its own frame and clips.
- **Fixed:** the Navigator stretched and squeezed Develop's Presets, Versions and History out of the left panel. It now keeps its own height.
- **Verified on macOS 26 CI:** the app was launched with sample photos and snapshots were taken of Lightroom Develop and Library. They show the module picker, Navigator, left and right panels, photo, toolbar and filmstrip.
- **Known:** the Library histogram stays empty until that photo's grid preview has been saved.

## Develop: curves, Point Color, detail and more — September 27, 2026

- **Added:**
  - Point tone curves (RGB, Red, Green, Blue) and the parametric curve, with targeted adjustment.
  - Point Color, with targeted adjustment for HSL / Color.
  - B&W mix with Auto mix.
  - Sharpening Radius / Detail / Masking; noise reduction Detail / Contrast and Color / Color detail.
  - Remove chromatic aberration, measured per photo.
  - Red eye and Pet eye.
  - Visualize spots.
  - Snapshots.
  - Camera Raw import of point curves, parametric curves, the gray mixer and the detail sliders.
- **Automated tests (DevelopM11Tests):**
  - Point curves pass through their points, stay flat outside them and don't overshoot; the parametric curve stays monotonic.
  - Old five-point curves still decode and render as before.
  - The B&W mix changes each color's gray; Point Color moves nearby colors and leaves grays alone.
  - Sharpening steepens edges and Masking leaves flat areas alone; old edits keep the original sharpening until a Detail slider changes.
  - Chromatic aberration measurement finds a synthetic red / blue scale error.
  - Red eye darkens a red pupil.
  - Visualize spots shows edges.
  - Snapshots add, rename, restore as one undo step and delete.
  - Batch copy carries the new settings.
  - Camera Raw import reads them.
- **Not yet verified by hand on a Mac:**
  - Adding and dragging curve points.
  - Sampling a Point Color from a real photo.
  - Red eye on a portrait.
  - Targeted adjustment drags.
  - Restoring a snapshot.

## Library: views, filter bar, stacks, Quick Develop, keywords, rename, Auto Import — September 27, 2026

- **Added:**
  - Library views: Loupe, Compare and Survey.
  - A thumbnail size slider.
  - Metadata filter columns with counts.
  - Stacks (manual and by capture time).
  - The Quick Develop panel.
  - Keyword Sets with ⌥1–9, and keyword suggestions.
  - The Keyword List.
  - The Painter.
  - Rename Photos (F2) with undo.
  - Auto Import from a watched folder.
  - The Reference View window.
- **Automated tests (LibraryM12Tests):**
  - Stacks group, reorder and break up, and a stack left with one photo goes away.
  - Closed stacks show their top photo and open ones show all of them.
  - Auto-stack groups bursts.
  - Metadata columns count and narrow each other.
  - Quick Develop nudges, clamps and undoes as a batch.
  - The keyword tree lists every level.
  - Suggestions come from co-occurring keywords, and Recent Keywords are tracked.
  - Rename moves the files and sidecars, updates records and the catalog, refuses clashes, and undoes.
  - Auto Import waits for files to settle, moves only top-level photos, and refuses a destination inside the watched folder.
- **UI snapshots on macOS 26 CI:** Grid with the filter bar, Quick Develop and Keywording; Loupe; Compare; Survey; Develop.
- **Not yet verified by hand on a Mac:**
  - Dragging the Painter across photos.
  - Opening a stack with S.
  - A rename and its undo in a real folder.
  - Auto Import with a real tethering app.
  - ⌥1–9 keyword sets.

## Workflow: Edit In, after export, Smart Previews, catalog, Book and more — September 27, 2026

- **Added:**
  - Edit In another app.
  - After-export actions: Finder, an app, or a script.
  - Smart Previews for photos on disconnected drives.
  - Catalog backups (manual and on quit).
  - Export and import as catalog, and moving the catalog folder.
  - The Secondary Display window.
  - The Book module with PDF output.
  - Auto Sync.
  - Adaptive presets (subject, background, sky).
  - A custom identity plate.
- **Automated tests (WorkflowM13Tests):**
  - Edit In renders a TIFF copy with a unique name, carries the rating and stacks it on top.
  - After-export scripts get the files, and settings from before the option existed still load.
  - A Smart Preview stands in for a missing original: the record is found, and it renders and edits.
  - Backups are dated and pruned, and the backup copy of the catalog opens.
  - The schedule decides when a backup is due.
  - Export as Catalog round-trips edits.
  - Book pages lay out inside the page and save a PDF with the right page count.
  - Auto Sync copies only what changed.
  - Adaptive presets set their tools and masks, with the background inverted.
  - Book is a module, and the catalog location is remembered.
- **Not yet verified by hand on a Mac:**
  - Edit In round trip with Photoshop or Affinity.
  - Editing with the drive ejected.
  - Book PDF on paper.
  - Secondary Display on a second monitor.
  - Auto Sync with a filmstrip selection.
  - Sky presets with local AI installed.


## Mask layers, Return closes tools, Smart Contrast, Delete to Trash — September 27, 2026

- **Added / fixed:**
  - Mask layers: any number of masks, each with its own 14 sliders; rename, duplicate, invert, hide and delete. Per-tool masks still work.
  - Return (or Done) finishes Crop, Remove, Red Eye and Masking and closes the panel completely; Escape closes it too.
  - Smart Contrast replaces the plain contrast curve for new edits; older edits keep their look until Contrast is moved.
  - Temperature and Tint on rendered photos went the wrong way (higher Temperature cooled a JPEG). They now match RAW; older edits keep their look until Temperature or Tint is moved.
  - Mask Temperature and Tint go the same way as Lightroom's; lowering Smart Contrast no longer lifts deep blacks.
  - Tall tool drawers scroll instead of stretching the window; an empty tool mask no longer shows blank component controls; Return in Crop without a frame leaves Crop.
  - The Luminar Neo layout is now called the EZ Layout.
  - The stars under library thumbnails can be clicked to rate that photo; clicking the current rating clears it.
  - haon-v2/OpenStill#16: Delete then Return moves the photo to Trash (Move to Trash is the default button, Escape cancels). Delete in the library grid trashes the selected photos after the same confirmation.
- **Automated tests (MasksContrastM14Tests):**
  - Mask layers add, duplicate and remove with their masks, sanitize their sliders, and round-trip; older edits decode with none.
  - Two layers change only their own areas; hidden, neutral and unmasked layers do nothing.
  - Layer sliders render (exposure, saturation, temperature).
  - Batch copies layers only when masks are copied.
  - Smart Contrast is neutral at 1, never clips or reverses a ramp, keeps hue, and pivots on the photo's brightness.
  - Temperature warms and Tint adds magenta once corrected; older edits keep the reversed look until Temperature or Tint changes.
  - Older edits keep the legacy contrast until Contrast changes; Quick Develop contrast switches to Smart Contrast.
- **UI snapshots on macOS 26 CI:** each Lightroom tool drawer open, after Return and after Escape; two mask layers; the EZ Layout Masks tool before and after Return (checked from the app's state, since glass panels don't render in CI snapshots); the library. The window keeps its size with every drawer open.
- **Not yet verified by hand on a Mac:**
  - Painting a brush mask layer on a real photo.
  - Delete then Return in the Library grid with several photos selected.

## Logo designer modes and prompt — September 27, 2026

- **Changed:**
  - The watermark logo designer has three separate modes: **Design your own** (manual, no AI), **Generate with AI** (a multi-line prompt, the optional local model, **Edit in Design your own**) and **Import**.
  - The identity plate can use a saved logo (**Use Saved Logo**).
- **Automated tests (LogoPromptTests):** the prompt reaches the model as data and is limited to 500 characters; the instructions keep the exact name and tagline in OpenStill's hands; bad model output is refused.
- **Not yet verified by hand on a Mac:** generating with a prompt using the local model; Use Saved Logo on the identity plate.

## Tone sliders, G / D keys, right-click menu, import locations, faster RAF — September 28, 2026

- **Fixed:**
  - **Highlights ran backwards.** Highlights and Shadows are now −100…+100 sliders centred at 0, like Lightroom's. Lowering Highlights recovers bright areas without greying them; raising it brightens them. Shadows mirrors it. They use a new tone kernel. Photos edited before keep their look until one of the two sliders moves. Quick Develop, Auto Tone, presets, Auto Sync, mask layers and Camera Raw import (`Highlights2012` / `Shadows2012`) use the same scale.
  - **G then D stopped responding.** The workspace keys (G, D, R, Q, Shift-W, L, T, Tab) now work anywhere in the main window, not only when the photo, filmstrip or grid has focus. Text fields keep their keys. Showing the Library also focuses the grid.
- **Added:**
  - A right-click menu on the library grid, the filmstrip and the photo: Open in Develop, **Open With ▸**, **Edit In ▸**, Show in Finder, **Show in Folder**, rating, flag, label, Share and Move to Trash.
  - After a Lightroom catalog import, the folders your photos are in, with Show in Finder and Show in Library. A normal import names the folders it copied to.
  - **Faster RAF:** the camera's embedded preview shows while a RAW file develops; Fuji X-Trans uses the one-pass demosaic on screen, and three-pass for exports.
- **Automated tests:** ToneRegionsTests (recover and brighten on a ramp without reversing, monotonic, darker half untouched, shadows mirror, hue kept, centred sliders, older edits unchanged, adoption, JSON round-trip, sanitizing, Quick Develop, Camera Raw); ImportFoldersTests (folder list and grouping); XMPImportTests updated.
- **Not yet verified by hand on a Mac:** RAF timings on real X-Trans files; Open With with several apps installed; G / D after clicking in a side panel.

## One layout, Develop order, Folders, import modes — September 28, 2026

- **Changed:**
  - **One layout.** The EZ Layout is gone, and so are Settings → Layout and View → Lightroom Classic Layout / EZ Layout (⌃⌘1 / ⌃⌘2). A saved EZ Layout choice is ignored. With it goes the catalog controls shown three times (left, right and top) in that layout.
  - **Develop's right panel, in Lightroom's order:** Basic with the **Profile first**, Tone Curve, HSL / Color, B&W Mix, Color Grading, Detail (sharpening, noise, chromatic aberration, defringe, AI enhance), **Geometry** (Crop & Straighten, Lens Corrections, Transform), **Effects** (vignetting, grain, **Lens Blur**, Glow, Sunrays, Structure) and Calibration, then Sky Replacement, Layers and On-Device AI. Only Basic starts open.
  - **On-device AI** replaces "local AI tools" in every label and message, with a plain explanation: optional, about 450 MB once, runs only on this Mac. (One message said 350 MB; the models add up to about 450 MB.)
  - **Secondary windows** (Import, Export, Metadata, Duplicates…) are flat panels instead of a floating glass card.
- **Added:**
  - **Folders like Lightroom's:** drives (startup disk first, external drives dimmed when not connected), then the library's folders with photo counts, expandable. Right-click a folder: Show in Finder, Import to This Folder…, Synchronize Folder, Expand / Collapse.
  - **Import: Copy / Move / Add.** Move renames on the same drive; across drives it verifies each copy and only then puts the original in the Trash. Add leaves photos where they are. From a camera card only Copy is offered.
  - README: a table comparing OpenStill's catalog with Lightroom Classic's, with what's still missing (missing-file badges, virtual copies as grid thumbnails, removing deleted photos on Synchronize, Find Missing Folder, collection sets).
- **Automated tests:** FolderTreeTests (drives first, skipped single-folder chains, counts, offline drives, Finder-style sorting); ImportModeTests (Add leaves files untouched and applies metadata, Move takes photos and sidecars, settings saved before modes default to Copy); ShortcutTests checks a saved EZ Layout choice is ignored.
- **Not yet verified by hand on a Mac:** Move from an external drive to the startup disk (Trash step); Folders with thousands of folders; Import to This Folder from the Folders menu.

## Studio layout — September 29, 2026

- **Changed:** the window is redesigned after the photo editor Compositor. It replaces the Lightroom-style chrome of 0.0.14 and keeps every editing feature and key.
  - A toolbar with Library | Develop, **photo tabs** (up to 12, remembered per catalog; a dot marks edits), Fit / 100% / zoom, Presets, History, Share and Export.
  - A **tool rail**: Adjust, Crop, Remove, Red Eye, Masking, White Balance, Targeted, Before / After and Clipping in Develop; Grid, Loupe, Compare, Survey, Painter, People, Map and Timeline in the Library.
  - A fixed-height **tool options bar** with only the current tool's settings. When the window is narrow, the last settings step aside and Cancel / Done always stay.
  - One **right panel** that you can resize (240–420 points). The Library's Folders, Collections and Info are tabs in it.
  - A **status line** with zoom, size, file, rating and position, the current tool's keys, and OpenStill's messages. These were previously written into a note nobody could see.
  - **Floating panels** for Presets & LUTs (Shift-P), History / Snapshots / Versions (H), Info and the Navigator. They remember where you put them.
  - Sliders: drag a slider's name to scrub it, double-click it to reset, or use the arrow keys in its field. Temp, Tint, Vibrance, Saturation and the tone sliders show colored tracks.
  - New keys: A (Adjust), W (white balance picker), H, Shift-P, K (Painter). F6 / F7 / F8 show the filmstrip, tool rail and right panel.
  - The Library grid's columns now fill the width instead of leaving a gap.
- **Removed:** code the new layout no longer used. That covers the standalone Library window, a hidden copy of every Develop control that was refreshed on each edit, the old sidebar layout, and old button and toolbar classes (about 570 lines).
- **Automated tests:** StudioLayoutTests covers photo tabs (open, switch, close, the 12-tab limit and which tab closes, edits, renames, missing files, per-catalog memory), the panel layout (width limits, toggles, carrying over the old panel choices) and the tool list (symbols, hints, keys). ShortcutTests, FolderTreeTests and ImportModeTests were rerun. The full suite passes: 290 tests.
- **Verified on macOS 26 CI:** window captures of these screens were reviewed:
  - the empty window and Develop;
  - each tool's options bar and the masks list with two masks;
  - the Library with each tab and Compare;
  - the filmstrip, Lights Out and Tab hiding the panels;
  - both floating panels.
  
  Real key presses G, D, R, Return, Q, Esc, Shift-W, Return, T, T, Tab, Tab and A each switched to the expected tool or panel.
- **Not yet verified by hand on a Mac:** dragging the panel edge; scrubbing a slider's name with a trackpad; photo tabs after renaming files in Finder; floating panels across two displays.

## Editing speed and sliders — September 29, 2026

- **Changed:** Develop renders the way Lightroom does, at the size the photo is shown on screen.
  - While a slider moves, the photo updates continuously with lighter frames. Only the newest change is rendered, one at a time. Before, each movement cancelled the pending render, so the photo waited until you paused.
  - Letting go renders the full-quality frame. The histogram, mask overlay and split view update then too.
  - Zooming to 100% renders only the visible part in full detail.
  - RAW photos keep a screen-sized half-float copy in a render cache on disk (10 GB by default), so going back to a photo skips decoding the RAW again. Other photos open from a screen-sized preview and decode the full image only when needed.
  - The decode cache is sized from the Mac's memory, and a larger decode serves smaller requests.
  - Measurements that don't change while you drag are computed once: the Smart Contrast midpoint, Auto analysis, brush masks and AI mask images.
  - The photo is shown by a GPU layer; the canvas draws only its overlays.
  - Core Image compiles the Develop kernels in the background at launch.
  - Saving waits for a burst of changes to end and writes the record once. It's flushed before switching photos, going to the Library, or quitting.
  - LUT thumbnails render only while Presets & LUTs is open.
- **Sliders:**
  - One slider class replaces three.
  - A click without moving doesn't add a history step.
  - Colored tracks follow the slider, not its title, so the three Calibration "Saturation" sliders each get their own color.
  - A change that's refused (while AI is running) puts the slider back.
  - Slider fills use the accent color.
- **Automated tests:** RenderSpeedTests covers:
  - a 24 MP benchmark (full size, the screen-size copy, a 100% region);
  - the preview and lazy full image;
  - decode reuse;
  - shared Smart Contrast measurements and stable cache keys;
  - brush stroke keys;
  - the size-limited cache;
  - 2,000 preview writes;
  - one record decode per save.

  The full suite passes: 298 tests.
- **Measured on macOS 26 CI** (a 24 MP photo, a small CI GPU):
  - Full-size render, which 0.0.15 did on every slider release: 0.75 s.
  - From the screen-size copy: 0.22 s.
  - While dragging, in the real window: each frame renders in 11–60 ms.
  - First frame of a drag: 0.29 s for Exposure and 0.40 s for Contrast. Before the kernel warm-up, Contrast's first frame took 1.6 s, and 0.0.15 showed no frames at all until you paused.
- **Not yet verified by hand on a Mac:** 40 MP RAW files from several cameras; the render cache filling past its limit; a Pro Display XDR in HDR mode.

## Settings, dark windows, every window tested — September 29, 2026

- **Changed:**
  - Settings is redesigned in the Studio style: always dark, a sidebar of sections (General, Editing & Performance, Library & Catalog, Auto Import, Shortcuts) and grouped rows with a label on the left and the control on the right.
  - Catalog Settings and Auto Import Settings are now Settings sections instead of separate dialogs, and their menu items open them.
  - New in Settings: the render cache size with how much it uses and Clear Cache, the GPU and HDR availability, the catalog location with Show / Change…, and Back Up Now.
  - The whole app is always dark, including Export, Import, Metadata, Book, Print, Slideshow, Web Gallery, Map, People, Timeline, Tethered Capture, the logo designer, alerts and sheets.
  - The output windows keep their form rows together instead of spreading them over the window.
- **Fixed:** found while testing every window:
  - Loupe, Compare, Survey and Reference showed no photo in 0.0.16. This was also released on its own as 0.0.17.
  - The Settings row notes could be cut off.
- **Removed:** unused code:
  - EditorPanel's always-hidden header, and the glass panel code (only the flat color was used);
  - `LRColors`, merged into the Studio colors;
  - the separate Catalog Settings dialog and Auto Import window;
  - `Appearance.glass()` and `line(in:)`, an unused person-count helper, and the Settings tab API.
- **Verified on macOS 26 CI:** captures of every window and panel were reviewed:
  - each Settings section;
  - Library grid, Loupe, Compare and Survey;
  - People, Timeline, Metadata, Rename, Export, Import;
  - Map, Book, Slideshow, Print, Web Gallery;
  - Identity Plate, Reference, Tethered Capture;
  - Presets, History, Info and Navigator panels;
  - Crop and Masking;
  - a 900-point-wide window and the empty window.

  The build and test suites pass.
- **Not yet verified by hand on a Mac:** changing the catalog location and relaunching; Clear Cache while a RAW photo is open.

## Presets and LUT library — September 29, 2026
- **Added:**
  - A library of 420 free LUT tables (about 250 looks once film strengths are grouped) in one 18.5 MB pack, replacing the 12 loose `.cube` files:
    - 293 RawTherapee Film Simulation tables (CC BY-SA 4.0), under descriptive names, with −1 / Normal / +1 / +2 strengths grouped per look;
    - 50 FreshLUTs community looks (CC0), including the 12 shipped before, with the same ids;
    - 77 OpenStill Originals (CC0) generated from `Resources/LUTs/originals.json`.
  - 82 presets in 13 categories, including the six earlier presets with identical results; Amount 0–200%; My Presets (save, rename, delete, import, export).
  - A Presets | LUTs browser: category menu with counts, search, favorites, recent, a strength menu for film looks, and thumbnails rendered only for visible cards.
- **Kept working:**
  - Looks already applied to photos (they are copies in the photo's assets).
  - Saved edits that name one of the original 12 looks.
  - `.openstillpreset` files saved by earlier versions (Import preset…, and develop presets in Import and Tethered Capture).
  - Version 1 LUT catalogs and imported `.cube` files.
- **Tests:** `LUTLibraryTests` (every look decodes and matches its checksum, licenses and credits, the 12 old ids, the neutral look is an identity within 1/255, black-and-white originals stay gray, tampering is refused, version 1 catalogs, search and strengths, preview equals applied result) and `PresetLibraryTests` (bundled presets are valid and their looks exist, the six old presets give the same edits, Amount 0 / 100 / 200%, photo-specific edits are kept, looks are applied as copies, My Presets round trip and old files).
- **Skies (added on request):** 30 CC0 Poly Haven skies in six categories. The on-device sky AI makes the photo's "Sky" mask the first time; the sky is composited live and **Relight scene** carries its brightness and color into the land (dark skies darken it, sunsets warm it). Also Horizon, Sky exposure, Defocus, Atmosphere, Flip, Remove, Your Skies, and Refine sky selection with the mask tools. Presets keep the sky. `SkyReplacementTests` cover the composite through the mask, dark skies darkening and sunsets warming the land, relight 0 leaving it, no mask meaning no sky, sanitizing and saving, presets keeping it, and the library and Your Skies. The old baked "Choose sky & replace…" is replaced; photos edited with it keep their result.
- **Not included:** previewing a look on the main photo while hovering its card; the card thumbnails show each look on the current photo instead.

## AI assistants (OpenStill MCP) — September 30, 2026
- **Added:** Settings → **AI Assistant**: install, update and uninstall OpenStill MCP (checksum-verified download), connect Claude Desktop (with a backup of its settings) or copy the Claude Code command, **Allow AI assistants to edit** (off by default), the largest preview size, and Recent AI actions.
- **How it stays in sync:** the MCP talks to OpenStill over an owner-only local socket; OpenStill makes every change through the same path as its sliders, so AI edits appear live, are one undo step each, and are saved like any edit.
- **Works with this release's libraries:** `list_luts` / `apply_lut` cover the whole LUT pack by display name; `apply_preset` accepts any preset name from the Presets panel; LUTs the AI imports appear under **Found by AI** with their license.
- **Automated tests (AssistantTests):** message framing and the protocol version check; slider values sanitized (NaN, out of range); `import_lut` refuses non-https links, missing licenses, oversized files, zip path tricks and bad `.cube` files; provenance is recorded; the Claude Desktop settings edit keeps other entries.
- **Not yet verified by hand on a Mac:** a full session from Claude Desktop (install, connect, edit, undo).

## AI assistant masking — September 30, 2026
- **Fixed:** linear masks added by the AI were reversed (asking for the top selected the bottom). AI selections (subject, sky, background, people) are now waited for; when nothing is found, no empty layer is left and the reason is given.
- **Added for the AI:** every mask answer shows the photo with the layer's area in red beside the selection alone, with coverage and bounds; `list_mask_layers`, `preview_mask`, `update_mask_layer` (sliders, name, hidden, invert, move/resize), `delete_mask_layer`; `preview` with `compare` (before | after).
- **Checked on CI in the built app** (sample photo): radial added in the center, moved to the top-left; linear from the top selects the top 20–40%; invert; subject with nothing to find adds nothing; sky without on-device AI explains the setup; delete; before/after. The images were reviewed.
- **Tests (AssistantTests):** selection stats (coverage, bounds, empty), reshaping keeps size/feather/invert, slider updates merge, layer descriptions with shapes, the linear gradient's direction.
- **Not yet verified by hand:** a session from Claude Desktop with OpenStill MCP 1.1.0; subject and sky selections on real photos.

## AI assistant: full editing and copy/paste settings — September 30, 2026
- **Added for the AI:** `get_edits` (the whole edit, every Develop section shown), `edit` (JSON merge patch: one undo step, values limited like the sliders, unknown keys / wrong types / invented files refused with the path named, changes and limited values reported), `edit_reference` (every field's meaning and range; a test fails if a field is missing), `run_command` (Develop's buttons, waiting for them to finish), `copy_edits` (Copy / Paste Settings by section), `list_presets`, `list_skies`.
- **Checked on CI in the built app** (sample photos): one `edit` set glow, grain, point color, color grading, a parametric curve and a brushed layer, and the before/after and mask images were reviewed; an unknown key and an out-of-range exposure gave clear answers; snapshot, auto tone, Upright and undo ran; `copy_edits` pasted glow, grain, color and grading onto a second photo without touching its exposure.
- **Tests (AssistantEditTests):** reference completeness, the document's sections and hidden internals, merge / null removal / limits / refusals, a brushed layer set by value, the render changing, the command table.
- **Not yet verified by hand:** a session from Claude Desktop with OpenStill MCP 1.2.0.

## AI tools keep the crop and every setting — September 30, 2026
- **Fixed:** AI erase (and AI noise removal, detail and super resolution) ran on the fully edited photo and then reset the edit, so the crop was baked in (the photo looked zoomed in and couldn't be uncropped) and every other setting was lost. They now run on the photo itself, in its own geometry, and the result replaces only the base: crop, rotation, straighten, transform, tone, masks and layers stay as they were and adjustable. A second AI tool builds on the first. On RAW photos white balance stays adjustable.
- **Tests (AIBaseTests):** a cropped, rotated, straightened, exposure-adjusted photo with a simulated erase keeps its frame (no zoom), is unchanged away from the erased spot and changed on it, and a second AI tool starts from the result; RAW results keep white balance adjustable.
- **Not verified on CI:** the AI worker itself (a ~450 MB model download); verify by hand: erase something on a cropped photo, then uncrop.
