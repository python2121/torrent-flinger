import Foundation

/// The torrent's file list as a directory tree, for the Files tab.
///
/// Transmission hands back a flat list of paths (`"Super Nintendo/Chrono
/// Trigger.zip"`), which for a 678-file torrent is unreadable and impossible to
/// act on in bulk. Folding it into directories is pure list arithmetic, so it
/// lives here rather than in the view: `FileNode.tree` is the whole feature,
/// and the window only draws it.
public struct FileNode: Identifiable, Equatable, Sendable {
    /// Whether the files underneath this row are set to download.
    public enum Wanted: Equatable, Sendable {
        case on, off, mixed

        /// What a click does: anything not fully checked becomes checked.
        public var toggled: Bool { self != .on }
    }

    /// Stable across refreshes and unique even if a torrent lists the same path
    /// twice: files key off their index, directories off their path.
    public let id: String
    /// Just this level's component — the row shows the tree, not the path.
    public let name: String
    /// Every file index in this subtree, in server order. A file has exactly
    /// one; a directory has all of its descendants', which is what makes
    /// checking or prioritizing a whole folder one RPC call.
    public let indices: [Int]
    public let length: Int64
    public let completed: Int64
    public let wanted: Wanted
    /// Nil when the files underneath disagree.
    public let priority: Int?
    /// Nil for files — `Table`'s outline uses this to decide what gets a
    /// disclosure triangle.
    public let children: [FileNode]?

    public var isDirectory: Bool { children != nil }

    public var donePercent: String {
        String(format: "%.0f%%", Double(completed) / Double(max(length, 1)) * 100)
    }

    /// Fold `files`/`fileStats` into a tree, preserving server order: a
    /// directory appears where its first file did, and files keep their
    /// original order within it. Missing `fileStats` entries fall back to the
    /// documented default (wanted, normal priority), same as the flat list did.
    public static func tree(files: [TorrentFile], stats: [TorrentFileStats]) -> [FileNode] {
        let root = Builder(name: "", path: "")
        for (index, file) in files.enumerated() {
            let stat = index < stats.count ? stats[index] : TorrentFileStats()
            let components = file.name.split(separator: "/").map(String.init)
            var node = root
            for component in components.dropLast() {
                node = node.directory(named: component)
            }
            let leaf = Builder(name: components.last ?? "(unnamed)",
                               path: "f\(index)")
            leaf.file = (index, file.length, stat)
            node.children.append(leaf)
        }
        return root.children.map { $0.build() }
    }

    /// The file indices behind a set of selected rows, deduplicated and in
    /// server order — selecting a folder and one of its files must not send
    /// that file twice.
    public static func indices(for ids: Set<String>, in nodes: [FileNode]) -> [Int] {
        var found: Set<Int> = []
        func walk(_ node: FileNode) {
            if ids.contains(node.id) {
                found.formUnion(node.indices)
                return
            }
            node.children?.forEach(walk)
        }
        nodes.forEach(walk)
        return found.sorted()
    }

    /// Mutable scaffolding: a trie that remembers insertion order, collapsed
    /// into immutable `FileNode`s once every file has been placed.
    private final class Builder {
        let name: String
        let path: String
        var children: [Builder] = []
        /// Directory children by name, so placing a file stays O(depth).
        var directories: [String: Builder] = [:]
        var file: (index: Int, length: Int64, stat: TorrentFileStats)?

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func directory(named component: String) -> Builder {
            if let existing = directories[component] { return existing }
            let child = Builder(name: component,
                                path: path.isEmpty ? component : "\(path)/\(component)")
            directories[component] = child
            children.append(child)
            return child
        }

        func build() -> FileNode {
            if let file {
                return FileNode(id: path, name: name, indices: [file.index],
                                length: file.length, completed: file.stat.bytesCompleted,
                                wanted: file.stat.wanted ? .on : .off,
                                priority: file.stat.priority, children: nil)
            }
            let built = children.map { $0.build() }
            let wanted: FileNode.Wanted =
                built.allSatisfy { $0.wanted == .on } ? .on
                : built.allSatisfy { $0.wanted == .off } ? .off
                : .mixed
            let priorities = Set(built.map(\.priority))
            return FileNode(id: "d:\(path)",
                            name: name,
                            indices: built.flatMap(\.indices),
                            length: built.reduce(0) { $0 + $1.length },
                            completed: built.reduce(0) { $0 + $1.completed },
                            wanted: wanted,
                            priority: priorities.count == 1 ? priorities.first! : nil,
                            children: built)
        }
    }
}
