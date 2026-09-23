#if os(macOS)
public import AppKit

/// Presents `NSOpenPanel` and returns what the user picked as grants.
@MainActor
public enum OpenPanelPicker {
    /// Shows an open panel and returns the picked items, or an empty array when cancelled.
    ///
    /// The returned grants have access already started by the system. Adopt them with
    /// ``Bookmarks/adopt(_:kind:relativeTo:includingResourceValuesFor:validators:context:)``
    /// or ``BookmarkStore/add(_:key:metadata:)``, or relinquish them.
    public static func choose(_ configuration: PickerConfiguration, attachedTo window: NSWindow? = nil) async -> [Grant] {
        let panel = NSOpenPanel()
        configure(panel, with: configuration)
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK else { return [] }
        return GrantMapping.grants(from: panel.urls, origin: .openPanel)
    }

    /// Applies a configuration to an open panel.
    public static func configure(_ panel: NSOpenPanel, with configuration: PickerConfiguration) {
        panel.message = configuration.message
        if let prompt = configuration.prompt {
            panel.prompt = prompt
        }
        panel.directoryURL = configuration.directoryURL
        panel.canChooseDirectories = configuration.allowsFolders
        panel.canChooseFiles = configuration.allowsFiles
        panel.allowedContentTypes = configuration.allowedContentTypes
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection
        panel.canCreateDirectories = configuration.canCreateFolders
        panel.showsHiddenFiles = configuration.showsHiddenFiles
        panel.resolvesAliases = true
    }
}

extension BookmarkStore {
    /// Asks the user to pick the item for `key` again, starting next to its last known
    /// location, and replaces its bookmark.
    ///
    /// - Returns: The updated record, or `nil` when the user cancelled.
    @MainActor
    public func regrantWithOpenPanel(
        _ key: Key,
        message: String? = nil,
        prompt: String? = nil,
        attachedTo window: NSWindow? = nil
    ) async throws(Failure) -> Record? {
        guard let record = try record(key) else { throw .notFound(key) }
        let configuration = RegrantConfiguration.make(
            for: record,
            recorded: bookmarks.recordedValues(in: record.data),
            message: message,
            prompt: prompt
        )
        guard let grant = await OpenPanelPicker.choose(configuration, attachedTo: window).first else {
            return nil
        }
        return try await regrant(key, with: grant)
    }
}
#endif
