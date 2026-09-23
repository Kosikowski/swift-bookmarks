public import Foundation
import os
import Synchronization

/// Tracks every active scope in the process, whichever store, registry or resolved bookmark
/// holds it.
///
/// The kernel limits sandbox extensions per process, not per store, so the count and the
/// soft-limit warning live here. The ledger also finds active scopes that cover a location,
/// so a lease on a file inside a folder that any part of the app holds reuses that folder's
/// access instead of starting another.
public final class ScopeLedger: Sendable {
    /// The ledger that ``BookmarkService`` and ``AccessRegistry`` use by default.
    public static let shared = ScopeLedger()

    private struct Entry {
        let handle: ScopeHandle
        let started: Bool
    }

    /// The number of started scopes above which the ledger logs a warning.
    public let softLimit: Int
    private let entries = Mutex<[ObjectIdentifier: Entry]>([:])
    private let warned = Atomic<Bool>(false)

    /// Creates a ledger.
    ///
    /// - Parameter softLimit: The number of started scopes above which the ledger logs a
    ///   warning. The kernel limit is roughly 1,000 to 2,500 per process and can't be queried.
    public init(softLimit: Int = 500) {
        self.softLimit = softLimit
    }

    /// The number of scopes whose system start succeeded and is still held.
    public var startedScopeCount: Int {
        entries.withLock { $0.values.count { $0.started } }
    }

    /// Whether the number of started scopes has exceeded the soft limit at some point.
    public var hasExceededSoftLimit: Bool {
        warned.load(ordering: .relaxed)
    }

    /// A new lease on the deepest active scope that contains `url` and grants `access`, or
    /// `nil` when none does.
    ///
    /// Scopes from bookmarks that carry no access, such as reference bookmarks, never match.
    public func lease(covering url: URL, access: AccessMode = .readWrite) -> AccessLease? {
        let target = NormalizedPath(url)
        let candidates = entries.withLock { entries in
            entries.values
                .map(\.handle)
                .filter { $0.access.map { $0.satisfies(access) } ?? false && $0.path.contains(target) }
                .sorted { $0.path.components.count > $1.path.components.count }
        }
        // Handles are acquired outside the ledger's lock: a handle calls the ledger while it
        // holds its own lock, so the ledger never waits for a handle.
        for handle in candidates {
            if let lease = AccessLease(activeHandle: handle) {
                return lease
            }
        }
        return nil
    }

    /// Called under the handle's lock when its first holder arrives.
    func activated(_ handle: ScopeHandle, started: Bool) {
        let count = entries.withLock { entries in
            entries[ObjectIdentifier(handle)] = Entry(handle: handle, started: started)
            return entries.values.count { $0.started }
        }
        if count > softLimit, !warned.exchange(true, ordering: .relaxed) {
            Log.access.error("\(count, privacy: .public) security scopes are active; the kernel limit is near")
        }
    }

    /// Called under the handle's lock when its last holder leaves or it's invalidated.
    func deactivated(_ handle: ScopeHandle) {
        entries.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(handle)) }
    }
}

extension AccessMode {
    func satisfies(_ needed: AccessMode) -> Bool {
        self == .readWrite || needed == .readOnly
    }
}
