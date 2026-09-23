public import Foundation

/// A URL the system handed to the app, together with where it came from.
///
/// The origin decides whether the system already started security-scoped access for the URL,
/// which the library balances when it adopts the grant.
public struct Grant: Sendable, Hashable {
    /// Where a granted URL came from.
    public enum Origin: String, Sendable, Hashable, Codable, CaseIterable {
        /// `NSOpenPanel`. Access is already started on macOS.
        case openPanel
        /// `NSSavePanel`. Access is already started on macOS; the file may not exist yet.
        case savePanel
        /// AppKit drag and drop through `NSDraggingInfo`. Access is already started on macOS.
        case appKitDrop
        /// SwiftUI `dropDestination`. Whether the system starts access isn't verified, so the
        /// library starts it around bookmark creation, which works either way.
        case swiftUIDrop
        /// Files opened through Finder, the Dock or a service. Access is already started on macOS.
        case finderOpen
        /// SwiftUI `fileImporter`. Access is not started, on any platform.
        case fileImporter
        /// `UIDocumentPickerViewController`. Access is not started.
        case documentPicker
        /// A URL resolved from an implicit bookmark with implicit start. Access is started.
        case implicitBookmark
        /// A location the app can reach without a grant, such as its container, or any
        /// location when the app isn't sandboxed.
        case alreadyAccessible
    }

    /// The granted URL.
    public let url: URL
    /// Where the URL came from.
    public let origin: Origin

    /// Creates a grant.
    public init(url: URL, origin: Origin) {
        self.url = url
        self.origin = origin
    }

    /// Whether the system started access for the URL before handing it over on `platform`.
    public func isStartedBySystem(on platform: SandboxEnvironment.Platform) -> Bool {
        switch origin {
        case .openPanel, .savePanel, .appKitDrop, .finderOpen:
            platform == .macOS || platform == .macCatalyst
        case .implicitBookmark:
            true
        case .swiftUIDrop, .fileImporter, .documentPicker, .alreadyAccessible:
            false
        }
    }
}
