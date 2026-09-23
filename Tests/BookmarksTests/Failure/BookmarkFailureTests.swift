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
        .refused(.tooBroad(path: "/")), .refused(.notDirectory(path: "/f")), .refused(.notFile(path: "/d")),
        .refused(.symbolicLink(path: "/l")), .refused(.duplicate(path: "/a")), .refused(.insideExisting(existing: "/a")),
        .refused(.containsExisting(existing: "/a/b")), .refused(.doesNotCover(target: "/t")),
        .refused(.uninspectable(path: "/u")), .refused(.custom("no")),
    ])
    func roundTripsThroughJSON(_ failure: BookmarkFailure) throws {
        let decoded = try JSONDecoder().decode(BookmarkFailure.self, from: JSONEncoder().encode(failure))

        #expect(decoded == failure)
    }
}

@Suite("BookmarkFailure stored format")
struct BookmarkFailureStoredFormatTests {
    /// Stored statuses from earlier versions must keep decoding, so the encoding never changes.
    @Test(arguments: [
        (BookmarkFailure.missing, #"{"code":"missing"}"#),
        (.volumeUnavailable(name: "V"), #"{"code":"volumeUnavailable","volumeName":"V"}"#),
        (.volumeUnavailable(name: nil), #"{"code":"volumeUnavailable"}"#),
        (.needsRegrant, #"{"code":"needsRegrant"}"#),
        (.denied, #"{"code":"denied"}"#),
        (.corrupt, #"{"code":"corrupt"}"#),
        (.unsupported(reason: "why"), #"{"code":"unsupported","reason":"why"}"#),
        (.timedOut, #"{"code":"timedOut"}"#),
        (.cancelled, #"{"code":"cancelled"}"#),
        (.other(domain: "D", code: 3), #"{"code":"other","domain":"D","errorCode":3}"#),
        (.refused(.tooBroad(path: "/")), #"{"code":"refused","refusal":{"tooBroad":{"path":"\/"}}}"#),
        (.refused(.notDirectory(path: "f")), #"{"code":"refused","refusal":{"notDirectory":{"path":"f"}}}"#),
        (.refused(.notFile(path: "d")), #"{"code":"refused","refusal":{"notFile":{"path":"d"}}}"#),
        (.refused(.symbolicLink(path: "l")), #"{"code":"refused","refusal":{"symbolicLink":{"path":"l"}}}"#),
        (.refused(.duplicate(path: "a")), #"{"code":"refused","refusal":{"duplicate":{"path":"a"}}}"#),
        (.refused(.insideExisting(existing: "a")), #"{"code":"refused","refusal":{"insideExisting":{"existing":"a"}}}"#),
        (.refused(.containsExisting(existing: "a")), #"{"code":"refused","refusal":{"containsExisting":{"existing":"a"}}}"#),
        (.refused(.doesNotCover(target: "t")), #"{"code":"refused","refusal":{"doesNotCover":{"target":"t"}}}"#),
        (.refused(.uninspectable(path: "u")), #"{"code":"refused","refusal":{"uninspectable":{"path":"u"}}}"#),
        (.refused(.custom("no")), #"{"code":"refused","refusal":{"custom":{"_0":"no"}}}"#),
    ])
    func encodesToAFixedFormat(_ failure: BookmarkFailure, _ json: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        #expect(String(data: try encoder.encode(failure), encoding: .utf8) == json)
        #expect(try JSONDecoder().decode(BookmarkFailure.self, from: Data(json.utf8)) == failure)
    }

    @Test func unknownCodesFailToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BookmarkFailure.self, from: Data(#"{"code":"future"}"#.utf8))
        }
    }

    @Test func missingOptionalFieldsDecodeWithDefaults() throws {
        let decoder = JSONDecoder()

        #expect(try decoder.decode(BookmarkFailure.self, from: Data(#"{"code":"unsupported"}"#.utf8)) == .unsupported(reason: ""))
        #expect(try decoder.decode(BookmarkFailure.self, from: Data(#"{"code":"other"}"#.utf8)) == .other(domain: "", code: 0))
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
