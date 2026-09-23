public import Foundation
import Synchronization

/// A URL the system handed to the app, together with where it came from.
///
/// The origin decides whether the system already started security-scoped access for the URL.
/// A grant is used once: adopting it or relinquishing it balances that access, and later
/// attempts do nothing. A grant released without either balances the access itself, so
/// ignoring what a picker returned doesn't leak a scope.
public final class Grant: Sendable {
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

    private let startedBySystem: Bool
    private let stopAccessing: @Sendable (URL) -> Void
    private let consumed = Atomic<Bool>(false)

    /// Creates a grant for a URL the system handed to this process.
    public convenience init(url: URL, origin: Origin) {
        self.init(url: url, origin: origin, platform: SandboxEnvironment.current.platform) { url in
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Creates a grant whose unused system start is balanced by `stopAccessing`, for engines
    /// other than the system's.
    public init(
        url: URL,
        origin: Origin,
        platform: SandboxEnvironment.Platform,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        self.url = url
        self.origin = origin
        self.stopAccessing = stopAccessing
        startedBySystem = Self.isStartedBySystem(origin, on: platform)
    }

    deinit {
        if claim(), startedBySystem {
            stopAccessing(url)
        }
    }

    /// Whether the grant has been adopted or relinquished.
    public var isConsumed: Bool {
        consumed.load(ordering: .acquiring)
    }

    /// Marks the grant used. Returns `false` when it already was.
    func claim() -> Bool {
        !consumed.exchange(true, ordering: .acquiringAndReleasing)
    }

    /// Whether the system started access for the URL before handing it over on `platform`.
    public func isStartedBySystem(on platform: SandboxEnvironment.Platform) -> Bool {
        Self.isStartedBySystem(origin, on: platform)
    }

    private static func isStartedBySystem(_ origin: Origin, on platform: SandboxEnvironment.Platform) -> Bool {
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
