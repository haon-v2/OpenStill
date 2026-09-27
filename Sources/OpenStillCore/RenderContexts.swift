import Foundation
import CoreImage
import Metal

/// Long-lived Core Image contexts on one Metal device. Creating a context is expensive (it compiles and caches GPU programs),
/// so the app keeps a few for its whole life instead of making one per render.
public enum RenderContexts {
    /// The Mac's default GPU. Nil only without Metal, when Core Image falls back to its own choice.
    public static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    /// A context with Core Image's default color handling, for masks, overlays and other small utility images.
    public static let utility = make([:])
    /// How many contexts were created, for tests that check nothing makes throwaway ones.
    nonisolated(unsafe) public private(set) static var created = 0
    private static let lock = NSLock()

    public static func make(_ options: [CIContextOption: Any]) -> CIContext {
        lock.lock(); created += 1; lock.unlock()
        var options = options
        options[.name] = options[.name] ?? "OpenStill"
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }
}
