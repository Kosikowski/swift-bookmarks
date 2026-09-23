public import Foundation
import os

/// Stores records in a JSON file with atomic, coordinated writes.
///
/// Before each write, the previous file is kept as `<name>.last-good`. Undecodable files are
/// moved to `<name>.corrupt-<timestamp>` and the last good copy is used instead, when
/// ``CorruptionHandling/quarantine`` applies. Records this version can't decode, such as ones
/// written by a newer version, are kept in the file unchanged.
///
/// Several processes can share the file, such as an app and its extensions through an app
/// group: every change is read, applied and written inside one `NSFileCoordinator` write.
public struct JSONFilePersistence<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: BookmarkPersistence {
    /// The file holding the records.
    public let fileURL: URL
    /// What happens to an undecodable file.
    public let corruption: CorruptionHandling
    /// Whether the previous file is kept before each write.
    public let keepsLastGoodCopy: Bool

    /// Creates a persistence backed by `fileURL`.
    public init(fileURL: URL, corruption: CorruptionHandling = .quarantine, keepsLastGoodCopy: Bool = true) {
        self.fileURL = fileURL
        self.corruption = corruption
        self.keepsLastGoodCopy = keepsLastGoodCopy
    }

    /// Where the previous version is kept.
    public var lastGoodURL: URL {
        fileURL.deletingLastPathComponent().appending(path: fileURL.lastPathComponent + ".last-good")
    }

    public func load() throws(PersistenceError) -> [BookmarkRecord<Key, Metadata>] {
        let data: Data?
        do {
            data = try Coordination.read(at: fileURL, options: []) { url in try Self.contents(of: url) }
        } catch {
            throw PersistenceError(.readFailed, underlying: error as NSError)
        }
        return try decode(data).records
    }

    public func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        try update { _ in records }
    }

    /// Reads, transforms and writes the file inside one coordinated write, so another process
    /// coordinating on the same file can't write in between.
    public func update(
        _ transform: ([BookmarkRecord<Key, Metadata>]) -> [BookmarkRecord<Key, Metadata>]?
    ) throws(PersistenceError) {
        do {
            try Coordination.write(at: fileURL, options: .forMerging) { url in
                let data: Data?
                do {
                    data = try Self.contents(of: url)
                } catch {
                    throw PersistenceError(.readFailed, underlying: error as NSError)
                }
                let stored = try decode(data)
                guard let records = transform(stored.records) else { return }
                let encoded = try PersistedEnvelope<Key, Metadata>.encode(records, preserving: stored.preserved, pretty: true)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if keepsLastGoodCopy, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    try? FileManager.default.removeItem(at: lastGoodURL)
                    try? FileManager.default.copyItem(at: url, to: lastGoodURL)
                }
                try encoded.write(to: url, options: .atomic)
            }
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError(.writeFailed, underlying: error as NSError)
        }
    }

    private static func contents(of url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try Data(contentsOf: url)
    }

    private func decode(_ data: Data?) throws(PersistenceError) -> StoredRecords<Key, Metadata> {
        guard let data else { return StoredRecords() }
        do {
            return try PersistedEnvelope<Key, Metadata>.decode(data)
        } catch where error.reason == .unreadable && corruption == .quarantine {
            quarantine()
            return recoverLastGood()
        }
    }

    private func quarantine() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = fileURL.deletingLastPathComponent().appending(path: "\(fileURL.lastPathComponent).corrupt-\(stamp)")
        Log.persistence.error("Stored bookmarks in \(fileURL.lastPathComponent, privacy: .public) are unreadable; moving them aside")
        try? FileManager.default.moveItem(at: fileURL, to: destination)
    }

    private func recoverLastGood() -> StoredRecords<Key, Metadata> {
        guard
            keepsLastGoodCopy,
            let data = try? Self.contents(of: lastGoodURL),
            let stored = try? PersistedEnvelope<Key, Metadata>.decode(data)
        else {
            return StoredRecords()
        }
        return stored
    }

}

extension JSONFilePersistence {
    /// A stream that yields each time the file is created or changed through a coordinated
    /// write, such as a save by another process sharing it.
    ///
    /// Saves by this process are reported too; reloading after them finds nothing new. Pass
    /// the stream to ``BookmarkStore/reload(on:)`` to keep a store current. The stream ends
    /// when its consumer stops iterating. Observing creates the file's folder if it's missing.
    public func changes() -> AsyncStream<Void> {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let presenter = FilePresenter(folder: folder, file: fileURL) { continuation.yield() }
            NSFileCoordinator.addFilePresenter(presenter)
            continuation.onTermination = { _ in NSFileCoordinator.removeFilePresenter(presenter) }
        }
    }
}

/// Presents the file's folder, because presenters of a file aren't told when it's created.
// Unchecked because NSFilePresenter requires an NSObject; every property is immutable, and
// the system calls it on its own serial queue.
private final class FilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let file: NormalizedPath
    private let onChange: @Sendable () -> Void

    init(folder: URL, file: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = folder
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        self.file = NormalizedPath(file.resolvingSymlinksInPath())
        self.onChange = onChange
    }

    func presentedSubitemDidChange(at url: URL) {
        if file.matches(NormalizedPath(url.resolvingSymlinksInPath())) {
            onChange()
        }
    }
}
