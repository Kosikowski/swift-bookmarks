@testable import Bookmarks
import Foundation
import Testing

@Suite("BookmarkKind")
struct BookmarkKindTests {
    static let allKinds: [BookmarkKind] = [
        .appScoped(.readWrite), .appScoped(.readOnly),
        .documentScoped(.readWrite), .documentScoped(.readOnly),
        .implicit, .reference, .alias,
    ]

    @Suite("Persistent default")
    struct PersistentDefault {
        @Test func isAppScopedReadWriteOnSandboxedMac() {
            #expect(BookmarkKind.persistentDefault(for: .init(platform: .macOS, isSandboxed: true)) == .appScoped(.readWrite))
            #expect(BookmarkKind.persistentDefault(for: .init(platform: .macCatalyst, isSandboxed: true)) == .appScoped(.readWrite))
        }

        @Test func isReferenceOnUnsandboxedMac() {
            #expect(BookmarkKind.persistentDefault(for: .init(platform: .macOS, isSandboxed: false)) == .reference)
            #expect(BookmarkKind.persistentDefault(for: .init(platform: .macCatalyst, isSandboxed: false)) == .reference)
        }

        @Test(arguments: [SandboxEnvironment.Platform.iOS, .visionOS, .other])
        func isImplicitWithoutSecurityScope(_ platform: SandboxEnvironment.Platform) {
            #expect(BookmarkKind.persistentDefault(for: .init(platform: platform, isSandboxed: true)) == .implicit)
        }
    }

    @Suite("Properties")
    struct Properties {
        @Test func securityScopedKinds() {
            #expect(BookmarkKind.appScoped(.readWrite).isSecurityScoped)
            #expect(BookmarkKind.documentScoped(.readOnly).isSecurityScoped)
            #expect(!BookmarkKind.implicit.isSecurityScoped)
            #expect(!BookmarkKind.reference.isSecurityScoped)
            #expect(!BookmarkKind.alias.isSecurityScoped)
        }

        @Test func kindsThatCarryAccess() {
            #expect(BookmarkKind.appScoped(.readOnly).carriesAccess)
            #expect(BookmarkKind.documentScoped(.readWrite).carriesAccess)
            #expect(BookmarkKind.implicit.carriesAccess)
            #expect(!BookmarkKind.reference.carriesAccess)
            #expect(!BookmarkKind.alias.carriesAccess)
        }

        @Test func accessModeOnlyForScopedKinds() {
            #expect(BookmarkKind.appScoped(.readOnly).accessMode == .readOnly)
            #expect(BookmarkKind.documentScoped(.readWrite).accessMode == .readWrite)
            #expect(BookmarkKind.implicit.accessMode == nil)
            #expect(BookmarkKind.reference.accessMode == nil)
            #expect(BookmarkKind.alias.accessMode == nil)
        }

        @Test(arguments: BookmarkKindTests.allKinds)
        func roundTripsThroughJSON(_ kind: BookmarkKind) throws {
            let decoded = try JSONDecoder().decode(BookmarkKind.self, from: JSONEncoder().encode(kind))

            #expect(decoded == kind)
        }
    }

    @Suite("Support")
    struct Support {
        let document = URL(filePath: "/Users/me/Document.pages")

        @Test(arguments: BookmarkKindTests.allKinds)
        func everyKindIsSupportedOnMacWithTheRightInputs(_ kind: BookmarkKind) {
            let anchor = kind.accessMode != nil && !kind.isAppScoped ? document : nil

            #expect(kind.unsupportedReason(in: .init(platform: .macOS, isSandboxed: true), relativeTo: anchor) == nil)
        }

        @Test(arguments: [BookmarkKind.appScoped(.readWrite), .implicit, .reference, .alias])
        func onlyDocumentScopedKindsTakeAnAnchor(_ kind: BookmarkKind) {
            let reason = kind.unsupportedReason(in: .init(platform: .macOS, isSandboxed: true), relativeTo: document)

            #expect(reason == "Only document-scoped bookmarks are anchored on a document.")
        }

