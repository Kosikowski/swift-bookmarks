public import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Creates and resolves bookmark bytes and starts and stops security-scoped access.
///
/// Engines are the only boundary between the library and the operating system. Calls that
/// create, resolve or inspect bookmarks may block, so the library makes them through a
/// ``BlockingExecutor``. ``startAccessing(_:)`` and ``stopAccessing(_:)`` are different: they run
/// synchronously on whichever thread begins or ends a lease, including actors and the main
/// thread, while the library holds its locks. They must return quickly and must not call back
/// into the library. Every method must be safe to call from any thread.
/// ``SystemBookmarkEngine`` is the real implementation; `BookmarksTesting` provides a fake.
public protocol BookmarkEngine: Sendable {
    /// The environment the engine operates in.
    var environment: SandboxEnvironment { get }

    /// Creates bookmark bytes for `url`.
    func makeBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions,
        includingResourceValuesFor keys: Set<URLResourceKey>,
        relativeTo document: URL?
    ) throws -> BookmarkData

    /// Resolves bookmark bytes to a URL and reports whether they are stale.
    func resolve(
        _ data: BookmarkData,
        options: URL.BookmarkResolutionOptions,
        relativeTo document: URL?
    ) throws -> (url: URL, isStale: Bool)

    /// Reads what the bookmark recorded about its target, without resolving it.
    func recordedValues(in data: BookmarkData) -> RecordedValues?

    /// Starts security-scoped access to `url`. Returns whether there is now access to balance.
    ///
    /// Called synchronously on the caller's thread while the library holds its locks.
    func startAccessing(_ url: URL) -> Bool

    /// Balances one successful ``startAccessing(_:)``.
    ///
    /// Called synchronously on the caller's thread while the library holds its locks.
    func stopAccessing(_ url: URL)
}

/// Inspects items on disk, for validation, failure classification and duplicate detection.
public protocol ItemInspecting: Sendable {
    /// Whether a volume is mounted at `path`.
    ///
    /// A folder left where a volume used to be mounted, such as an empty `/Volumes/Backup`
    /// after an unclean unmount, isn't a mounted volume.
    func isVolumeMounted(atPath path: String) -> Bool

    /// The item's path-independent identity, or `nil` when the volume doesn't report both a
    /// file identifier and a volume UUID.
    func fileIdentity(of url: URL) -> FileIdentity?

    /// Describes the item at `url`, or `nil` when it can't be inspected.
    func itemInfo(at url: URL) -> ItemInfo?

    /// Whether an item exists at `path`, or `nil` when that can't be told, such as when the
    /// sandbox refuses to look.
    ///
    /// Tells a deleted item from a scope key that doesn't match, since inside the App Sandbox
    /// both fail resolution the same way. The default implementation asks `lstat`, and only
    /// its "no such file" answer counts as absent.
    func itemExists(atPath path: String) -> Bool?

    /// Whether the item with `identity` still exists anywhere on its volume, or `nil` when
    /// that can't be told, such as when the volume isn't mounted or the sandbox refuses to look.
    ///
    /// Tells an item that moved from one that was deleted when its bookmark can't say, as a
    /// scoped bookmark whose key doesn't match can't inside the App Sandbox. The default
    /// implementation asks `fsgetpath` on macOS and can't tell elsewhere.
    func itemExists(withIdentity identity: FileIdentity) -> Bool?

    /// Whether names on the volume that holds `url` differ by case.
    ///
    /// When nothing exists at `url`, its nearest existing ancestor decides. Return `true` when
    /// unsure: comparing paths case-sensitively on a volume that ignores case only costs extra
    /// system starts, while the opposite could map a path onto a different item.
    func namesAreCaseSensitive(at url: URL) -> Bool
}

extension ItemInspecting {
    public func itemExists(atPath path: String) -> Bool? {
        var info = stat()
        if lstat(path, &info) == 0 {
            return true
        }
        return errno == ENOENT || errno == ENOTDIR ? false : nil
    }

    public func itemExists(withIdentity identity: FileIdentity) -> Bool? {
        #if os(macOS)
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        guard let volume = volumes.first(where: {
            (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == identity.volumeUUID
        }) else {
            return nil
        }
        guard var fsid = filesystemID(atPath: volume.path(percentEncoded: false)) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fsgetpath(&buffer, buffer.count, &fsid, identity.fileID) >= 0 {
            return true
        }
        return errno == ENOENT ? false : nil
        #else
        return nil
        #endif
    }
}

#if os(macOS)
/// The filesystem ID of the volume that holds `path`, the `fsid_t` `fsgetpath` takes, or `nil`
/// when it can't be read.
///
/// Read with `getattrlist` and `ATTR_CMN_FSID` rather than `statfs`: Apple lists `statfs`
/// among the disk-space APIs an app's privacy manifest has to declare a reason for, and none
/// of that category's reasons covers reading a filesystem ID. `getattrlist` is in the file
/// timestamp category, which `itemExists(atPath:)`'s `lstat` already puts an app in.
func filesystemID(atPath path: String) -> fsid_t? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_FSID)
    // The reply: its length as a `u_int32_t`, then the `fsid_t`.
    var reply = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size + MemoryLayout<fsid_t>.size)
    let result = reply.withUnsafeMutableBytes { buffer in
        getattrlist(path, &request, buffer.baseAddress, buffer.count, 0)
    }
    guard result == 0 else { return nil }
    return reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: fsid_t.self) }
}
#endif

/// Reads and writes Finder alias files.
public protocol AliasFileAccessing: Sendable {
    /// Writes alias-file bookmark bytes to `url`.
    func writeAliasFile(_ data: BookmarkData, to url: URL) throws

    /// Reads the bookmark bytes stored in the alias file at `url`.
    func aliasFileData(at url: URL) throws -> BookmarkData
}

/// Replaces items the way a safe save does.
///
/// The default implementation writes the replacement into a temporary folder on the item's
/// volume and swaps it in with `FileManager.replaceItemAt(_:withItemAt:)`, which keeps the
/// item's extended attributes. Engines that don't touch real files, such as the fake one in
/// tests, override it.
public protocol ItemReplacing: Sendable {
    /// Replaces the item at `url` with a file that `write` writes to the URL it's given,
    /// keeping the item's extended attributes, such as the key of document-scoped bookmarks
    /// anchored on it.
    func replaceItem(at url: URL, writing write: (URL) throws -> Void) throws
}

extension ItemReplacing {
    public func replaceItem(at url: URL, writing write: (URL) throws -> Void) throws {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let replacement = folder.appending(path: url.lastPathComponent)
        try write(replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
    }
}

/// Everything ``BookmarkService`` needs from the system.
public typealias FileSystemEngine = BookmarkEngine & ItemInspecting & AliasFileAccessing & ItemReplacing
