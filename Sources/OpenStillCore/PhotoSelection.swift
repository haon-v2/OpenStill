import Foundation

public struct PhotoSelection {
    public private(set) var indices: Set<Int> = []
    public private(set) var active: Int?
    private var anchor: Int?
    public init() {}

    public mutating func click(_ index: Int, extending: Bool = false, toggling: Bool = false) {
        guard index >= 0 else { return }
        if extending, let anchor {
            let range = Set(min(anchor, index)...max(anchor, index))
            indices = toggling ? indices.union(range) : range
            active = index
        } else if toggling {
            if indices.contains(index) { indices.remove(index) }
            else { indices.insert(index) }
            active = indices.contains(index) ? index : indices.sorted().first
            anchor = active
        } else {
            indices = [index]
            active = index
            anchor = index
        }
    }
    public mutating func selectAll(count: Int) {
        indices = Set(0..<max(0, count))
        active = active.flatMap { indices.contains($0) ? $0 : nil } ?? indices.sorted().first
        anchor = active
    }
    public mutating func extend(by step: Int, count: Int) {
        guard count > 0 else { return }
        click(min(count - 1, max(0, (active ?? 0) + step)), extending: true)
    }
}
