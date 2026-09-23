import Bookmarks
import Foundation

struct FakeItem: Sendable {
    let id: UInt64
    var isDirectory: Bool
    var linkTarget: String?
}

struct ScriptedFailure: Sendable {
    let error: NSError
    var remaining: Int?
}

struct FakeFileSystem: Sendable {
    var items: [String: FakeItem] = ["/": FakeItem(id: 1, isDirectory: true)]
    var nextItemID: UInt64 = 2
    var mountedVolumes: Set<String> = ["/"]
    var caseInsensitiveVolumes: Set<String> = []
    var volumesWithoutUUID: Set<String> = []
    var freelyAccessible: Set<String> = []
    var aliasFiles: [String: BookmarkData] = [:]

    var issued: Set<String> = []
    var outstanding: [String: Int] = [:]
    var unbalancedStops: [String] = []
    var unissuedStarts: [String] = []
    var refused: Set<String> = []

    var resolutionFailures: [String: ScriptedFailure] = [:]
    var creationFailures: [String: ScriptedFailure] = [:]
    var forcedStale: [String: Int] = [:]
    var gates: [String: [FakeBookmarkEngine.Gate]] = [:]
    var creationGates: [String: [FakeBookmarkEngine.Gate]] = [:]

    var calls = FakeBookmarkEngine.Calls()
    var creationRequests: [FakeBookmarkEngine.CreationRequest] = []
    var resolutionRequests: [FakeBookmarkEngine.ResolutionRequest] = []
    var serial = 0

    static func volume(of path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Volumes" else { return "/" }
        return "/Volumes/\(components[1])"
    }

    static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        ancestor == "/" || path == ancestor || path.hasPrefix(ancestor + "/")
    }

    func item(at path: String) -> FakeItem? {
        guard mountedVolumes.contains(Self.volume(of: path)) else { return nil }
        return items[path]
    }

    func isDirectory(_ path: String) -> Bool {
        items[path]?.isDirectory ?? false
    }

    func canonicalPath(_ path: String) -> String {
        var resolved = "/"
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let next = resolved == "/" ? "/\(component)" : "\(resolved)/\(component)"
            resolved = items[next]?.linkTarget.map(canonicalPath) ?? next
        }
        return resolved
    }

    func path(ofItem id: UInt64) -> String? {
        items.first { $0.value.id == id && mountedVolumes.contains(Self.volume(of: $0.key)) }?.key
    }

    func hasAccess(to path: String) -> Bool {
        if freelyAccessible.contains(where: { Self.isDescendant(path, of: $0) }) {
            return true
        }
        return outstanding.contains { $0.value > 0 && Self.isDescendant(path, of: $0.key) }
    }

    mutating func addItem(at path: String, isDirectory: Bool) {
        if let parent = Self.parent(of: path), items[parent] == nil {
            addItem(at: parent, isDirectory: true)
        }
        if items[path] == nil {
            items[path] = FakeItem(id: nextItemID, isDirectory: isDirectory)
            nextItemID += 1
        }
    }

    mutating func addSymbolicLink(at path: String, to target: String) {
        addItem(at: path, isDirectory: false)
        items[path]?.linkTarget = target
        items[path]?.isDirectory = false
    }

    mutating func removeItem(at path: String) {
        for key in items.keys where Self.isDescendant(key, of: path) && key != "/" {
            items[key] = nil
        }
    }

    mutating func moveItem(from source: String, to destination: String) {
        if let parent = Self.parent(of: destination), items[parent] == nil {
            addItem(at: parent, isDirectory: true)
        }
        // Moving to another volume copies and deletes, so the items get new identities.
        let acrossVolumes = Self.volume(of: source) != Self.volume(of: destination)
        let moving = items.filter { Self.isDescendant($0.key, of: source) }
        for (path, item) in moving.sorted(by: { $0.key < $1.key }) {
            items[path] = nil
            var moved = item
            if acrossVolumes {
                moved = FakeItem(id: nextItemID, isDirectory: item.isDirectory, linkTarget: item.linkTarget)
                nextItemID += 1
            }
            items[destination + String(path.dropFirst(source.count))] = moved
        }
    }

    mutating func replaceItem(at path: String) {
        guard let existing = items[path] else { return }
        items[path] = FakeItem(id: nextItemID, isDirectory: existing.isDirectory)
        nextItemID += 1
    }

    mutating func recordStart(_ path: String) {
        outstanding[path, default: 0] += 1
    }

    static func consumeFailure(_ failures: inout [String: ScriptedFailure], for path: String) -> NSError? {
        guard var failure = failures[path] else { return nil }
        if let remaining = failure.remaining {
            failure.remaining = remaining - 1
            failures[path] = remaining - 1 > 0 ? failure : nil
        }
        return failure.error
    }
}
