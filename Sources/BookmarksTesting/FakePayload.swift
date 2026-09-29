import Foundation

enum FakeFlavor: Codable, Equatable, Sendable {
    case appScoped(readOnly: Bool)
    case documentScoped(readOnly: Bool)
    case implicit
    case reference
    case alias

    /// Reads the options by their bits, so the fake takes them as the platform it simulates
    /// would, whichever platform it runs on.
    init(_ options: URL.BookmarkCreationOptions) throws {
        if options.contains(.fakeSecurityScope) {
            if options.contains(.minimalBookmark) || options.contains(.suitableForBookmarkFile) {
                throw CocoaError.error(.fileReadUnknown)
            }
            self = .appScoped(readOnly: options.contains(.fakeSecurityScopeReadOnly))
        } else if options.contains(.suitableForBookmarkFile) {
            self = .alias
        } else if options.contains(.withoutImplicitSecurityScope) {
            self = .reference
        } else {
            self = .implicit
        }
    }

    var isScoped: Bool {
        switch self {
        case .appScoped, .documentScoped: true
        case .implicit, .reference, .alias: false
        }
    }

    func checkResolution(options: URL.BookmarkResolutionOptions, document: String?, payload: FakePayload) throws {
        if options.contains(.fakeSecurityScope), !isScoped {
            throw CocoaError.error(.fileReadCorruptFile)
        }
        // With a key, the anchor's key decides, so a moved anchor still resolves.
        if case .documentScoped = self, document == nil || (payload.documentKey == nil && payload.document != document) {
            throw CocoaError.error(.fileReadCorruptFile)
        }
    }
}

extension URL.BookmarkCreationOptions {
    /// `.withSecurityScope`, which the SDK names only on macOS and Mac Catalyst.
    static let fakeSecurityScope = URL.BookmarkCreationOptions(rawValue: 1 << 11)
    /// `.securityScopeAllowOnlyReadAccess`, which the SDK names only on macOS and Mac Catalyst.
    static let fakeSecurityScopeReadOnly = URL.BookmarkCreationOptions(rawValue: 1 << 12)
}

extension URL.BookmarkResolutionOptions {
    /// `.withSecurityScope`, which the SDK names only on macOS and Mac Catalyst.
    static let fakeSecurityScope = URL.BookmarkResolutionOptions(rawValue: 1 << 10)
}

struct FakePayload: Codable, Sendable {
    let itemID: UInt64
    let path: String
    let isDirectory: Bool
    let flavor: FakeFlavor
    let document: String?
    /// The key of the document a document-scoped bookmark is anchored on.
    var documentKey: Int?
    let serial: Int
}
