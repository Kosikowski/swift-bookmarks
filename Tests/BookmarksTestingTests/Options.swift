import Bookmarks
import Foundation

// The SDK names these options only on macOS and Mac Catalyst; the fake engine reads their bits
// on every platform, so the tests spell them by value.
extension URL.BookmarkCreationOptions {
    /// `.withSecurityScope`.
    static let scope = URL.BookmarkCreationOptions(rawValue: 1 << 11)
    /// `.securityScopeAllowOnlyReadAccess`.
    static let scopeReadOnly = URL.BookmarkCreationOptions(rawValue: 1 << 12)
}

extension URL.BookmarkResolutionOptions {
    /// `.withSecurityScope`.
    static let scope = URL.BookmarkResolutionOptions(rawValue: 1 << 10)
}

extension SandboxEnvironment {
    /// A sandboxed Mac app, which most tests simulate whatever the host is.
    static let sandboxedMac = SandboxEnvironment(platform: .macOS, isSandboxed: true)
}
