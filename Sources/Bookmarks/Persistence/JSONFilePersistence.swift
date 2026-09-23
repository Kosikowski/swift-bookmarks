public import Foundation
import os

/// Stores records in a JSON file with atomic, coordinated writes.
///
/// Before each write, the previous file is kept as `<name>.last-good`. Undecodable files are
/// moved to `<name>.corrupt-<timestamp>` and the last good copy is used instead, when
/// ``CorruptionHandling/quarantine`` applies.
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
        guard let data = try read(fileURL) else { return [] }
        do {
            return try PersistedEnvelope<Key, Metadata>.decode(data)
        } catch where error.reason == .unreadable && corruption == .quarantine {
            quarantine()
            return recoverLastGood()
        }
    }

    public func save(_ records: [BookmarkRecord<Key, Metadata>]) throws(PersistenceError) {
        let data = try PersistedEnvelope<Key, Metadata>.encode(records, pretty: true)
        do {
            try coordinate(writing: fileURL) { url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if keepsLastGoodCopy, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    try? FileManager.default.removeItem(at: lastGoodURL)
                    try? FileManager.default.copyItem(at: url, to: lastGoodURL)
                }
                try data.write(to: url, options: .atomic)
            }
        } catch {
            throw PersistenceError(.writeFailed, underlying: error as NSError)
        }
    }

    private func read(_ url: URL) throws(PersistenceError) -> Data? {
        do {
            return try coordinate(reading: url) { url in
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
                return try Data(contentsOf: url)
            }
        } catch {
            throw PersistenceError(.readFailed, underlying: error as NSError)
        }
    }

    private func quarantine() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = fileURL.deletingLastPathComponent().appending(path: "\(fileURL.lastPathComponent).corrupt-\(stamp)")
        Log.persistence.error("Stored bookmarks in \(fileURL.lastPathComponent, privacy: .public) are unreadable; moving them aside")
        try? FileManager.default.moveItem(at: fileURL, to: destination)
    }

    private func recoverLastGood() -> [BookmarkRecord<Key, Metadata>] {
        guard
            keepsLastGoodCopy,
            let data = try? read(lastGoodURL),
            let records = try? PersistedEnvelope<Key, Metadata>.decode(data)
        else {
            return []
        }
        return records
    }

    private func coordinate<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    private func coordinate(writing url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var result: Result<Void, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        try result!.get()
    }
}
