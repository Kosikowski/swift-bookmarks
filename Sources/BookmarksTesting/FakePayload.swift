import Foundation

enum FakeFlavor: Codable, Equatable, Sendable {
    case appScoped(readOnly: Bool)
    case documentScoped(readOnly: Bool)
    case implicit
    case reference
    case alias

    init(_ options: URL.BookmarkCreationOptions) throws {
        #if os(macOS) || targetEnvironment(macCatalyst)
        if options.contains(.withSecurityScope) {
            if options.contains(.minimalBookmark) || options.contains(.suitableForBookmarkFile) {
                throw CocoaError.error(.fileReadUnknown)
            }
            self = .appScoped(readOnly: options.contains(.securityScopeAllowOnlyReadAccess))
            return
        }
        #endif
        if options.contains(.suitableForBookmarkFile) {
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
        #if os(macOS) || targetEnvironment(macCatalyst)
        if options.contains(.withSecurityScope), !isScoped {
            throw CocoaError.error(.fileReadCorruptFile)
        }
        #endif
        if case .documentScoped = self, payload.document != document {
            throw CocoaError.error(.fileReadCorruptFile)
        }
    }
}

struct FakePayload: Codable, Sendable {
    let itemID: UInt64
    let path: String
    let isDirectory: Bool
    let flavor: FakeFlavor
    let document: String?
    let serial: Int
}
