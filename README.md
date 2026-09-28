# OpenStill

A free, open-source macOS photo viewer and editor. A little space for your photographs.

OpenStill 0.6 combines a native photo browser with nondestructive editing, optional on-device AI, complete ImageIO-readable metadata, and sharing. Originals are preserved.

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

Press **Delete** while browsing, use **File → Move to Trash… (⌘Delete)**, or right-click the photo or a filmstrip thumbnail. Right-clicking a thumbnail selects that photo first. A confirmation names the exact file and its folder; **Move to Trash** is the default button, so Delete then Return trashes the photo, and Escape cancels. In the library grid, Delete asks the same way for all the selected photos. Only the selected original is moved, leaving paired RAW/JPEG files and sidecars alone. In the viewer, Trash works on one photo at a time.

After confirmation, OpenStill uses macOS Trash and advances to a remaining photo. You can recover the file from Finder's Trash. If the device is read-only or does not support Trash, OpenStill shows an error and never falls back to permanent deletion. No files are removed from the viewer until the Trash operation succeeds. Holding Delete does not repeatedly trigger deletion.

## Right-click menu

Right-click a photo in the library grid, the filmstrip or the viewer. The clicked photo is selected first if it wasn't already. The menu has:
- **Open in Develop** (from the Library);
- **Open With ▸**: the apps macOS offers for that file, the default app first, plus **Other…**. The original file is opened;
- **Edit In ▸**: your saved external editor, or **Choose App…** (the same as **Photo → Edit In**);
- **Show in Finder**, and **Show in Folder**, which opens the photo's folder in the Library with the photo selected;
- **Set Rating**, **Set Flag** and **Set Color Label**;
- **Share** and **Move to Trash…**.

## Metadata

The Info panel reads embedded EXIF, TIFF, and auxiliary metadata through Apple's ImageIO framework:

- Camera make and model; lens make and model (or recorded lens specifications).
- Shutter speed, aperture, ISO, focal length, 35mm equivalent, exposure compensation.
- Capture time, oriented pixel dimensions, format, and file size.

The camera, lens, ISO, focal length, aperture, and shutter remain visible above the editing tools. **Info → All recorded metadata** expands every property supplied by ImageIO, including nested EXIF/TIFF/GPS fields when available.

Missing fields say **Not recorded**. Capture time is the camera's recorded local time; its offset is shown when embedded. Images exported without EXIF cannot reveal settings that were removed. Proprietary maker notes and lens-ID databases are not parsed. XMP sidecars are read into the library (see **XMP sidecars and Lightroom** below), not shown in the Info panel.

Common formats include JPEG, PNG, HEIC, TIFF, and other formats supported by the installed macOS ImageIO decoders. Sensor RAW development uses bundled LibRaw 0.22.2. While a RAW file develops, the camera's embedded preview shows straight away. Fujifilm X-Trans files (`.RAF`) use LibRaw's one-pass X-Trans interpolation on screen, which is several times faster; exports, Edit In and full-quality renders keep the three-pass one. Unsupported files show a capability error. Animated/multipage images show the first frame/page. EXIF orientation is applied. Images retain their embedded color space for display, but HDR editing and HDR proofing are outside this release.

## Library and catalog

OpenStill keeps a local SQLite catalog (`Catalog.sqlite`, next to your edit records in Application Support). It indexes every photo you open: file path, size and modification date, capture date, camera, lens, ISO, focal length, aperture, dimensions and GPS position, plus ratings, flags, labels, titles, captions and keywords. Your edit records stay the source of truth. The catalog is an index that is kept in sync as you work, and records saved by earlier versions are indexed the first time you open a photo after updating.

- **Faster opening.** A photo whose path, size and modification date haven't changed is found in the catalog without re-reading the whole file. A moved or renamed file is still recognized by its contents.
- **Include subfolders** (Library sidebar) scans the folders inside the one you open. Hidden folders and packages are skipped.
- **Star ratings.** Press **0–5**, or click the stars under a thumbnail to rate that photo; clicking its current rating again clears it.
- **Color labels.** Press **6** red, **7** yellow, **8** green or **9** blue, or use **Label** for purple and Clear. Pressing a photo's current label key again clears it. Labels show as a colored strip on each thumbnail. Filter by label, or show only unlabeled photos.
- **Metadata.** Select photos and choose **Actions → Edit metadata…** to set title, caption, creator, copyright, location, city, state, country and keywords. Keywords can have levels with `>`, for example `Places > France > Paris`; searching for "France" also finds it. With several photos selected, filled-in fields apply to all of them, keywords are added, and **Remove keywords** takes keywords off. Save frequent fields such as creator and copyright as **metadata presets**. Metadata is stored with OpenStill's edits and your original files are not changed. Exports include it as IPTC, with the keyword's last level as the IPTC keyword, when **Keep metadata** is on.
- **Collections.** **Actions → Add to collection…** puts the selected photos in a new or existing collection. Collections list in the sidebar and can hold photos from any folder. Control-click a collection to rename or delete it; deleting a collection never deletes photos. **Actions → Remove from this collection** takes photos out.
- **Smart collections** gather every catalog photo that matches up to six rules: rating, flag, label, keyword, camera, lens, ISO, capture date, filename, edited, or any text. Choose whether all rules or any rule must match. They update themselves.
- **Search** matches filenames, titles, captions, keywords, camera and lens. Every word must match.
- **Preview cache.** Library thumbnails are saved as small JPEGs under `Previews`, keyed by the edit version and revision, so unchanged photos appear without rendering again. An edit makes a new preview and removes the old one.

Moved or deleted files drop out of collections until they're found again.

### Library views, filter bar, stacks and more (Lightroom layout)

