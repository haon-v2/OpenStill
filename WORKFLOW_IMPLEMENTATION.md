# OpenStill 0.6 photographer workflow

Implemented September 25, 2026. This document records the delivered behavior and
actual coverage; it is not a claim of testing every camera, printer or Mac.

## Integration

- Floating-point extended-linear Rec.2020 graph separates decoding, editing,
  display and export. Embedded input profiles remain attached. Output supports
  JPEG and 8/16-bit PNG/TIFF in sRGB, Display P3, Adobe RGB and ProPhoto RGB.
  LUTs remain in their intended sRGB domain. Output profile simulation and ICC
  printer proofing occur only at the preview boundary.
- Pinned LibRaw 0.22.2 develops sensor data with camera WB/matrices and selectable
  highlight recovery. S9 defaults to Camera Look, retaining its embedded JPEG
  appearance. Other supported RAW files default to RAW. Source changes create
  separate versions. RAW failures are explicit; a camera JPEG is never labelled
  as sensor development. RAW temperature is a relative adaptation around as-shot
  camera balance, not a calibrated absolute Kelvin readout.
- Versioned photo records use UUIDs, bookmarks and full-content fingerprints.
  Legacy histories preserve the legacy renderer. New-renderer features duplicate
  legacy versions. Atomic local saves retain ten recovery snapshots; named
  versions remain until explicitly deleted. No automatic portable sidecars.
- Histograms, output/sensor clipping, master/RGB curves and a neutral WB picker;
  Lensfun matching/manual profiles and optical/manual corrections; named per-tool
  masks with component operations, color/luminance ranges and source geometry;
  nondestructive source-point healing/cloning with aligned offsets and undo.
- Shoot grid, stars, pick/reject, filters/sorting, synchronized comparison,
  selective batch preview/application/undo, and conflict protection for later edits.
- Export presets, serial full-resolution queue, cancellation/retry, collision-safe
  naming, resizing/sharpening, metadata choices and preview-only Little CMS proofing.
  GPS is removed by default. Successfully completed exports survive later failures.
- Explicit portable packages contain histories, versions, ratings and referenced
  assets with checksums; optional originals or verified relinking. Imports append
  versions. Missing/tampered assets and mismatched originals are rejected.
- Watermark library accepts private copies of PNG/TIFF/JPEG/PDF/static SVG.
  Editable vector logo designer preserves exact text, offers three local model
  suggestions, and exports SVG/PDF/transparent PNG. Placement has nine anchors,
  percentage size, margin, opacity and preset persistence. App icon unchanged.
- Optional official Qwen3-0.6B Q8_0 download: 639,446,688 bytes, verified SHA-256,
  progress/cancel/removal, pinned bundled llama.cpp helper, Metal or CPU.
  Manual/imported logos require no model. Generated values follow a constrained
  schema; no arbitrary code/SVG execution and no photo upload.
- New AI bridge uses float32 extended-sRGB exchange. Models receive bounded
  [0,1] input; out-of-range residuals are retained. Existing model training/range
  limits still apply. Legacy versions retain the original image bridge.

## Acceptance evidence

- Full release-mode suite: 110 tests in 20 suites passed. The two opt-in Vision
  tests were then run with actual local fixtures and both passed. Python float
  transport: two tests passed. Batch/package regression after final cleanup:
  six tests passed. Automated storage uses disposable isolated roots.
- Actual S9 fixture: Photography Blog sample 01 RW2 + JPEG, decoded to 6016×4016
  RAW / 6000×4000 camera preview. Verified defaults, camera/lens metadata, source
  versions, WB changes, orientation against JPEG and output. This fixture is for
  local QA only and is not bundled. Source:
  https://www.photographyblog.com/reviews/panasonic_lumix_s9_review
- A car JPEG and 12 other authorized JPEG copies were used locally; no messages
  were sent. These shared JPEGs lack camera/lens EXIF and
  are not evidence of sensor RAW support. User photos are not in the repository.
- Color tests verify actual 16-bit output, embedded profiles and >256 gradient
  levels for every PNG/TIFF profile combination. Preview/output sample agreement,
  camera/lens/copyright retention, GPS removal, original protection and filename
  collisions passed. SWOP CMYK patches match official Little CMS transicc values
  within 0.004 normalized RGB; paper simulation and gamut warnings tested.
- Masks/retouch tests cover legacy coverage, component operations, independence,
  geometry/lens alignment, feathered masks, source alignment and history. Native
  car QA painted/undid a healing stroke and verified tool switching clears the
  active overlay. Corrected vertical lens-map upload orientation with a regression.
- Native QA verified rating/pick filtering, two-photo zoom synchronization,
  two-photo batch copy/undo, package export/import, metadata, export dimensions,
  RAW highlight-recovery undo, WB eyedropper history, watermark candidate editing/saving, model download/cancel/generation/cancel/
  removal, export presets, proof profile loading and a watermarked JPEG export.
