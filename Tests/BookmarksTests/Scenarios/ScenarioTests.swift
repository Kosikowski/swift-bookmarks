@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("DocumentBookmarks")
struct DocumentBookmarksTests {
    let engine = Fixtures.engine()
    var documents: DocumentBookmarks {
        DocumentBookmarks(document: URL(filePath: "/Users/me/Report.pages"), service: Fixtures.service(engine))
    }

    init() {
        engine.addItem(at: "/Users/me/Report.pages", isDirectory: false)
        engine.addItem(at: "/Users/me/Images/chart.png", isDirectory: false)
    }

    @Test func createsAndResolvesBookmarksAnchoredOnTheDocument() async throws {
        let data = try await documents.create(for: engine.grant("/Users/me/Images/chart.png", origin: .openPanel))

        let resolved = try await documents.resolve(data)

        #expect(resolved.kind == .documentScoped(.readWrite))
        #expect(resolved.displayPath == "/Users/me/Images/chart.png")
        #expect(engine.creationRequests.last?.document == "/Users/me/Report.pages")
    }

    @Test func readOnlyAccess() async throws {
        let readOnly = DocumentBookmarks(document: documents.document, access: .readOnly, service: Fixtures.service(engine))

        _ = try await readOnly.create(for: engine.grant("/Users/me/Images/chart.png", origin: .openPanel))

        #expect(readOnly.kind == .documentScoped(.readOnly))
        #expect(engine.creationRequests.last?.options == [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
    }

    @Test func refusesFolderTargets() async {
        engine.addItem(at: "/Users/me/Images")

        let error = await #expect(throws: BookmarkError.self) {
            try await documents.create(for: engine.grant("/Users/me/Images", origin: .openPanel))
        }

        #expect(error?.failure == .refused(.notFile(path: "/Users/me/Images")))
    }

    @Test func refusesFolderAnchors() async {
        engine.addItem(at: "/Users/me/Package.bundle")
        let documents = DocumentBookmarks(document: URL(filePath: "/Users/me/Package.bundle"), service: Fixtures.service(engine))

        let error = await #expect(throws: BookmarkError.self) {
            try await documents.create(for: engine.grant("/Users/me/Images/chart.png", origin: .openPanel))
        }

        guard case .unsupported = error?.failure else {
            Issue.record("Expected unsupported, got \(String(describing: error))")
            return
        }
    }

    @Test func missingAnchorsAreMissing() async {
        let documents = DocumentBookmarks(document: URL(filePath: "/Users/me/Gone.pages"), service: Fixtures.service(engine))

        let error = await #expect(throws: BookmarkError.self) {
            try await documents.create(for: engine.grant("/Users/me/Images/chart.png", origin: .openPanel))
        }

        #expect(error?.failure == .missing)
    }

    @Test func resolvingAgainstAnotherDocumentFails() async throws {
        let data = try await documents.create(for: engine.grant("/Users/me/Images/chart.png", origin: .openPanel))
        engine.addItem(at: "/Users/me/Other.pages", isDirectory: false)
        let other = DocumentBookmarks(document: URL(filePath: "/Users/me/Other.pages"), service: Fixtures.service(engine))

        let error = await #expect(throws: BookmarkError.self) { try await other.resolve(data) }

        #expect(error?.failure == .needsRegrant)
    }

    @Test func unsupportedOnIOS() async {
        let engine = Fixtures.engine(Fixtures.iOS)
        engine.addItem(at: "/Documents/Doc.pages", isDirectory: false)
        let documents = DocumentBookmarks(document: URL(filePath: "/Documents/Doc.pages"), service: Fixtures.service(engine))

        let error = await #expect(throws: BookmarkError.self) {
            try await documents.create(for: engine.grant("/Documents/Doc.pages", origin: .documentPicker))
        }

        guard case .unsupported = error?.failure else {
            Issue.record("Expected unsupported, got \(String(describing: error))")
            return
        }
    }

    @Test func checksAvailabilityAgainstTheDocument() async throws {
        let data = try await documents.create(for: engine.grant("/Users/me/Images/chart.png", origin: .openPanel))

        #expect(await documents.availability(of: data) == .available)
        engine.removeItem(at: "/Users/me/Images/chart.png")
        #expect(await documents.availability(of: data) == .missing)
    }

    @Test func withAccessBalances() async throws {
        let data = try await documents.create(for: engine.grant("/Users/me/Images/chart.png", origin: .fileImporter))

        let name = try await documents.withAccess(to: data) { $0.lastPathComponent }

        #expect(name == "chart.png")
        #expect(engine.isBalanced)
    }
}

@Suite("Handoff")
struct HandoffTests {
    let engine = Fixtures.engine()
    var handoff: Handoff { Handoff(service: Fixtures.service(engine)) }

    func activeLease() async throws -> AccessLease {
        let data = try await Fixtures.adoptFolder("/Users/me/Shared", engine: engine)
        return try await Fixtures.service(engine).resolve(data).beginAccess()
    }

    @Test func tokensAreImplicitBookmarks() async throws {
        let lease = try await activeLease()
        defer { lease.end() }

        _ = try await handoff.makeToken(for: lease)

        #expect(engine.creationRequests.last?.options == [])
    }

    @Test func receivingTakesOverTheImplicitStart() async throws {
        let lease = try await activeLease()
        let token = try await handoff.makeToken(for: lease)
        lease.end()

        let received = try await handoff.receive(token)

        #expect(received.isActive)
        #expect(received.didStartScope)
        #expect(engine.isAccessing("/Users/me/Shared"))
        #expect(engine.resolutionRequests.last?.options.contains(.withoutImplicitStartAccessing) == false)
        received.end()
        #expect(engine.isBalanced)
    }

