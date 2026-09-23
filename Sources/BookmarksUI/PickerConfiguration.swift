@_exported public import Bookmarks
public import Foundation
public import UniformTypeIdentifiers

/// What a folder or file picker offers.
public struct PickerConfiguration: Sendable, Hashable {
    /// Text shown in the picker, such as why access is needed.
    public var message: String?
    /// The title of the confirm button.
    public var prompt: String?
    /// Where the picker starts.
    public var directoryURL: URL?
    /// Whether folders can be picked.
    public var allowsFolders: Bool
    /// The file types that can be picked. Empty means no files.
    public var allowedContentTypes: [UTType]
    /// Whether several items can be picked at once.
    public var allowsMultipleSelection: Bool
    /// Whether the user can create folders in the picker (macOS).
    public var canCreateFolders: Bool
    /// Whether hidden files are shown (macOS).
    public var showsHiddenFiles: Bool

    /// Creates a configuration.
    public init(
        message: String? = nil,
        prompt: String? = nil,
        directoryURL: URL? = nil,
        allowsFolders: Bool = true,
        allowedContentTypes: [UTType] = [],
        allowsMultipleSelection: Bool = false,
        canCreateFolders: Bool = false,
        showsHiddenFiles: Bool = false
    ) {
        self.message = message
        self.prompt = prompt
        self.directoryURL = directoryURL
        self.allowsFolders = allowsFolders
        self.allowedContentTypes = allowedContentTypes
        self.allowsMultipleSelection = allowsMultipleSelection
        self.canCreateFolders = canCreateFolders
        self.showsHiddenFiles = showsHiddenFiles
    }

    /// Picks one folder.
    public static func folder(message: String? = nil, directoryURL: URL? = nil) -> PickerConfiguration {
        PickerConfiguration(message: message, directoryURL: directoryURL)
    }

    /// Picks files of the given types.
    public static func files(_ types: [UTType], multiple: Bool = false, message: String? = nil) -> PickerConfiguration {
        PickerConfiguration(message: message, allowsFolders: false, allowedContentTypes: types, allowsMultipleSelection: multiple)
    }

    /// The content types a system picker should offer.
    public var pickerContentTypes: [UTType] {
        allowsFolders ? [.folder] + allowedContentTypes : allowedContentTypes
    }

    /// Whether files can be picked.
    public var allowsFiles: Bool {
        !allowedContentTypes.isEmpty
    }
}

/// Builds a picker configuration for re-granting access to a stored item.
public enum RegrantConfiguration {
    /// A configuration that starts in the folder that held the item.
    ///
    /// The picker offers folders when the bookmark recorded a folder, and files of
    /// `fileTypes` otherwise. Without recorded values, a path without an extension counts as
    /// a folder.
    public static func make<Key, Metadata>(
        for record: BookmarkRecord<Key, Metadata>,
        recorded: RecordedValues?,
        message: String? = nil,
        prompt: String? = nil,
        fileTypes: [UTType] = [.item]
    ) -> PickerConfiguration {
        let lastKnown = URL(filePath: record.lastKnownPath)
        let isFolder = recorded?.isDirectory ?? lastKnown.pathExtension.isEmpty
        return PickerConfiguration(
            message: message,
            prompt: prompt,
            directoryURL: lastKnown.deletingLastPathComponent(),
            allowsFolders: isFolder,
            allowedContentTypes: isFolder ? [] : fileTypes
        )
    }
}

/// Turns picker results into grants.
public enum GrantMapping {
    /// Grants for URLs a system picker returned.
    public static func grants(from urls: [URL], origin: Grant.Origin) -> [Grant] {
        urls.filter(\.isFileURL).map { Grant(url: $0, origin: origin) }
    }

    /// Grants for a SwiftUI `fileImporter` result.
    public static func grants(from result: Result<[URL], any Error>) -> Result<[Grant], any Error> {
        result.map { grants(from: $0, origin: .fileImporter) }
    }
}
