import Foundation
import CoreImage

/// A self-contained HTML gallery (grid plus lightbox) that can be uploaded to any web host. Nothing is uploaded by OpenStill.
public struct WebGallerySettings: Codable, Equatable, Sendable {
    public var title = "Gallery"
    public var subtitle = ""
    public var dark = true
    /// Longest edge of the full-size images and of the thumbnails, in pixels.
    public var imageEdge = 2048, thumbnailEdge = 480
    public var quality = 0.85
    public var showCaptions = true
    /// Keep camera, lens and copyright metadata (GPS is always removed).
    public var keepMetadata = false
    public var watermark: WatermarkSettings?
    public init() {}
    public var sanitized: Self {
        var s = self
        s.imageEdge = min(8192, max(320, imageEdge)); s.thumbnailEdge = min(1024, max(120, thumbnailEdge))
        s.quality = quality.isFinite ? min(1, max(0.3, quality)) : 0.85
        s.watermark = watermark?.sanitized
        return s
    }
}
public struct GalleryItem {
    public var source: URL
    public var recipe: RenderRecipe
    public var title: String, caption: String
    public var metadata: IPTCMetadata?
    public init(source: URL, recipe: RenderRecipe, title: String = "", caption: String = "", metadata: IPTCMetadata? = nil) {
        self.source = source; self.recipe = recipe; self.title = title; self.caption = caption; self.metadata = metadata
    }
    public init(_ item: ShootItem) {
        self.init(source: item.url, recipe: item.record.active.recipe, title: item.record.iptc.title, caption: item.record.iptc.caption, metadata: item.record.metadata)
    }
}

