@testable import Bookmarks
import Foundation
import Testing

@Suite("BookmarkFailure")
struct BookmarkFailureTests {
    @Test(arguments: [
        (BookmarkFailure.missing, BookmarkFailure.Recommendation.forget),
        (.volumeUnavailable(name: nil), .retryLater),
        (.timedOut, .retryLater),
        (.cancelled, .retryLater),
        (.other(domain: "D", code: 1), .retryLater),
        (.needsRegrant, .regrant),
        (.denied, .regrant),
        (.corrupt, .regrant),
        (.unsupported(reason: "r"), .regrant),
    ])
    func recommendations(_ failure: BookmarkFailure, _ expected: BookmarkFailure.Recommendation) {
        #expect(failure.recommendation == expected)
        #expect(failure.isTransient == (expected == .retryLater))
    }

    @Test(arguments: [
        BookmarkFailure.missing, .volumeUnavailable(name: "V"), .volumeUnavailable(name: nil), .needsRegrant,
        .denied, .corrupt, .unsupported(reason: "why"), .timedOut, .cancelled, .other(domain: "D", code: 3),
    ])
    func roundTripsThroughJSON(_ failure: BookmarkFailure) throws {
        let decoded = try JSONDecoder().decode(BookmarkFailure.self, from: JSONEncoder().encode(failure))

        #expect(decoded == failure)
    }
}

@Suite("BookmarkFailure log names")
struct BookmarkFailureLogNameTests {
    @Test(arguments: [
        (BookmarkFailure.missing, "missing"),
        (.volumeUnavailable(name: "Private Disk"), "volumeUnavailable"),
        (.needsRegrant, "needsRegrant"),
        (.denied, "denied"),
        (.corrupt, "corrupt"),
        (.refused(.tooBroad(path: "/Users/me")), "refused"),
        (.unsupported(reason: "r"), "unsupported"),
        (.timedOut, "timedOut"),
        (.cancelled, "cancelled"),
        (.other(domain: "D", code: 1), "other"),
    ])
    func omitPayloadsThatMayHoldPaths(_ failure: BookmarkFailure, _ name: String) {
        #expect(failure.caseName == name)
    }
}

@Suite("BookmarkError")
struct BookmarkErrorTests {
    @Test func descriptionIncludesFailurePathAndUnderlyingCode() {
        let error = BookmarkError(.missing, lastKnownPath: "/Users/me/Folder", underlying: CocoaError.error(.fileNoSuchFile) as NSError)

        #expect(error.description == "BookmarkError(missing, lastKnownPath: /Users/me/Folder, underlying: NSCocoaErrorDomain 4)")
    }

    @Test func descriptionWithoutOptionalParts() {
        #expect(BookmarkError(.denied).description == "BookmarkError(denied)")
    }

    @Test(arguments: [
        BookmarkFailure.missing, .volumeUnavailable(name: nil), .needsRegrant, .denied, .corrupt, .timedOut, .cancelled,
    ])
    func everyClassifiedFailureHasAMessage(_ failure: BookmarkFailure) {
        let message = BookmarkError(failure).errorDescription

        #expect(message?.isEmpty == false)
    }

    @Test func volumeMessageNamesTheVolume() {
        #expect(BookmarkError(.volumeUnavailable(name: "Backup")).errorDescription?.contains("Backup") == true)
    }

    @Test func unsupportedMessageIsTheReason() {
        #expect(BookmarkError(.unsupported(reason: "Needs macOS.")).errorDescription == "Needs macOS.")
    }

    @Test func otherFailureUsesTheUnderlyingMessage() {
        let underlying = NSError(domain: "D", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something broke"])

        #expect(BookmarkError(.other(domain: "D", code: 1), underlying: underlying).errorDescription == "Something broke")
        #expect(BookmarkError(.other(domain: "D", code: 1)).errorDescription == nil)
    }
}
