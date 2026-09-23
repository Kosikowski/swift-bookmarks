import Foundation

/// Passes access to an item to another process, such as an XPC service or a login item.
///
/// App-scoped bookmarks only resolve in the app that created them. A handoff token is a
/// regular bookmark that carries access implicitly: any process that resolves it gains
/// access until the next reboot. Send it over a private channel and never persist it.
///
/// With `NSXPCConnection`, sending the lease's URL directly also carries its scope and is an
/// alternative to tokens.
public struct Handoff: Sendable {
    /// The bookmark service.
    public let service: BookmarkService

    /// Creates a handoff helper.
    public init(service: BookmarkService = BookmarkService()) {
        self.service = service
    }

    /// Creates a token for the item behind an active lease.
    public func makeToken(for lease: AccessLease) async throws(BookmarkError) -> BookmarkData {
        guard lease.isActive else {
            throw BookmarkError(.denied, lastKnownPath: lease.url.path(percentEncoded: false))
        }
        return try await service.create(for: Grant(url: lease.url, origin: .alreadyAccessible), kind: .implicit)
    }

    /// Resolves a token received from another process and takes over the access it carries.
    ///
    /// End the returned lease when done; it balances the access started by resolution.
    public func receive(_ token: BookmarkData) async throws(BookmarkError) -> AccessLease {
        let resolved = try await service.resolve(token, kind: .implicit, policy: ResolutionPolicy(startsImplicitAccess: true))
        return resolved.beginAccess()
    }
}
