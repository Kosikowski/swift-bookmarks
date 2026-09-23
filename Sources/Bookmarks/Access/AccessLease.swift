public import Foundation
import Synchronization

/// A balanced claim on security-scoped access to a resolved item.
///
/// Use ``url`` for all file access while the lease is active, and derive children from it
/// with `appending(path:)` or ``url(forDescendant:)``. A URL rebuilt from a path string
/// doesn't carry the scope. Ending a lease is idempotent, and a lease that is deallocated
/// without being ended ends itself.
public final class AccessLease: Sendable {
    /// The resolved URL that carries the scope.
    public let url: URL
    /// Whether the system start call succeeded.
    ///
    /// `false` is normal outside the App Sandbox and for locations the app can already reach.
    /// It is not an error: only a failing file operation proves missing access.
    public let didStartScope: Bool

    private let handle: ScopeHandle
    private let cycle: UInt64
    private let ended = Atomic<Bool>(false)

    convenience init(handle: ScopeHandle) {
        self.init(handle: handle, acquisition: handle.acquire())
    }

    /// A lease joining the handle's current holders, or `nil` when the handle is idle.
    convenience init?(activeHandle handle: ScopeHandle) {
        guard let acquisition = handle.acquireIfActive() else { return nil }
        self.init(handle: handle, acquisition: acquisition)
    }

    private init(handle: ScopeHandle, acquisition: ScopeHandle.Acquisition) {
        self.handle = handle
        url = handle.url
        didStartScope = acquisition.didStart
        cycle = acquisition.cycle
    }

    deinit {
        end()
    }

    /// Releases this claim. Access stops when the last lease on the same item ends.
    public func end() {
        guard !ended.exchange(true, ordering: .acquiringAndReleasing) else { return }
        handle.release(cycle: cycle)
    }

    /// Whether the lease still holds access. It doesn't once ended or after ``AccessRegistry/endAll()``.
    public var isActive: Bool {
        !ended.load(ordering: .acquiring) && handle.isCurrent(cycle: cycle)
    }

    /// Maps a URL inside the leased directory to one derived from ``url``, so it keeps the scope.
    ///
    /// Returns `nil` when `descendant` isn't the leased item or inside it.
    public func url(forDescendant descendant: URL) -> URL? {
        guard let components = handle.path.relativeComponents(of: NormalizedPath(descendant)) else {
            return nil
        }
        return components.reduce(url) { partial, component in
            partial.appending(path: component, directoryHint: .inferFromPath)
        }
    }
}
