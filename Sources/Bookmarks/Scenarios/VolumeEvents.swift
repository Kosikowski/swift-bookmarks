#if os(macOS)
public import AppKit
import os

/// A volume that was mounted or unmounted.
public enum VolumeEvent: Sendable, Hashable {
    case mounted(URL)
    case unmounted(URL)

    /// The volume's mount point.
    public var volumeURL: URL {
        switch self {
        case .mounted(let url), .unmounted(let url): url
        }
    }
}

/// Mount and unmount notifications, for re-resolving bookmarks on volumes that come back.
///
/// ```swift
/// Task { await store.refreshStatuses(on: VolumeEvents.stream()) }
/// ```
public enum VolumeEvents {
    /// A stream of volume events. The stream ends when its consumer stops iterating.
    public static func stream(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            let observers = [
                observe(NSWorkspace.didMountNotification, in: notificationCenter, as: VolumeEvent.mounted, into: continuation),
                observe(NSWorkspace.didUnmountNotification, in: notificationCenter, as: VolumeEvent.unmounted, into: continuation),
            ]
            let tokens = ObserverTokens(observers, center: notificationCenter)
            continuation.onTermination = { _ in tokens.remove() }
        }
    }

    private static func observe(
        _ name: Notification.Name,
        in center: NotificationCenter,
        as event: @escaping @Sendable (URL) -> VolumeEvent,
        into continuation: AsyncStream<VolumeEvent>.Continuation
    ) -> any NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: nil) { notification in
            if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                continuation.yield(event(url))
            }
        }
    }
}

extension BookmarkStore {
    /// Refreshes the statuses of records that aren't known to be available each time `events`
    /// reports a mounted volume, until the stream ends or the calling task is cancelled.
    public func refreshStatuses(on events: AsyncStream<VolumeEvent>) async {
        for await event in events {
            guard case .mounted = event else { continue }
            do {
                try await refreshStatuses()
            } catch {
                Log.store.error("Refreshing statuses after a mount failed: \(String(describing: error), privacy: .private)")
            }
        }
    }
}

// Unchecked because observer tokens aren't Sendable; they're immutable after init and only
// passed back to NotificationCenter, which is thread-safe.
private final class ObserverTokens: @unchecked Sendable {
    private let tokens: [any NSObjectProtocol]
    private let center: NotificationCenter

    init(_ tokens: [any NSObjectProtocol], center: NotificationCenter) {
        self.tokens = tokens
        self.center = center
    }

    func remove() {
        tokens.forEach(center.removeObserver)
    }
}
#endif
