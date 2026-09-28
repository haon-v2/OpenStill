import Foundation

/// A folder in the Library's Folders panel: its photos (including subfolders) and its subfolders.
public struct FolderNode: Equatable, Sendable {
    public var name: String
    public var path: String
    /// Photos in this folder and every folder below it.
    public var count: Int
    public var children: [FolderNode]
    public init(name: String, path: String, count: Int, children: [FolderNode] = []) {
        self.name = name; self.path = path; self.count = count; self.children = children
    }
}

/// A drive in the Folders panel, with the top-level folders that hold catalog photos.
public struct FolderVolume: Equatable, Sendable {
    public var name: String
    public var path: String
    public var count: Int
    public var folders: [FolderNode]
    /// False when the drive isn't connected (its photos show as missing).
    public var online: Bool
}

/// Lightroom Classic's Folders panel: drives, then the folder hierarchy of the catalog's photos, with counts.
public enum FolderTree {
    /// The system drive's name when none is found.
    public static var startupDiskName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }

    /// Groups photo paths by drive. On each drive the chain of single folders above the photos is skipped,
    /// so the top level starts where your photos branch out (for example "2024" rather than "/Users/you/Pictures/2024").
    public static func volumes(_ photoPaths: [String], startupName: String = startupDiskName,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [FolderVolume] {
        var byVolume: [String: (name: String, dirs: [String])] = [:]
        for path in photoPaths {
            let directory = (path as NSString).deletingLastPathComponent
            let (root, name) = volume(of: directory, startupName: startupName)
            byVolume[root, default: (name, [])].dirs.append(directory)
        }
        return byVolume.map { root, entry in
            let trie = Trie(path: root, name: entry.name)
            for directory in entry.dirs { trie.insert(relative(directory, to: root)) }
            return FolderVolume(name: entry.name, path: root, count: entry.dirs.count, folders: topLevel(trie), online: exists(root))
        }
        .sorted { a, b in
            // The startup disk first, then external drives by name.
            if (a.path == "/") != (b.path == "/") { return a.path == "/" }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The drive a folder is on: "/Volumes/Name" for external drives, "/" for the startup disk.
    static func volume(of directory: String, startupName: String) -> (root: String, name: String) {
        let parts = directory.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" { return ("/Volumes/" + parts[1], String(parts[1])) }
        return ("/", startupName)
    }
    private static func relative(_ directory: String, to root: String) -> [String] {
        let rest = root == "/" ? directory : String(directory.dropFirst(root.count))
        return rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private final class Trie {
        let path: String, name: String
        var direct = 0, total = 0
        var children: [String: Trie] = [:]
        init(path: String, name: String) { self.path = path; self.name = name }
        func insert(_ components: [String]) {
            total += 1
            guard let first = components.first else { direct += 1; return }
            let childPath = path == "/" ? "/" + first : path + "/" + first
            let child = children[first] ?? Trie(path: childPath, name: first)
            children[first] = child
            child.insert(Array(components.dropFirst()))
        }
        var sortedChildren: [Trie] { children.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        var node: FolderNode { FolderNode(name: name, path: path, count: total, children: sortedChildren.map(\.node)) }
    }

    /// Skips folders that only lead to one subfolder and hold no photos themselves.
    private static func topLevel(_ root: Trie) -> [FolderNode] {
        var node = root
        while node.direct == 0, node.children.count == 1, let only = node.children.values.first { node = only }
        // On the drive itself, list its folders; otherwise show the folder where your photos branch out.
        return node === root ? node.sortedChildren.map(\.node) : [node.node]
    }
}