public enum WebGallery {
    /// Escapes text for HTML element content and attribute values.
    public static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"; case "<": out += "&lt;"; case ">": out += "&gt;"; case "\"": out += "&quot;"; case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }
    /// "007-sunset-at-the-pier.jpg": numbered so the order survives any host's sorting, and safe in URLs.
    static func slug(_ index: Int, _ source: URL) -> String {
        let base = source.deletingPathExtension().lastPathComponent.lowercased()
        let allowed = base.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let cleaned = String(allowed).split(separator: "-").joined(separator: "-")
        return String(format: "%03d", index + 1) + "-" + (cleaned.isEmpty ? "photo" : String(cleaned.prefix(60))) + ".jpg"
    }

    /// Renders the photos and writes `index.html`, `images/` and `thumbs/` into `folder` (created if needed; existing gallery files are replaced).
    /// Returns the index page.
    @discardableResult
    public static func build(_ items: [GalleryItem], settings: WebGallerySettings, into folder: URL, progress: ((Int, Int) -> Void)? = nil, cancelled: () -> Bool = { false }) throws -> URL {
        let s = settings.sanitized, fm = FileManager.default
        let images = folder.appendingPathComponent("images", isDirectory: true), thumbs = folder.appendingPathComponent("thumbs", isDirectory: true)
        for dir in [images, thumbs] {
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var export = ExportSettings(); export.format = .jpeg; export.profile = .sRGB; export.quality = s.quality
        export.keepMetadata = s.keepMetadata; export.keepGPS = false; export.watermark = s.watermark
        var thumb = export; thumb.longestEdge = s.thumbnailEdge; thumb.watermark = nil; thumb.keepMetadata = false
        export.longestEdge = s.imageEdge
        var entries: [(file: String, width: Int, height: Int, title: String, caption: String)] = []
        for (i, item) in items.enumerated() {
            if cancelled() { throw CocoaError(.userCancelled) }
            progress?(i, items.count)
            try autoreleasepool {
                let name = slug(i, item.source)
                let image = try ModernRenderer.render(source: item.source, recipe: item.recipe.sdr)
                try ModernRenderer.export(image, to: images.appendingPathComponent(name), source: item.source, settings: export, metadata: s.keepMetadata ? item.metadata : nil)
                try ModernRenderer.export(image, to: thumbs.appendingPathComponent(name), source: item.source, settings: thumb)
                let scale = min(1, Double(s.imageEdge) / max(image.extent.width, image.extent.height))
                entries.append((name, Int(image.extent.width * scale), Int(image.extent.height * scale), item.title, item.caption))
            }
        }
        progress?(items.count, items.count)
        let figures = entries.enumerated().map { i, e -> String in
            let alt = escape(e.title.isEmpty ? "Photo \(i + 1)" : e.title)
            let caption = s.showCaptions && !(e.title.isEmpty && e.caption.isEmpty)
                ? "<figcaption>" + (e.title.isEmpty ? "" : "<strong>\(escape(e.title))</strong>") + (e.caption.isEmpty ? "" : "<span>\(escape(e.caption))</span>") + "</figcaption>" : ""
            return """
            <figure><a href="images/\(e.file)" data-w="\(e.width)" data-h="\(e.height)" data-caption="\(escape([e.title, e.caption].filter { !$0.isEmpty }.joined(separator: " — ")))"><img src="thumbs/\(e.file)" alt="\(alt)" loading="lazy"></a>\(caption)</figure>
            """
        }.joined(separator: "\n")
        let html = page(title: escape(s.title), subtitle: escape(s.subtitle), dark: s.dark, figures: figures)
        let index = folder.appendingPathComponent("index.html")
        try Data(html.utf8).write(to: index, options: .atomic)
        return index
    }

    static func page(title: String, subtitle: String, dark: Bool, figures: String) -> String {
        let (bg, fg, muted) = dark ? ("#111", "#eee", "#999") : ("#fafafa", "#111", "#666")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="OpenStill">
        <title>\(title)</title>
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        * { box-sizing: border-box; }
        body { margin: 0; background: \(bg); color: \(fg); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
        header { padding: 32px 16px 8px; max-width: 1400px; margin: 0 auto; }
        h1 { margin: 0; font-size: 28px; font-weight: 600; }
        header p { margin: 4px 0 0; color: \(muted); }
        main { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; padding: 16px; max-width: 1400px; margin: 0 auto; }
        figure { margin: 0; }
        figure a { display: block; aspect-ratio: 1; overflow: hidden; border-radius: 6px; background: \(dark ? "#222" : "#e6e6e6"); }
        figure img { width: 100%; height: 100%; object-fit: cover; display: block; transition: transform .3s; }
        figure a:hover img, figure a:focus img { transform: scale(1.03); }
        figcaption { padding: 6px 2px 0; font-size: 13px; color: \(muted); }
        figcaption strong { display: block; color: \(fg); font-weight: 500; }
        #lightbox { position: fixed; inset: 0; background: rgba(0,0,0,.94); display: none; align-items: center; justify-content: center; flex-direction: column; z-index: 10; }
        #lightbox.open { display: flex; }
        #lightbox img { max-width: 96vw; max-height: 86vh; object-fit: contain; }
        #lightbox p { color: #ccc; margin: 12px 16px 0; text-align: center; min-height: 1.5em; }
        #lightbox button { position: absolute; background: none; border: 0; color: #fff; font-size: 34px; padding: 16px; cursor: pointer; opacity: .8; }
        #lightbox button:hover { opacity: 1; }
        #close { top: 0; right: 0; } #prev { left: 0; top: 45%; } #next { right: 0; top: 45%; }
        footer { text-align: center; color: \(muted); font-size: 12px; padding: 24px 16px 40px; }
        </style>
        </head>
        <body>
        <header><h1>\(title)</h1>\(subtitle.isEmpty ? "" : "<p>\(subtitle)</p>")</header>
        <main>
        \(figures)
        </main>
        <footer>Made with OpenStill</footer>
        <div id="lightbox" role="dialog" aria-modal="true" aria-label="Photo viewer">
        <button id="close" aria-label="Close">×</button><button id="prev" aria-label="Previous">‹</button><button id="next" aria-label="Next">›</button>
        <img alt=""><p></p>
        </div>
        <script>
        (function () {
          var links = Array.prototype.slice.call(document.querySelectorAll('main a'));
          var box = document.getElementById('lightbox'), img = box.querySelector('img'), text = box.querySelector('p'), current = 0;
          function show(i) { current = (i + links.length) % links.length; var a = links[current]; img.src = a.getAttribute('href'); img.alt = a.querySelector('img').alt; text.textContent = a.dataset.caption || ''; box.classList.add('open'); }
          function hide() { box.classList.remove('open'); img.removeAttribute('src'); links[current].focus(); }
          links.forEach(function (a, i) { a.addEventListener('click', function (e) { e.preventDefault(); show(i); }); });
          document.getElementById('close').onclick = hide;
          document.getElementById('prev').onclick = function () { show(current - 1); };
          document.getElementById('next').onclick = function () { show(current + 1); };
          box.addEventListener('click', function (e) { if (e.target === box) hide(); });
          document.addEventListener('keydown', function (e) {
            if (!box.classList.contains('open')) return;
            if (e.key === 'Escape') hide(); else if (e.key === 'ArrowLeft') show(current - 1); else if (e.key === 'ArrowRight') show(current + 1);
          });
        })();
        </script>
        </body>
        </html>
        """
    }
}
