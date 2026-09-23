public import Foundation

/// Whether a security-scoped bookmark grants write access or read access only.
public enum AccessMode: String, Sendable, Hashable, Codable, CaseIterable {
    case readWrite
    case readOnly
}

/// The kind of bookmark to create or resolve.
///
/// A bookmark must be resolved with the same kind it was created with, so stores record the
/// kind next to the bytes.
public enum BookmarkKind: Sendable, Hashable, Codable {
    /// A security-scoped bookmark that only the creating app can resolve (macOS, Mac Catalyst).
    case appScoped(AccessMode)
    /// A security-scoped bookmark to a file, anchored on a document file (macOS, Mac Catalyst).
    ///
    /// Any app with access to the document can resolve it. Requires the
    /// `com.apple.security.files.bookmarks.document-scope` entitlement. Tools that strip
    /// extended attributes from the document break these bookmarks.
    case documentScoped(AccessMode)
    /// A regular bookmark that carries access implicitly.
    ///
    /// This is how iOS and visionOS persist access. On macOS it is a bearer token that grants
    /// access to any process that resolves it until reboot, so use it only for in-memory
    /// handoff to helpers.
    case implicit
    /// A bookmark that tracks an item's location and carries no access.
    case reference
    /// A bookmark suitable for writing to an alias file. Carries no access.
    case alias

    /// The kind to persist by default in the given environment.
    ///
    /// App-scoped read-write on sandboxed macOS and Mac Catalyst, reference-only on unsandboxed
    /// macOS, and implicit on iOS and visionOS.
    public static func persistentDefault(for environment: SandboxEnvironment) -> BookmarkKind {
        switch environment.platform {
        case .macOS, .macCatalyst:
            environment.isSandboxed ? .appScoped(.readWrite) : .reference
        case .iOS, .visionOS, .other:
            .implicit
        }
    }

    /// The kind to persist by default in the current process.
    public static var persistentDefault: BookmarkKind {
        persistentDefault(for: .current)
    }

    /// Whether the bookmark carries a security scope that must be started before use.
    public var isSecurityScoped: Bool {
        switch self {
        case .appScoped, .documentScoped: true
        case .implicit, .reference, .alias: false
        }
    }

    /// Whether resolving the bookmark yields a URL that grants access.
    public var carriesAccess: Bool {
        switch self {
        case .appScoped, .documentScoped, .implicit: true
        case .reference, .alias: false
        }
    }

    /// The access mode for security-scoped kinds, `nil` otherwise.
    public var accessMode: AccessMode? {
        switch self {
        case .appScoped(let mode), .documentScoped(let mode): mode
        case .implicit, .reference, .alias: nil
        }
    }

    /// Why this kind can't be used in the given environment, or `nil` when it can.
    public func unsupportedReason(in environment: SandboxEnvironment, relativeTo document: URL?) -> String? {
        if isSecurityScoped, !environment.supportsSecurityScope {
            return "Security-scoped bookmarks are only available on macOS and Mac Catalyst."
        }
        switch (self, document) {
        case (.documentScoped, .none):
            return "Document-scoped bookmarks need the document that anchors them. Use DocumentBookmarks."
        case (.documentScoped, .some), (_, .none):
            return nil
        case (_, .some):
            return "Only document-scoped bookmarks are anchored on a document."
        }
    }
}

extension BookmarkKind {
    var creationOptions: URL.BookmarkCreationOptions {
        switch self {
        case .appScoped(let mode), .documentScoped(let mode):
            #if os(macOS) || targetEnvironment(macCatalyst)
            mode == .readOnly ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.withSecurityScope]
            #else
            []
            #endif
        case .implicit:
            []
        case .reference:
            [.withoutImplicitSecurityScope]
        case .alias:
            [.suitableForBookmarkFile]
        }
    }

    func resolutionOptions(_ policy: ResolutionPolicy) -> URL.BookmarkResolutionOptions {
        var options: URL.BookmarkResolutionOptions = []
        if !policy.allowsUI {
            options.insert(.withoutUI)
        }
        if policy.mounting == .never {
            options.insert(.withoutMounting)
        }
        switch self {
        case .appScoped, .documentScoped:
            #if os(macOS) || targetEnvironment(macCatalyst)
            options.insert(.withSecurityScope)
            #endif
        case .implicit:
            if !policy.startsImplicitAccess {
                options.insert(.withoutImplicitStartAccessing)
            }
        case .reference, .alias:
            options.insert(.withoutImplicitStartAccessing)
        }
        return options
    }
}