    @Test func refusesEndedLeases() async throws {
        let lease = try await activeLease()
        lease.end()

        let error = await #expect(throws: BookmarkError.self) { try await handoff.makeToken(for: lease) }

        #expect(error?.failure == .denied)
    }
}

@Suite("AliasFiles")
struct AliasFilesTests {
    let engine = Fixtures.engine()
    var aliases: AliasFiles { AliasFiles(service: Fixtures.service(engine)) }

    @Test func writesAndResolvesAliases() async throws {
        engine.addItem(at: "/Users/me/Target")
        engine.makeAccessibleWithoutGrant("/Users/me/Desktop")

        try await aliases.write(aliasTo: engine.grant("/Users/me/Target", origin: .fileImporter), at: URL(filePath: "/Users/me/Desktop/Target alias"))
        let resolved = try await aliases.resolve(aliasAt: URL(filePath: "/Users/me/Desktop/Target alias"))

        #expect(resolved.kind == .alias)
        #expect(resolved.displayPath == "/Users/me/Target/")
        #expect(engine.creationRequests.last?.options == [.suitableForBookmarkFile])
        #expect(engine.isBalanced)
    }

    @Test func aliasesFollowMoves() async throws {
        engine.addItem(at: "/Users/me/Target")
        try await aliases.write(aliasTo: engine.grant("/Users/me/Target", origin: .fileImporter), at: URL(filePath: "/Users/me/Alias"))
        engine.moveItem(from: "/Users/me/Target", to: "/Users/me/Moved")

        let resolved = try await aliases.resolve(aliasAt: URL(filePath: "/Users/me/Alias"))

        #expect(resolved.wasStale)
        #expect(resolved.displayPath == "/Users/me/Moved/")
    }

    @Test func readsTheStoredBytes() async throws {
        engine.addItem(at: "/Users/me/Target")
        try await aliases.write(aliasTo: engine.grant("/Users/me/Target", origin: .fileImporter), at: URL(filePath: "/Users/me/Alias"))

        let data = try await aliases.data(inAliasAt: URL(filePath: "/Users/me/Alias"))

        #expect(Fixtures.service(engine).recordedValues(in: data)?.path == "/Users/me/Target")
    }

    @Test func missingAliasFilesAreMissing() async {
        let error = await #expect(throws: BookmarkError.self) {
            try await aliases.resolve(aliasAt: URL(filePath: "/Users/me/Nothing"))
        }

        #expect(error?.failure == .missing)
        #expect(error?.lastKnownPath == "/Users/me/Nothing")
    }

    @Test func writeFailuresAreClassified() async throws {
        engine.addItem(at: "/Users/me/Target")
        let engine = engine
        let failing = AliasFiles(service: BookmarkService(engine: RejectingAliasEngine(base: engine), executor: Fixtures.executor))

        let error = await #expect(throws: BookmarkError.self) {
            try await failing.write(aliasTo: engine.grant("/Users/me/Target", origin: .fileImporter), at: URL(filePath: "/Users/me/Alias"))
        }

        #expect(error?.failure == .denied)
    }
}

private struct RejectingAliasEngine: BookmarkEngine {
    let base: FakeBookmarkEngine
    var environment: SandboxEnvironment { base.environment }

    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions, includingResourceValuesFor keys: Set<URLResourceKey>, relativeTo document: URL?) throws -> BookmarkData {
        try base.makeBookmark(for: url, options: options, includingResourceValuesFor: keys, relativeTo: document)
    }

    func resolve(_ data: BookmarkData, options: URL.BookmarkResolutionOptions, relativeTo document: URL?) throws -> (url: URL, isStale: Bool) {
        try base.resolve(data, options: options, relativeTo: document)
    }

    func recordedValues(in data: BookmarkData) -> RecordedValues? { base.recordedValues(in: data) }
    func startAccessing(_ url: URL) -> Bool { base.startAccessing(url) }
    func stopAccessing(_ url: URL) { base.stopAccessing(url) }
    func itemExists(atPath path: String) -> Bool { base.itemExists(atPath: path) }
    func fileIdentity(of url: URL) -> FileIdentity? { base.fileIdentity(of: url) }
    func itemInfo(at url: URL) -> ItemInfo? { base.itemInfo(at: url) }
    func writeAliasFile(_ data: BookmarkData, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    func aliasFileData(at url: URL) throws -> BookmarkData { try base.aliasFileData(at: url) }
}

#if os(macOS)
import AppKit

@Suite("VolumeEvents")
struct VolumeEventsTests {
    @Test func reportsMountsAndUnmounts() async {
        let center = NotificationCenter()
        let stream = VolumeEvents.stream(notificationCenter: center)
        let volume = URL(filePath: "/Volumes/Backup")

        center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
        center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
        center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [:])

        var events: [VolumeEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == 2 { break }
        }

        #expect(events == [.mounted(volume), .unmounted(volume)])
        #expect(events.map(\.volumeURL) == [volume, volume])
    }

    @Test func stopsObservingWhenTheConsumerStops() async {
        let center = NotificationCenter()
        let volume = URL(filePath: "/Volumes/Backup")
        do {
            let stream = VolumeEvents.stream(notificationCenter: center)
            center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
            for await _ in stream { break }
        }

        center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
    }
}
#endif
