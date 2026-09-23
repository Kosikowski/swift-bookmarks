@testable import Bookmarks
import Foundation
import Testing

@Suite("SandboxEnvironment")
struct SandboxEnvironmentTests {
    @Test(arguments: [
        (SandboxEnvironment.Platform.macOS, true),
        (.macCatalyst, true),
        (.iOS, false),
        (.visionOS, false),
        (.other, false),
    ])
    func securityScopeSupport(_ platform: SandboxEnvironment.Platform, _ expected: Bool) {
        #expect(SandboxEnvironment(platform: platform, isSandboxed: true).supportsSecurityScope == expected)
    }

    @Test func macIsSandboxedOnlyWithAContainerID() {
        #expect(SandboxEnvironment.detectSandbox(["APP_SANDBOX_CONTAINER_ID": "com.example"], platform: .macOS))
        #expect(!SandboxEnvironment.detectSandbox([:], platform: .macOS))
        #expect(SandboxEnvironment.detectSandbox(["APP_SANDBOX_CONTAINER_ID": "x"], platform: .macCatalyst))
    }

    @Test func mobilePlatformsAreAlwaysSandboxed() {
        #expect(SandboxEnvironment.detectSandbox([:], platform: .iOS))
        #expect(SandboxEnvironment.detectSandbox([:], platform: .visionOS))
        #expect(!SandboxEnvironment.detectSandbox([:], platform: .other))
    }

    #if os(macOS)
    @Test func currentProcessIsAnUnsandboxedMacTestRunner() {
        #expect(SandboxEnvironment.current.platform == .macOS)
        #expect(!SandboxEnvironment.current.isSandboxed)
    }

    @Test func realHomeIsNotAContainer() {
        let home = SandboxEnvironment.realHomeDirectory.path(percentEncoded: false)

        #expect(!home.contains("/Library/Containers/"))
        #expect(FileManager.default.fileExists(atPath: home))
    }
    #endif
}

@Suite("ResolutionPolicy")
struct ResolutionPolicyTests {
    @Test func defaultIsConservative() {
        let policy = ResolutionPolicy.default

        #expect(policy.mounting == .never)
        #expect(!policy.allowsUI)
        #expect(!policy.startsImplicitAccess)
        #expect(policy == ResolutionPolicy())
    }

    @Test func allowingMountOnlyChangesMounting() {
        #expect(ResolutionPolicy.allowingMount == ResolutionPolicy(mounting: .allowed))
    }
}

@Suite("RecordedValues")
struct RecordedValuesTests {
    @Test(arguments: [
        (nil as String?, true),
        ("/", true),
        ("/Volumes/External", false),
    ])
    func bootVolumeDetection(_ volumePath: String?, _ expected: Bool) {
        #expect(RecordedValues(volumePath: volumePath).isOnBootVolume == expected)
    }
}

@Suite("FileIdentity")
struct FileIdentityTests {
    @Test func describesVolumeAndFile() {
        #expect(FileIdentity(volumeUUID: "V", fileID: 7).description == "V:7")
        #expect(FileIdentity(volumeUUID: nil, fileID: 7).description == "?:7")
    }

    @Test func equalityNeedsBothParts() {
        #expect(FileIdentity(volumeUUID: "A", fileID: 1) == FileIdentity(volumeUUID: "A", fileID: 1))
        #expect(FileIdentity(volumeUUID: "A", fileID: 1) != FileIdentity(volumeUUID: "B", fileID: 1))
        #expect(FileIdentity(volumeUUID: "A", fileID: 1) != FileIdentity(volumeUUID: "A", fileID: 2))
    }
}

@Suite("Availability")
struct AvailabilityTests {
    @Test(arguments: [
        (BookmarkFailure.missing, Availability.missing),
        (.volumeUnavailable(name: "Backup"), .volumeUnavailable(name: "Backup")),
        (.needsRegrant, .needsRegrant),
        (.denied, .needsRegrant),
        (.corrupt, .needsRegrant),
        (.unsupported(reason: "x"), .unknown),
        (.timedOut, .unknown),
        (.cancelled, .unknown),
        (.other(domain: "D", code: 1), .unknown),
    ])
    func mapsFailures(_ failure: BookmarkFailure, _ expected: Availability) {
        #expect(Availability(failure) == expected)
    }
}
