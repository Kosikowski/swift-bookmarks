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
        /// SwiftUI `dropDestination`. Access is already started on macOS: the URL is readable
        /// before any start, another start returns `false`, and one stop ends access, so the
        /// grant owes exactly one stop. Verified in the integration host; unverified on Mac
        /// Catalyst, where the library starts it around bookmark creation instead.
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

    /// Whether the system started access for the URL before handing it over, on the platform
    /// the grant was created for.
    public let isStartedBySystem: Bool
    private let stopAccessing: @Sendable (URL) -> Void
    private let use = Mutex(Use.unused)

    private enum Use {
        case unused
        /// A bookmark is being created from the grant.
        case inUse(relinquishRequested: Bool)
        case used
    }

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
        isStartedBySystem = origin.isStartedBySystem(on: platform)
    }

    deinit {
        relinquish()
    }

    /// Whether the grant has been adopted or relinquished.
    public var isConsumed: Bool {
        use.withLock { if case .used = $0 { true } else { false } }
    }

    /// Marks the grant used and balances the access the system started for it. Does nothing
    /// when the grant was already used.
    ///
    /// While a bookmark is being created from the grant, the system's start is still needed,
    /// so the grant is relinquished when creation ends instead.
    func relinquish() {
        let stops = use.withLock { use in
            switch use {
            case .unused:
                use = .used
                return true
            case .inUse:
                use = .inUse(relinquishRequested: true)
                return false
            case .used:
                return false
            }
        }
        balance(stops)
    }

    /// Marks the grant used without balancing the system's start, which the caller takes
    /// over. Returns `false` when the grant is in use or used.
    func takeOver() -> Bool {
        use.withLock { use in
            guard case .unused = use else { return false }
            use = .used
            return true
        }
    }

    /// Reserves the grant for one bookmark creation. Returns `false` when it's already in
    /// use or used, so one grant never backs two creations at once.
    func claim() -> Bool {
        use.withLock { use in
            guard case .unused = use else { return false }
            use = .inUse(relinquishRequested: false)
            return true
        }
    }

    /// Ends the creation that ``claim()`` reserved the grant for, relinquishing it when
    /// `consuming` or when a relinquish arrived meanwhile, and freeing it for another use
    /// otherwise.
    func endUse(consuming: Bool) {
        let stops = use.withLock { use in
            guard case .inUse(let relinquishRequested) = use else { return false }
            guard consuming || relinquishRequested else {
                use = .unused
                return false
            }
            use = .used
            return true
        }
        balance(stops)
    }

    /// This is the only place a grant's system start is balanced, whether the grant is
    /// relinquished, adopted or released.
    private func balance(_ stops: Bool) {
        if stops, isStartedBySystem {
            stopAccessing(url)
        }
    }
}

extension Grant.Origin {
    /// Whether the system starts access for URLs from this origin on `platform`.
    public func isStartedBySystem(on platform: SandboxEnvironment.Platform) -> Bool {
        switch self {
        case .openPanel, .savePanel, .appKitDrop, .finderOpen:
            platform == .macOS || platform == .macCatalyst
        case .swiftUIDrop:
            platform == .macOS
        case .implicitBookmark:
            true
        case .fileImporter, .documentPicker, .alreadyAccessible:
            false
        }
    }
}

/// One bookmark creation's claim on a grant.
///
/// The claim ends once, when the creation work finishes, or when the caller gives up before
/// handing the claim to that work. Work that never runs, because its caller stopped waiting
/// before it started, releases the claim when it's discarded.
final class GrantUse: Sendable {
    let grant: Grant
    private let consuming: Bool
    private let handedOff = Atomic(false)
    private let ended = Atomic(false)

    /// Claims `grant`, or returns `nil` when it's already in use or used.
    ///
    /// - Parameter consuming: Whether ending the claim relinquishes the grant, as adopting
    ///   does, rather than freeing it for another use.
    init?(claiming grant: Grant, consuming: Bool) {
        guard grant.claim() else { return nil }
        self.grant = grant
        self.consuming = consuming
    }

    deinit {
        end()
    }

    /// Passes the claim to work that ends it when it finishes.
    func handOff() {
        handedOff.store(true, ordering: .releasing)
    }

    func end() {
        if !ended.exchange(true, ordering: .acquiringAndReleasing) {
            grant.endUse(consuming: consuming)
        }
    }

    func endUnlessHandedOff() {
        if !handedOff.load(ordering: .acquiring) {
            end()
        }
    }
}