- **Views.** The toolbar under the grid switches between **Grid (G)**, **Loupe (E)**, **Compare (C)** and **Survey (N)**.
  - **Loupe** shows the selected photo large; ← and → step through the photos.
  - **Compare** puts the selected photo (the *select*) next to the next one (the *candidate*), with zoom and panning kept in step; ← and → change the candidate, and **Swap** trades them.
  - **Survey** tiles all the selected photos; click one to make it active, or × to drop it from the survey.
  - The **Thumbnails** slider sets the grid size.
- **Filter bar (\\).** Adds Metadata columns under the search and attribute filters: **Date, Camera, Lens, Label** and **Keyword**, each with photo counts. Each column only offers what the columns to its left leave; **None** clears them.
- **Stacks.**
  - **Library → Group into Stack (⌘G)** stacks the selected photos; **Unstack (⇧⌘G)** breaks it up.
  - A closed stack shows its top photo with a count; **S** opens or closes it, and **Shift-S** moves the selected photo to the top.
  - **Auto-Stack by Capture Time…** stacks photos taken within a chosen number of seconds of each other.
  - Stacks are kept in the catalog.
- **Quick Develop** (right panel) nudges the selected photos' white balance, temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, clarity and vibrance up or down, runs **Auto Tone** or **Reset All**. Each click is one batch that **Actions → Undo batch** reverses.
- **Keywording and the Keyword List.**
  - Type keywords to add them to the selected photos, or click a word in a **Keyword Set** (⌥1–⌥9) or a **Keyword Suggestion**, which comes from keywords that appear together on your photos. Recent Keywords is the first set.
  - The **Keyword List** shows every keyword with its count: the checkbox adds or removes it on the selected photos, and › shows the photos that have it.
- **Painter.** Turn on **Painter** in the toolbar, choose Keywords, Label, Rating or Flag and type the value, then click or drag across photos to apply it.
- **Rename Photos (F2).**
  - Renames the selected files on disk from a template: `{name}`, `{index}`, `{date}`, `{yyyy}`, `{MM}`, `{dd}`, `{camera}` or `{title}`, with a start number and a preview.
  - Extensions stay the same, XMP sidecars are renamed too, and edits and collections follow the photos.
  - Names that would clash with another file are refused.
  - **Library → Undo Rename** puts the old names back.
- **Auto Import.** **Library → Auto Import Settings…** watches a folder.
  - Photos saved into it (for example by tethering software) are moved or copied into a destination folder, with optional keywords, while OpenStill is open.
  - Only the folder's top level is watched, and a file is taken only once it has stopped changing.
- **Reference View.** **Library → Reference View** keeps a chosen photo in its own window next to the one you're developing, for matching a look. **Use Current Photo as Reference** changes it.

## Importing photos

**File → Import Photos… (⇧⌘I)** works like Lightroom's import. Choose at the top:
- **Copy**: copies the photos into your photo folders and adds the copies. The originals stay where they are.
- **Move**: moves the photos into your photo folders. On the same drive the files are simply moved; from another drive each copy is verified first, and only then does the original go to the Trash.
- **Add**: adds the photos to the library where they are. Nothing is copied or moved, so the folder and name settings are hidden.

From a camera card only **Copy** is offered, so nothing on the card is changed. Right-click a folder in **Folders** and choose **Import to This Folder…** to copy photos straight into it. When the import finishes, the window says which folders the photos are in, with **Show in Library** and **Show in Finder**.
- **Source.** Cards and other removable drives are listed automatically, with ones holding a `DCIM` folder first; **Choose folder…** picks any folder. Subfolders are included and hidden files skipped.
- **Already imported.** Photos whose contents are already in your library (same size and SHA-256) are marked and unchecked. Check or uncheck any photo; with several rows selected, one checkbox changes them all.
- **Folders and names.** The folder template (for example `{yyyy}/{yyyy}-{MM}-{dd}`) and name template (for example `{date}_{name}`) use `{yyyy} {MM} {dd} {date} {time} {name} {index} {camera}`, with a live example. Dates come from the capture time recorded by the camera. An existing file is never replaced; a clash gets `-1`, `-2`…
- **Second copy.** Optionally write a backup copy, with the same folders and names, to another drive.
- **Apply on import.** A metadata preset, extra keywords, and a develop preset (`.openstillpreset`) applied to each photo's first version. A develop preset doesn't change crop, rotation or lens corrections.
- **Verified.** Every copy is written to a temporary file, read back, and compared with the original's SHA-256 before it gets its final name. A copy that doesn't match is removed and reported. XMP sidecars come along with their photos. Copy and Add never change the source.
- **Eject** the card when the import finishes without errors (optional).

Imported photos open in the library.

## Catalog: compared with Lightroom Classic

What OpenStill's catalog has, checked against the code, and what's still to come:

| Lightroom Classic | OpenStill |
| --- | --- |
| Folders panel with drives, hierarchy and counts | Yes, with Show in Finder, Import to This Folder and Synchronize Folder |
| Import: Copy / Move / Add | Yes. Copy as DNG isn't offered |
| Collections and smart collections | Yes |
| Stacks | Yes (Library → Group into Stack, ⌘G) |
| Virtual copies | Versions: named alternatives of one photo's edits, but not separate thumbnails in the grid |
| Missing-file badges ("!" on photos whose file moved) | Not yet: drives that aren't connected are dimmed in Folders, and Lightroom catalog imports can be relinked |
| Synchronize Folder removing photos deleted outside the app | Not yet: it adds new photos and refreshes counts |
| Find missing folder / Update folder location | Not yet |
| Collection sets (folders of collections) | Not yet |


## Duplicates

**Library → Actions → Find duplicates…** looks through the selected photos (or every photo shown):
- **Exact copies**: files with byte-for-byte identical contents, found by size and SHA-256.
- **Similar photos**: bursts, small edits and re-exports, compared with Apple's Vision image feature prints on this Mac. **Match** sets how close photos must be.

