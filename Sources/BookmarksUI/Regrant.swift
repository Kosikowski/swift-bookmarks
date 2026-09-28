public import Bookmarks
import Foundation
public import UniformTypeIdentifiers

extension BookmarkStore {
    /// A picker configuration for picking the item stored under `key` again: it starts in the
    /// folder that held the item and offers folders or files as the item was one.
    ///
    /// The bookmark's recorded values say which the item was. For a path-only record, the
    /// item at its path does, and without either a path without an extension counts as a
    /// folder. The same configuration drives ``regrantWithOpenPanel(_:message:prompt:attachedTo:)``,
    /// ``regrantWithDocumentPicker(_:from:fileTypes:)`` and the SwiftUI
    /// `bookmarkRegrant(of:in:message:prompt:fileTypes:onCompletion:)` modifier.
    public func regrantConfiguration(
        for key: Key,
        message: String? = nil,
        prompt: String? = nil,
        fileTypes: [UTType] = [.item]
    ) async throws(Failure) -> PickerConfiguration {
        guard let record = try await record(key) else { throw .notFound(key) }
        var recorded = service.recordedValues(in: record.data)
        if recorded == nil {
            let engine = service.engine
            let path = record.lastKnownPath
            let info = try? await service.executor.run(timeout: service.timeout) { engine.itemInfo(at: URL(filePath: path)) }
            recorded = info.map { RecordedValues(path: path, isDirectory: $0.isDirectory) }
        }
        return RegrantConfiguration.make(for: record, recorded: recorded, message: message, prompt: prompt, fileTypes: fileTypes)
    }

    /// Re-grants `key` with the first of `grants`, as a picker returned them, and relinquishes
    /// the rest.
    ///
    /// - Returns: The updated record, or `nil` when `grants` is empty because the user
    ///   cancelled.
    @discardableResult
    public func regrant(_ key: Key, withFirstOf grants: [Grant]) async throws(Failure) -> Record? {
        guard let grant = grants.first else { return nil }
        service.relinquish(grants.dropFirst())
        return try await regrant(key, with: grant)
    }
}