- Vector tests cover exact text, transparent output, static SVG shapes/arcs/
  transforms, rejection of active/external content, all anchors, asset independence
  and serialization. Unsupported non-outline glyphs fail explicitly. Actual Qwen
  inference returned three valid candidates with exact photographer text.
- Actual installed LaMa, SCUNet and Real-ESRGAN models ran through float transport
  on a small QA fixture (3.36s / 0.85s / 0.34s); erase preserved unmasked pixels.
  Vision detected the test's +7° tilt as −7.125° and selected foreground/background.
- Pinned dependency source archives, licenses, model manifests and notices bundled.
  Lens database conversion reproduces all 56 XML files byte-for-byte using
  `scripts/convert-lens-profiles.py`.

## Performance and limits

Measured on Apple M4 Pro, 24 GB RAM, macOS 26.6.2; release builds. These are local
measurements, not guarantees. Pixel buffers were realized to include render work.

| Operation | Time |
| --- | ---: |
| 24MP S9 RAW decode + Glow | 1.09 s |
| 1600px interactive S9 RAW decode + Glow | 0.31 s |
| 24MP JPEG + Glow | 0.18 s |
| 54MP upscaled JPEG + Glow | 0.43 s |
| 1600px JPEG interactive Glow | 0.029 s |

RAW preview/full-resolution mean sample difference was 0.00350 in normalized RGB.
The performance test process peaked around 1.40 GB resident memory while rendering
24/54MP cases; the complete regression run including the model peaked around
1.68 GB. Model generation varied from roughly 1.6 to 18 seconds across runs.
Slider dragging uses reduced previews; release restores full-resolution output.

Only the actual S9 sample is validated for sensor RAW in this release. Other
LibRaw-supported cameras, Intel runtime behavior, macOS 13 deployment, arbitrary
printer/paper profiles and physical print matching still need broader hardware
coverage. Native binaries target macOS 13; Vision object selection needs macOS 14.
Optional Python AI has its documented runtime requirements. Public distribution
requires Developer ID signing/notarization; local builds are ad-hoc signed.

## Installed delivery

OpenStill 0.6.0 (build 13) installed at
`~/Applications/OpenStill.app` and launched successfully with a
24MP car JPEG. Final native sidebar and compact Shoot toolbar inspected.
Deep/strict signature verification passed for the app, helper and all bundled
libraries. Dependency archive checksums, notices, 12 offline LUTs and unchanged
app-icon checksum verified. The optional logo model is not bundled and was
removed from application storage after the download/removal test. The generated
example watermark and Web 1600px preset remain available locally.

Previous installed 0.5.1 app retained at
`/tmp/OpenStill-previous-0.5.1-c0e3fc6f-3b22-43fb-b80b-a208f4b6b664.app`.


## Native workspace update — 0.7.1 (September 25, 2026)

The interface now combines native macOS 26 Liquid Glass with the simpler Lightroom desktop layout requested by the user. Local navigation and recent folders live on a slim left rail, Library and Edit share one window, and the right rail opens Edit, Crop, Retouch, the active tool's mask, Presets, History and Info. Editing retains a neutral photo canvas and bottom filmstrip. Green accents mark selections, sliders and primary actions. macOS 13–15 use native visual-effect materials. System-managed focus rings and menus retain their native accessibility appearance.

Library reuses the existing shoot workflow, including ratings, flags, comparison, selective batch edits and export. Filename search, multi-selection and filtered navigation are available in the main window. Double-click resolves the clicked item before opening, even when multiple items are selected. Library toolbar sharing/export uses the library selection; confirmed original deletion remains available in photo view. Recent-folder paths are stored locally in app preferences. Rendering algorithms, edit document formats, per-tool mask storage, LUT assets, originals and the app icon were not changed by this UI update.

Validation on this Mac (macOS 26.6.2, Apple silicon):

- Release build succeeded; installed at `~/Applications/OpenStill.app`. Deep/strict ad-hoc signature verification passed.
- 110 existing tests in 20 suites passed with isolated temporary application storage. Tests required graphics access outside the command sandbox. Optional hardware/camera fixture gates were not a new claim of additional camera coverage.
- Native visual review covered the editor and glass surfaces, green sliders and selections, the export window and logo designer. A secondary-window title-bar mismatch was found and corrected.
- Native interaction checks covered Fit/100%, inspector hiding, S9 camera/lens metadata, the integrated library, reopening a recent folder, filename filtering, multi-selection, a two-photo export panel, double-clicking the intended photo from a multi-selection, crop controls, the active Glow mask shortcut, and bundled/imported LUT availability. No test exports or original deletions were performed for this layout change.
- No Auto Layout conflict diagnostics appeared during the workspace checks. Light-mode, reduced-transparency and older-macOS visual coverage remain to be performed on those configurations.