In each group ★ marks the photo to keep: the highest rated, then a pick, then the largest file. **Flag extras as rejects** flags the others so you can review them with the Rejects filter. Duplicates are never deleted. Double-click a photo, or use **Show in Finder**, to see it in Finder.

## Print, slideshows, web galleries and publishing

Select photos in the library (or none, for every photo shown), then choose **Library → Actions**:
- **Print…** lays photos out as a **single photo** per page, a **contact sheet** (with file names) or a **custom grid**. It supports US Letter, A4, A3 and common photo papers, portrait or landscape, with margins, captions (file name or title), output sharpening (none, low, standard, high) and resolution (180–360 dpi). **Printer profile…** converts to an RGB printer/paper ICC profile (choose "No color adjustment" in the print driver); other profiles print as sRGB. **Print…** opens the system print dialog; **Save as PDF…** and **Save as JPEG…** write the pages instead. Sharpening is applied for print only; your edits are unchanged.
- **Slideshow…** plays full screen with a crossfade, a fade through black or a cut, an optional slow zoom (Ken Burns), a loop and music. Space pauses, ← → step, Esc ends. **Export Video…** writes an H.264 movie (720p, 1080p or 4K) with the music trimmed or looped to fit.
- **Web gallery…** writes a folder with `index.html`, full-size images and thumbnails: a responsive grid with a keyboard-friendly lightbox, titles and captions, an optional watermark, and no outside scripts or fonts. Upload the folder to any web host; OpenStill doesn't upload it.
- **Publish…** keeps publish collections, each tied to one service:
  - **Folder** (a local folder, or one that iCloud Drive, Dropbox or a NAS keeps in sync);
  - **Flickr**;
  - **SmugMug** (enter the album key).

  Add photos to a collection. **Publish** sends new and edited photos (edited ones are replaced) and removes photos you take out of the collection. For Flickr and SmugMug, enter the API key and secret from your own developer account (OpenStill doesn't include one), approve OpenStill in the browser, and paste the code shown. The sign-in is stored in your keychain. Deleting a collection leaves published photos where they are.

Limits: the Flickr and SmugMug connections follow their published OAuth 1.0a upload APIs but haven't been tested against live accounts in CI; tell us if one misbehaves. Printing to CMYK profiles relies on the printer driver.

## People, map, timeline and tethered capture

Choose **Library → Actions**. Each of these works on the photos in the open folder or collection.

- **People…**
  - **Find Faces** looks for faces in the photos. It uses Apple's Vision framework on this Mac.
  - Similar faces form unnamed groups. **Grouping** sets how alike faces must be: strict, normal or loose.
  - Select a group or some faces, then use **Name…**. OpenStill then suggests other faces that look like that person. Select a suggestion and choose **Name…** to confirm it, or **Not This Person** so it isn't suggested for them again.
  - Named people are added to each photo as a `People > Name` keyword. This makes them searchable, and they're written to exports and XMP.
  - **Show Photos** shows only that person's photos in the library. Use **Actions → Show all photos** to go back.
- **Map…**
  - Shows photos that have a location. It also lists the photos that don't.
  - To set where photos were taken, drag them from the list onto the map, or drag a pin to move it.
  - **Import GPX Track…** places photos from a phone, watch or GPS log. It matches each photo's capture time to the track. Photos that record their time zone use it. For the others, choose the time zone the camera's clock was set to, and how many minutes fast it was.
  - **Show Photos in View** shows only the photos in the visible part of the map.
  - Locations you set are saved with the photo and replace the camera's. They're written to XMP, and to exports when **Include GPS location** is on.
  - The map is Apple Maps, so viewing it downloads map tiles from Apple.
- **Timeline…** groups photos by year, month and day of capture. Double-click one to show its photos.
- **File → Tethered Capture…** (⇧⌘T)
  - Connect a camera with USB and name the session. Optionally choose a metadata preset and a develop preset, then click **Start Session**.
  - Each new shot is copied to `Pictures/OpenStill Sessions/<date> <name>/` and numbered in order. The presets are applied, and the shot opens in the editor.
  - **Take Picture** fires the camera from the Mac when the camera supports remote capture over PTP. Otherwise, use the camera's shutter button.
  - There's no live view.

Limits:
- Face grouping describes each face with Vision's general-purpose image feature print. It isn't a dedicated face-recognition model, so check suggestions before naming them. Lighting, angle and age can split one person into several groups; strict grouping helps when different people are merged.
- Tethering depends on the camera's USB/PTP support, and it hasn't been tested with a camera in CI.

## HDR, panoramas and focus stacks

Select photos in the library, then choose **Library → Actions**:
- **Merge to HDR…** combines bracketed exposures of the same scene. Photos are aligned (turn off **Align hand-held photos** for tripod shots), scaled to the middle exposure and blended in linear light, using each frame where it is well exposed. **Deghosting** takes moving things, such as people or leaves, from a single exposure.
- **Merge to panorama…** joins frames in the order they were taken. **Cylindrical** suits wide rows of frames; **Perspective** keeps straight lines straight for a few frames. **Crop to fill the frame** removes the empty edges. Each frame should overlap its neighbour by about a third.
- **Focus stack…** combines photos focused at different distances, taking each area from the sharpest frame.

The result is a 16-bit floating-point TIFF saved next to the first photo (for example `IMG_0001-HDR.tif`) and added to the library. Originals are unchanged. An HDR merge keeps highlights brighter than white: turn on **HDR → Edit in HDR**, or lower Exposure, to see them.

Alignment is OpenStill's own: it finds the shift between frames, then refines rotation and scale, on this Mac. It doesn't correct perspective differences between hand-held frames. These are OpenStill's own merges, not Adobe's: panoramas use feathered seams rather than multi-band blending, there is no spherical projection or boundary warp, and focus stacking can show halos along strong edges. Check the result at 100%.

## XMP sidecars and Lightroom

OpenStill reads and writes `.xmp` sidecars, the files Lightroom, Bridge and Camera Raw keep next to photos (`IMG_0001.CR2` → `IMG_0001.xmp`). Your photos themselves are never changed.

- **Reading.** The first time OpenStill opens a photo, it takes the rating, pick/reject, color label, title, caption, creator, copyright, location and keywords from its sidecar, or from XMP embedded in the photo when there is no sidecar. Bridge's reject rating (−1) becomes a reject flag, and hierarchical keywords (`lr:hierarchicalSubject`) keep their levels. **Actions → Read metadata from XMP** reads them again for the selected photos.
- **Writing.** **Actions → Write metadata to XMP** writes the selected photos' rating, label, keywords and other metadata to their sidecars. Turn on **Settings → Write metadata to XMP sidecars automatically** to do this whenever they change. OpenStill replaces only the fields it manages and keeps everything else already in the file, including Camera Raw develop settings. Pick/reject is stored as `openstill:Flag`, because Lightroom doesn't write picks to XMP. A photo shot as RAW + JPEG shares one sidecar name, as in Lightroom.
- **Camera Raw / Lightroom edits.** **Actions → Import Camera Raw edits from XMP** adds a version named "Camera Raw" developed with the settings in each photo's sidecar. The version keeps the original untouched. It carries over:
  - exposure, contrast, highlights, shadows, whites, blacks, white balance, vibrance and saturation;
  - clarity, texture, dehaze, and the HSL / Color mixer;
  - color grading (and older split toning), the point tone curves (master, red, green and blue, with their exact points), the parametric curve, grain, and post-crop vignette;
  - sharpening (Amount, Radius, Detail, Masking), luminance and color noise reduction with their Detail and Contrast, defringe, manual Transform sliders, crop, black & white and the B&W mix.
  OpenStill's tools are its own, so the result is close to Lightroom's but not identical. Anything it can't carry over is listed afterwards instead of being silently dropped: masks and local adjustments, spot removal, lens profiles, Upright, camera profiles and looks. Remove Chromatic Aberration is listed too: click **Remove chromatic aberration** in Lens corrections to measure it for the photo. White balance is an absolute temperature for RAW photos; for JPEG and other rendered photos, Camera Raw's relative temperature is approximated.
- **Import a Lightroom Classic catalog** (**File → Import Lightroom Catalog…**). Choose an `.lrcat` file. It is opened read-only, so Lightroom's copy is never changed. OpenStill imports, for each photo it finds:
  - rating, pick/reject and color label;
  - keywords (with their hierarchy), title, caption and the other metadata;
  - develop settings, as a version named "Lightroom";
  - regular collections.
  Photos stay where they are. If they've moved (for example to a new drive), **Relink…** points a top-level folder of the catalog to its new location. Smart collections and virtual copies are skipped. Custom label names other than Red, Yellow, Green, Blue and Purple aren't imported. Importing the same catalog again updates ratings and metadata but doesn't add a second "Lightroom" version.
  After the import, the window lists the folders your photos are in, with **Show in Finder** and **Show in Library** for each. Nothing is copied or moved. A normal **Import** also names the folders it copied to, with the same two buttons.

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

## Layout and keyboard shortcuts

OpenStill has one layout, modeled on Lightroom Classic's window, with flat dark-gray panels and square corners. (The EZ Layout of earlier versions is gone; a saved EZ Layout choice is ignored.)
- **The window:**
  - **Module picker** across the top: the identity plate on the left, **Library | Develop | Map | Slideshow | Print | Web** on the right. Map, Slideshow, Print and Web open their windows for the selected photos (⌥⌘3, ⌥⌘5, ⌥⌘6, ⌥⌘7). OpenStill has no Book module.
  - **Left panel:**
    - The **Navigator** sits at the top: the whole photo, with a frame around the zoomed-in area. Click or drag in it to move around, or use **FIT / 100% / 200%**.
    - Library has **Catalog, Folders, Collections** and **Publish Services**, with **Import… / Export…** at the bottom.
    - **Folders** works like Lightroom's: each drive (the startup disk first, then external drives, dimmed when not connected), then the folders that hold your library's photos, with photo counts. Click a triangle to open or close a folder, click a folder to show its photos, and right-click it for **Show in Finder**, **Import to This Folder…** and **Synchronize Folder**. Folders above your photos that hold nothing else are skipped, so the list starts where your photos are.
    - Develop has **Presets, Versions** and **History**, with **Copy… / Paste**. Versions take the place of Lightroom's Snapshots and are OpenStill's named alternatives.
  - **Right panel:**
    - Library has **Histogram, Keywording** and **Metadata** for the photo selected in the grid, with **Sync Metadata… / Sync Settings…**.
    - Develop has the **Histogram** with the camera settings under it, then the **Crop / Remove / Red Eye / Masking** tool strip. Below that, in Lightroom's order:
      - **Basic**: the **Profile** first, then Treatment, White Balance, Tone, Presence and HDR;
      - **Tone Curve**, **HSL / Color**, **B&W Mix** and **Color Grading**;
      - **Detail**: sharpening, noise reduction, chromatic aberration, defringe and the AI enhancements;
      - **Geometry**: Crop & Straighten, Lens Corrections and Transform together;
      - **Effects**: vignetting, grain, **Lens Blur**, Glow, Sunrays and Structure;
      - **Calibration**;
      - then OpenStill's own **Sky Replacement**, **Layers** and **On-Device AI**.

      Only Basic starts open; the others remember whether you left them open.
    - At the bottom of Develop are **Previous**, which copies the last photo's settings but not its crop, retouching, lens or transform, and **Reset**.
  - **Panels:**
    - Headers open and close sections. Option-click a header, or Control-click it and choose **Solo Mode**, so opening one section closes the rest. **Expand All / Collapse All** are in the same menu.
    - The triangles at each window edge show and hide that panel. Your panels and sections are remembered.
  - **Filmstrip:** it runs across the bottom in both Library and Develop. Its bar shows the grid button, back / forward, and the source, e.g. "Folder : Trip 124 photos / 1 selected / IMG_0001.CR3".
  - **Toolbar:** Develop's toolbar under the photo has Loupe, Before / After and the clipping warning.
  - **Lightroom's keys:**

    | Key | Action |
    | --- | --- |
    | G / D | Library grid / Develop (anywhere in the window, except while typing in a field) |
    | R | Crop |
    | Q | Remove |
    | Shift-W | Masking |
    | L | Lights Out: dim, then off, then on |
    | T | Toolbar |
    | Tab | Side panels |
    | Shift-Tab | All panels |
    | F5 / F6 / F7 / F8 | Module picker / filmstrip / left panel / right panel |

    You can change them all in **Settings → Shortcuts → Workspace**.
  - **Masking works like Lightroom's.** **New mask** (Brush, Linear, Radial, Subject, Sky, Background, People, Object, Color / Luminance / Depth range) adds a mask with its own Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Temperature, Tint, Saturation, Clarity, Texture, Dehaze, Sharpness and Noise sliders. Add as many as you like; each one changes only its own area. Rename, duplicate, invert, hide or delete a mask from its list. Below the list you can still limit a whole tool (Develop, Clarity, Color grading…) to a mask, as before.
  - **Return finishes a tool.** In Crop, Remove, Red Eye and Masking, Return (or **Done**) applies the crop or ends painting and closes the panel. Escape closes it too.
  - **Look and behavior are close to Lightroom Classic, not a copy.** The panel names, order and keys follow it, and the controls are OpenStill's own. There are no Adobe icons or artwork, and slider scales are OpenStill's (for example, Contrast runs 0.5–1.5), not Lightroom's −100 to +100.

**Settings → Shortcuts** lists every command and its shortcut:
- **What you can change:** every menu command, plus the single keys used in the library grid (ratings, labels, flags, open) and on the photo (clipping, before/after, compare, next and previous, Trash, brush size). A search box finds commands by name or by keys, e.g. “export” or “⌘E”.
- **How to change one:** click a shortcut, then press the new keys. Delete removes it and Escape cancels.
- **Conflicts:** if the keys already belong to another command, OpenStill asks before moving them. For example, giving Open ⌘P takes it from Print.
- **Resetting:** each changed shortcut has a reset button, and **Restore All Defaults** puts everything back.
- **Rules:** menu shortcuts need ⌘, ⌃ or ⌥, or a function or arrow key, so they don't get in the way of typing.
- **Fixed keys:** slideshow keys and the arrow keys that nudge the Sunrays source point can't be changed.

## Workflow

- **Edit In another app** (**Develop → Edit In App**, ⌘E).
  - Sends the photo, with your edits, to Photoshop, Affinity Photo or any app you choose (**Edit In Other App…** picks it the first time).
  - OpenStill writes a 16-bit ProPhoto TIFF named `-Edit` next to the original, adds it to the library with the original's rating, label and keywords, stacks it on top of the original, and opens it in the app.
  - Save it there, then refresh the library to see your changes in OpenStill.
- **After export** (Export panel).
  - When an export finishes, OpenStill can show the files in Finder, open them in an app, or run a script you choose (it gets the exported files as arguments). The script runs on this Mac and nothing is uploaded.
  - Saved export presets keep this choice.
- **Smart Previews** (**Develop → Build Smart Previews**).
  - A 2560-pixel copy of each selected photo, decoded but unedited, stored with the catalog.
  - While a photo's drive isn't connected, you can still open and edit it from its Smart Preview; your edits apply to the original when it's back.
  - Exporting still needs the original.
  - **Discard Smart Previews** frees the space.
- **Catalog.**
  - **File → Back Up Catalog Now** copies the catalog, edit records and settings into a dated folder.
  - **Catalog Settings…** schedules backups when OpenStill quits (every quit, daily or weekly), sets how many backups to keep, and can move the catalog to another folder (after a relaunch).
  - **Export as Catalog…** saves the selected photos' edits (and, if you like, the originals) as a folder of portable edit packages; **Import Catalog…** brings one in.
- **Secondary Display** (**Window → Secondary Display**, ⌘F11). A second window, on your other screen when there is one, showing the selected photo in Loupe, Compare or Survey. It follows the main window's selection.
- **Book** (**Window → Book**, ⌥⌘4, or Book in the Lightroom module picker).
  - Pages of one photo, full bleed, two or four photos, with captions.
  - **Auto Layout** fills pages in order; any spot can be changed from its menu, and pages can be added, moved or removed.
  - **Save PDF…** renders each photo at about 300 dpi. The book is made on this Mac; there's no print-service upload.
- **Auto Sync** (**Develop → Auto Sync**). While it's on, each change to the photo you're editing also goes to the other photos selected in the filmstrip.
  - Only the sliders you changed are copied, so changing Exposure doesn't overwrite another photo's Contrast.
  - Crop, retouching and lens settings are never synced.
- **Adaptive presets** (**Develop → Adaptive Presets**). Subject: Pop, Subject: Soften, Background: Soften, Background: Clear haze, Sky: Deepen and Sky: Soft.
  - They find the subject (Apple Vision, on this Mac) or the sky (on-device AI) in each photo and apply their settings only there.
  - The masks appear in each tool's Masking tab, where you can refine them.
- **Identity plate** (**Develop → Identity Plate…**). Your own text or logo in place of "OpenStill" at the top left of the Lightroom layout. **Use Saved Logo** picks a logo made or imported in the watermark logo designer.

## Performance

- **Rendering:** all rendering goes through a few long-lived Core Image contexts on the Mac's Metal GPU. Masks, overlays and selections no longer create a new context each time.
- **Pixel conversions:** RAW buffers and OpenStill's float intermediates are converted with Accelerate (vImage and vDSP) rather than per-pixel loops.
- **Library catalog:**
  - The library takes capture dates from the catalog instead of reopening each photo.
  - Indexing writes photos in batches, and capture dates are indexed.
  - Search skips per-photo work when the search box is empty.
  - On Macs with 8 or more cores, the grid renders two thumbnails at a time.
- **Benchmark:** `PerformanceTests` builds a 50,000-photo catalog on every test run. It times indexing, reading, search, smart collections, keyword counts, the timeline, lookups, the library filter and sort, and grouping 5,000 faces, and prints the timings in the test log.
- **Not changed:**
  - The Core Image kernels are still written in the Core Image Kernel Language. Core Image compiles them to Metal on the GPU. Moving them to precompiled Metal libraries would need a Metal build step that Swift Package Manager doesn't provide.
  - The editing canvas still draws a GPU-rendered, display-sized image rather than using an MTKView.

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
- Smart Contrast: the Contrast slider pivots on the photo's own middle tone instead of a fixed gray. Soft shoulders keep highlights and shadows from clipping, lowering it flattens midtones without milky blacks, it changes brightness only so colors don't shift, and higher settings add a little local contrast. Photos whose contrast was set before Smart Contrast keep their look until you move the slider again.
- Temperature and Tint: higher Temperature warms and positive Tint adds magenta, on RAW and rendered photos (JPEG, HEIC, TIFF…) alike. Rendered photos used to go the opposite way; an edit made before this fix keeps its look until you move Temperature or Tint.
- Dehaze: positive removes atmospheric haze using a dark-channel estimate; negative adds haze.
- Clarity: broad midtone contrast (negative softens). Texture: medium-sized detail such as skin, foliage or fabric (negative smooths).
- Color grading: Shadows, Midtones, Highlights and Global wheels. Drag in a wheel to set hue and strength, set each range's luminance, and use Blending and Balance to control how the ranges overlap. Double-click a wheel to reset it.
- Grain: film-like grain with Amount, Size and Roughness. Grain size scales with the photo, so previews and full-size exports match.
- Defringe (in Lens corrections): removes purple and green fringes along high-contrast edges, with adjustable hue ranges. Evenly colored purple or green areas are left alone.
- Clipping and comparison: click the histogram, press **J**, or choose **View → Show / Hide Clipping** to show clipped highlights in red and clipped shadows in blue. Press **Y** (or **View → Before / After Split**) for a side-by-side split with a draggable divider; press **\\** to toggle the full before view.
- Dehaze, Clarity, Texture, Color grading, Grain and Defringe are OpenStill's own algorithms. They are designed to feel familiar to Lightroom users but are not pixel-identical to Adobe's.
- Enhance: automatic tonal/color correction. Structure, sharpening, and noise reduction.
- Tone curve: **Parametric** has Highlights, Lights, Darks and Shadows sliders with three movable split points. **Point** edits the RGB, Red, Green or Blue curve: click to add a point (up to 16), drag to move it, double-click it or drag it off the graph to remove it. The curve bends smoothly through the points without overshooting. The parametric curve is applied first, then the point curves. **Targeted adjustment** lets you drag up or down on the photo to raise or lower the curve at that spot's brightness.
- Point Color (in Color / HSL): **Pick a color from the photo** samples up to 8 colors. Each one shifts the Hue, Saturation and Luminance of the colors near it; **Range** widens or narrows which colors count as near. Grays are left alone. **Drag on photo: Saturation, Hue or Luminance** changes the color band under the pointer as you drag up or down.
- B&W mix: with Black & white on, eight sliders (red to magenta) brighten or darken each color's gray. **Auto mix** sets them from the photo's colors.
- Detail: Sharpening has **Radius**, **Detail** and **Masking** (Masking 0 sharpens everything; higher values sharpen only edges). Noise reduction has Luminance **Detail** and **Contrast**, plus **Color** and **Color detail** for color blotches. Photos edited before these sliders existed look the same until you change one.
- Remove chromatic aberration (Lens corrections): measures the red and blue fringing toward the corners of this photo and lines the colors up again. It works without a lens profile. Measuring again replaces the old values; **Turn off chromatic aberration removal** removes it.
- Red eye and Pet eye (the Red Eye button in the Develop tool strip): drag an ellipse over an eye. Red eye darkens and desaturates the red pupil; Pet eye fills the pupil and can add a catchlight. **Pupil size** and **Darken** change the last eye. Eyes follow crop, rotation and flips.
- Visualize spots (Retouch / Remove): shows the photo as a black-and-white edge map so dust and small blemishes stand out; the slider sets how much detail it shows. It is never exported.
- Snapshots (Develop's left panel): **New snapshot…** saves the current edits under a name. Click one to go back to it in one undo step; Control-click it to rename or delete it. Snapshots belong to the version and are saved with it.
- Color: global saturation/vibrance plus eight visible swatches for red, orange, yellow, green, aqua, blue, purple, and magenta. Each color remembers its Saturation or HSL view. HSL provides Hue, Saturation, and Lightness with shade-gradient tracks and a live color indicator; switching views keeps your adjustments. Reset this color clears only the selected band.
- Black & white: monochrome strength plus separate Blacks and Whites tonal sliders.
- Vignette: negative darkens the edges, zero is neutral, positive lightens them.
- Lens blur: a depth-driven blur, like a wide-aperture lens. First choose the depth:
  - **Use the photo's depth data** (iPhone Portrait mode);
  - **Estimate depth** (on-device AI);
  - **Keep the subject sharp** (Vision's subject selection, for any photo).

  Then set **Blur amount**, **Focus distance** (1 = nearest) and **Focus range**, and whether nearer things blur too. The blur grows with distance from the focus band and scales with the photo, so previews match exports. It is OpenStill's own variable blur, not an optical bokeh simulation: there are no shaped highlights or cat's-eye bokeh. The Masking tab can limit it.
- HDR: **Edit in HDR** lifts the brightest highlights above SDR white, up to **Highlight headroom** stops (0.5–4). On an HDR display (macOS 14 or later, for example a MacBook Pro's XDR screen) the photo shows in extended range; elsewhere you see the SDR rendition. The Masking tab can limit it. It is OpenStill's own highlight expansion, not Adobe's HDR mode. SDR exports, sharing and previews on SDR displays use the SDR rendition.
- Glow (Creative): choose **Glow**, **Soft Focus**, **Orton Effect**, or **Orton Effect Soft**. Amount controls strength; expand Advanced for Softness, Brightness, Contrast, and Warmth. Starts disabled at Amount 0. Glow blooms around highlights; Soft Focus gently diffuses the photograph. All four looks support their own brush, gradient, radial, and object mask. Reset Glow keeps its mask and all other edits. Settings are included in saved presets and edit history, and render locally in previews and exports without a model download. These are OpenStill's own photographic diffusion algorithms, not pixel-identical copies of Luminar's filters.
- Transform: **Upright** buttons find long straight edges in the photo and correct them. **Level** rotates only; **Vertical** also makes vertical lines parallel; **Full** corrects vertical and horizontal perspective; **Auto** is a gentler balance of the three; **Guided** lets you drag 2–4 lines on the photo along edges that should be vertical or horizontal (Escape finishes, **Clear guides** removes them). Manual **Vertical**, **Horizontal**, **Rotate**, **Aspect**, **Scale** and **X/Y offset** sliders add to Upright. **Constrain crop** (on by default) enlarges the photo just enough that no empty edges show; turned off, empty edges export as white in JPEG and transparent in PNG and TIFF. The correction runs after lens corrections and before straighten and crop, and masks, retouching and the white balance eyedropper follow it. Upright finds lines itself, on this Mac; it is not Adobe's algorithm and can pick different lines, so check the result and switch modes or use Guided when it misjudges a scene.
- Crop: draw a rectangle and Apply crop; rotate, flip, or reset. **Crop preset** offers Freeform, Original proportions, Square, and separate **Horizontal** and **Vertical** groups: photo ratios (3:2, 4:3, 5:4, 16:9, 21:9 and their vertical versions) and common resolutions (720p, Full HD, QHD, 4K UHD, 1080 × 1350 portrait posts, 1080 × 1920 stories/reels). **Swap horizontal ↔ vertical** turns the chosen preset 90°. While cropping, the frame and the panel show the crop's aspect ratio and pixel size (for example `16:9 · 3840 × 2160`); with a resolution preset, the panel warns when the crop is smaller than that resolution. Straighten manually (−20° to +20°), choose **Auto straighten from lines** to level the photo from its long straight edges, or choose **AI align horizon** for local Apple Vision detection. Straightening automatically fills the frame without empty corners. If no confident tilted horizon is found, the photo stays unchanged. Escape ends a drawing tool.
- Layers: one image overlay with opacity and normal/screen/multiply blending; edit-strength control blends tonal adjustments with their input.
- Sunrays: Amount, Overall Look, Sunrays Length, Penetration, Sun Radius, Sun Glow Radius/Amount, Number of Sunrays, Randomize, and separate Sun/Sunrays Warmth controls, following [Luminar Neo’s documented layout](https://support.skylum.com/editing-tools/landscape-tools/sunrays). OpenStill uses its own local algorithm, not pixel-matched Skylum processing. Click **Place Sun Center**, then click or repeatedly drag inside or outside the photo; Escape finishes. Placement adds workspace margins, and arrow keys nudge the center (Shift for larger steps). Amount starts at zero. The final light blend uses the tool’s independent mask. Old saved Sunrays effects retain the legacy renderer until this tool is adjusted. New centers follow source geometry through crop, rotation, flip, and straightening; each drag is one undo step.
- Presets: six starting looks, save/load `.openstillpreset` files, and a categorized 3D `.cube` LUT library with photo previews, intensity, and its own mask. Saved portable presets include tonal/color settings, but exclude masks, LUT asset references, geometry, and AI/image assets; loading preserves those from the current photo.
- Edits: undo, redo, click a previous history step, compare with the original, or reset. A new change after undo replaces the redo branch.

### Masks

**Masking** (Shift-W) makes mask layers: each new mask has its own set of sliders, so you can brighten the sky and darken the ground with two masks. The sections below describe the selection tools every mask uses.

### Per-feature masks

Each adjustment group has Adjustments and Masking tabs, including AI tools. Choose Masking, then Brush, Linear, Radial, or Object AI. LUTs have a Mask this LUT button. Crop/rotation always changes the whole canvas.

Masks belong to their individual tool. Switching tools ends the active brush/selection and hides its overlay; a tool without a saved mask starts with the entire photo. Returning to a tool keeps its own saved mask. A pending AI object selection is discarded when you leave its tool, and clearing a mask affects only that tool.

- **Brush**: choose Paint or Erase and adjust Size, Softness, and Strength. The red brush outline shows its size; [ and ] resize it. Brush strokes can refine linear, radial, and AI object masks without replacing them.
- **Linear**: a live red gradient previews the fade while dragging, with boundary guides and a half-strength center line. New gradients fade across the full drag distance; Feather narrows the transition. Drag from the unaffected side toward the fully adjusted side.
- **Radial**: drag from the center to the edge of an ellipse.
- **AI object**: click inside a distinct foreground subject. Uses Apple's on-device Vision instance segmentation on macOS 14+; it is not arbitrary text-prompt/background-object selection.
- **Select with AI…** adds a new mask component. Everything except sky runs with Apple Vision on this Mac:
  - **Subject** and **Background**: every foreground object Vision finds, or the inverse.
  - **People**, or **Person 1–4** counted from the left: person segmentation with soft hair edges. Individual people need macOS 14.
  - **Face**, **Eyes**, **Eyebrows** and **Lips**: from Vision's face landmarks. The face shape runs from the jaw line to the top of the forehead.
  - **Skin**: people coverage limited to skin tones. The tone range covers light and dark complexions, but warm-colored clothing next to skin can be included; subtract a brush where needed.
  - **Sky**: the on-device AI's U2-Net model, as a mask only, without replacing anything.
  - **Depth range**: selects part of the scene by distance. The depth comes from the photo's own depth data (iPhone Portrait-mode HEIC) or, when set up, the on-device AI estimate (Depth Anything V2 Small). The luminance bounds choose the band (white = near).

  AI components are saved as mask images in the photo's orientation. Like other components, they follow crop, rotation, lens corrections and Transform, and can be added, subtracted, intersected, inverted or refined with a brush.
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

**Export** writes a separate JPEG, PNG, TIFF or HEIF with compatible recorded camera/lens metadata. An export cannot overwrite its source, including through a symbolic link. Export offers JPEG, HEIF or 8/16-bit PNG/TIFF with sRGB, Display P3, Adobe RGB or ProPhoto RGB profiles. **Dynamic range** adds HDR output: **HDR (PQ)** and **HDR (HLG)** write 10-bit Rec. 2100 HEIF; **SDR + HDR gain map** writes a JPEG or HEIF that looks normal on SDR screens and brighter on HDR screens (needs macOS 15). AVIF export is not offered yet. New edits use floating-point extended-linear Rec.2020 processing; display output is color managed. LUTs are interpreted in sRGB. Legacy versions keep their earlier renderer until explicitly upgraded or a new feature requires an upgraded copy. Proprietary maker notes are not copied into newly rendered exports because their offsets and processing data may no longer be valid.

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

The designer has three separate modes, chosen at the top. Your exact name/initials and optional tagline are shared by the first two:

- **Design your own** needs no AI and no download. Adjust typography, symbol, layout, spacing and colors yourself. Save reusable designs or export outlined SVG, vector PDF or transparent PNG. Emoji or glyphs without outlines are rejected rather than silently omitted.
- **Generate with AI** takes a **Prompt** (up to 500 characters: mood, style, colors…) and suggests three designs. The AI only chooses among OpenStill's fonts, symbols, layouts and colors; your exact name and tagline are always drawn by OpenStill. **Edit in Design your own** takes the chosen suggestion into the manual controls to fine-tune it.
- **Import** uses a logo you already have, or one saved earlier.

Generate with AI uses the optional **Download local model · 639 MB**, which installs checksum-verified official Qwen3-0.6B Q8_0 and runs it with the bundled llama.cpp helper. Metal is used on Apple silicon; CPU mode is available and is the Intel default. Download/generation can be cancelled and the model removed. Inference stays offline; the model cannot execute code, supply arbitrary SVG, or change your exact text. This designer affects photographer watermarks only, not OpenStill's app icon.

Export placement offers nine anchors, percentage width, margin and opacity with a live preview. Watermarks belong to export presets and never enter editing masks or original files.

## On-device AI (optional)

Optional AI for sky and subject masks, object removal, noise reduction, detail and depth. Nothing is set up until you ask, it downloads about 450 MB once, and it runs only on this Mac: photos are never uploaded.

Five local models are integrated: sky segmentation/replacement (U2-Net), object removal (LaMa), noise removal (SCUNet), detail restoration and 2× super resolution (Real-ESRGAN), and depth estimation (Depth Anything V2 Small, for Lens blur and depth masks). These are independent open-source implementations, not Luminar's proprietary engines. Results depend on the photograph and mask; review fine texture at 100% and undo when needed.

Choose **Set up on-device AI…** (Develop → On-Device AI) once. This downloads approximately 450 MB of pinned, SHA-256-verified model files plus the Python packages. When a new version adds a model, the tool that needs it asks you to run setup again, which downloads only what's missing; no account or API key is needed. This Mac has already been set up. For a fresh installation, install Python 3.11 or 3.12 at a supported Homebrew or `/usr/local/bin` location, then run setup. AI's pinned NumPy wheels require macOS 14+ on Apple Silicon; the native viewer/editor targets macOS 13+. Other architectures/macOS versions have not been validated for AI.

- **Erase AI**: create a brush, linear, radial, or AI object mask over the unwanted area, then **Remove selected area**. LaMa processes a padded region around the mask. Cover the object including its edges. Brush refinement and feathering are available.
- **Sky replacement AI**: choose your own replacement sky photograph. The model detects a sky boundary, blends the replacement into that area, and rejects masks with no reliable boundary. There is no automatic foreground relighting or reflection replacement.
- **Noise removal AI** and **Detail restoration AI** process overlapping tiles to bound memory. The overlaps are blended with linear ramps, so tile seams don't show. Detail restoration keeps the original dimensions.
- **Denoise RAW data (keeps edits)**, for RAW photos: denoises the decoded sensor data instead of the finished image, so every slider, mask and crop stays adjustable afterwards. White balance changes after denoising are applied relative to the denoised image. RAW decoding options (demosaic, highlight recovery) are fixed at that point; run it again after changing them.
- **Super resolution 2×** creates a new version at twice the width and height (Real-ESRGAN). The current version is left as it was.

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