        @Test(arguments: [BookmarkKind.appScoped(.readWrite), .documentScoped(.readOnly)])
        func scopedKindsAreUnsupportedOnIOS(_ kind: BookmarkKind) {
            let reason = kind.unsupportedReason(in: .init(platform: .iOS, isSandboxed: true), relativeTo: document)

            #expect(reason?.contains("macOS") == true)
        }

        @Test(arguments: [BookmarkKind.implicit, .reference, .alias])
        func unscopedKindsAreSupportedOnIOS(_ kind: BookmarkKind) {
            #expect(kind.unsupportedReason(in: .init(platform: .iOS, isSandboxed: true), relativeTo: nil) == nil)
        }

        @Test func documentScopeNeedsADocument() {
            let reason = BookmarkKind.documentScoped(.readWrite).unsupportedReason(in: .init(platform: .macOS, isSandboxed: true), relativeTo: nil)

            #expect(reason?.contains("DocumentBookmarks") == true)
        }
    }

    @Suite("Options")
    struct Options {
        @Test func creationOptionsPerKind() {
            #expect(BookmarkKind.appScoped(.readWrite).creationOptions == [.securityScope])
            #expect(BookmarkKind.appScoped(.readOnly).creationOptions == [.securityScope, .securityScopeReadOnly])
            #expect(BookmarkKind.documentScoped(.readWrite).creationOptions == [.securityScope])
            #expect(BookmarkKind.documentScoped(.readOnly).creationOptions == [.securityScope, .securityScopeReadOnly])
            #expect(BookmarkKind.implicit.creationOptions == [])
            #expect(BookmarkKind.reference.creationOptions == [.withoutImplicitSecurityScope])
            #expect(BookmarkKind.alias.creationOptions == [.suitableForBookmarkFile])
        }

        @Test(arguments: BookmarkKindTests.allKinds)
        func defaultPolicyNeverMountsOrShowsUI(_ kind: BookmarkKind) {
            let options = kind.resolutionOptions(.default)

            #expect(options.contains(.withoutUI))
            #expect(options.contains(.withoutMounting))
        }

        @Test func policyCanAllowMountingAndUI() {
            let options = BookmarkKind.reference.resolutionOptions(ResolutionPolicy(mounting: .allowed, allowsUI: true))

            #expect(!options.contains(.withoutUI))
            #expect(!options.contains(.withoutMounting))
        }

        @Test func scopedKindsResolveWithSecurityScope() {
            #expect(BookmarkKind.appScoped(.readOnly).resolutionOptions(.default).contains(.securityScope))
            #expect(BookmarkKind.documentScoped(.readWrite).resolutionOptions(.default).contains(.securityScope))
            #expect(!BookmarkKind.implicit.resolutionOptions(.default).contains(.securityScope))
            #expect(!BookmarkKind.reference.resolutionOptions(.default).contains(.securityScope))
        }

        @Test func implicitKindDefersStartingAccess() {
            #expect(BookmarkKind.implicit.resolutionOptions(.default).contains(.withoutImplicitStartAccessing))
            #expect(!BookmarkKind.implicit.resolutionOptions(ResolutionPolicy(startsImplicitAccess: true)).contains(.withoutImplicitStartAccessing))
        }

        @Test(arguments: [BookmarkKind.reference, .alias])
        func accessFreeKindsNeverStartAccess(_ kind: BookmarkKind) {
            #expect(kind.resolutionOptions(ResolutionPolicy(startsImplicitAccess: true)).contains(.withoutImplicitStartAccessing))
        }

        #if os(macOS) || targetEnvironment(macCatalyst)
        @Test func scopeBitsAreTheSDKsOptions() {
            #expect(URL.BookmarkCreationOptions.securityScope == .withSecurityScope)
            #expect(URL.BookmarkCreationOptions.securityScopeReadOnly == .securityScopeAllowOnlyReadAccess)
            #expect(URL.BookmarkResolutionOptions.securityScope == .withSecurityScope)
        }
        #endif
    }
}

extension BookmarkKind {
    fileprivate var isAppScoped: Bool {
        if case .appScoped = self { true } else { false }
    }
}
