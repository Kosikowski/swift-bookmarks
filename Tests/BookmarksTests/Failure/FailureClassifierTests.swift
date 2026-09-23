@testable import Bookmarks
import Foundation
import Testing

@Suite("FailureClassifier")
struct FailureClassifierTests {
    let mountedPaths: Set<String> = ["/", "/Volumes/Mounted"]

    var classifier: FailureClassifier {
        let mounted = mountedPaths
        return FailureClassifier { mounted.contains($0) }
    }

    func cocoa(_ code: CocoaError.Code) -> NSError {
        CocoaError.error(code) as NSError
    }

    func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    @Test(arguments: [CocoaError.Code.fileNoSuchFile, .fileReadNoSuchFile])
    func missingWithoutRecordedValues(_ code: CocoaError.Code) {
        #expect(classifier.classify(cocoa(code), recorded: nil) == .missing)
    }

    @Test func missingOnTheBootVolume() {
        let recorded = RecordedValues(path: "/Users/me/Gone", volumePath: "/")

        #expect(classifier.classify(cocoa(.fileNoSuchFile), recorded: recorded) == .missing)
    }

    @Test func missingOnAMountedVolume() {
        let recorded = RecordedValues(path: "/Volumes/Mounted/Gone", volumePath: "/Volumes/Mounted", volumeName: "Mounted")

        #expect(classifier.classify(cocoa(.fileNoSuchFile), recorded: recorded) == .missing)
    }

    @Test(arguments: [CocoaError.Code.fileNoSuchFile, .fileReadNoSuchFile])
    func unmountedVolume(_ code: CocoaError.Code) {
        let recorded = RecordedValues(path: "/Volumes/Backup/Folder", volumePath: "/Volumes/Backup", volumeName: "Backup")

        #expect(classifier.classify(cocoa(code), recorded: recorded) == .volumeUnavailable(name: "Backup"))
    }

    @Test func posixNoEntryFollowsTheSameVolumeRules() {
        let recorded = RecordedValues(volumePath: "/Volumes/Backup", volumeName: "Backup")

        #expect(classifier.classify(posix(ENOENT), recorded: recorded) == .volumeUnavailable(name: "Backup"))
        #expect(classifier.classify(posix(ENOENT), recorded: nil) == .missing)
    }

    @Test func corruptWhenTheBytesRecordNothing() {
        #expect(classifier.classify(cocoa(.fileReadCorruptFile), recorded: nil) == .corrupt)
    }

    @Test func regrantWhenReadableBytesAreRejected() {
        let recorded = RecordedValues(path: "/Users/me/Folder")

        #expect(classifier.classify(cocoa(.fileReadCorruptFile), recorded: recorded) == .needsRegrant)
    }

    @Test(arguments: [CocoaError.Code.fileReadUnknown, .fileReadNoPermission, .fileWriteNoPermission])
    func deniedCocoaErrors(_ code: CocoaError.Code) {
        #expect(classifier.classify(cocoa(code), recorded: nil) == .denied)
    }

    @Test(arguments: [EPERM, EACCES])
    func deniedPOSIXErrors(_ code: Int32) {
        #expect(classifier.classify(posix(code), recorded: nil) == .denied)
    }

    @Test func timeouts() {
        #expect(classifier.classify(posix(ETIMEDOUT), recorded: nil) == .timedOut)
    }

    @Test func unknownErrors() {
        let error = NSError(domain: "Custom", code: 17)

        #expect(classifier.classify(error, recorded: nil) == .other(domain: "Custom", code: 17))
    }

    @Test func classifiesTheUnderlyingErrorOfAnUnknownWrapper() {
        let error = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: posix(EPERM)])

        #expect(classifier.classify(error, recorded: nil) == .denied)
    }

    @Test func keepsTheOuterErrorWhenTheUnderlyingOneIsUnknownToo() {
        let inner = NSError(domain: "Inner", code: 2)
        let error = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: inner])

        #expect(classifier.classify(error, recorded: nil) == .other(domain: "Wrapper", code: 1))
    }

    @Test func swiftCocoaErrorsAreClassifiedToo() {
        #expect(classifier.classify(CocoaError(.fileNoSuchFile), recorded: nil) == .missing)
    }
}
