@testable import Bookmarks
import Foundation
import Testing

@Suite("BookmarkLogging", .serialized)
struct LoggingTests {
    @Test func subsystemCanBeConfigured() {
        let original = BookmarkLogging.subsystem
        defer { BookmarkLogging.subsystem = original }

        BookmarkLogging.subsystem = "com.example.app.bookmarks"

        #expect(BookmarkLogging.subsystem == "com.example.app.bookmarks")
    }

    @Test func defaultsToTheMainBundle() {
        let expected = Bundle.main.bundleIdentifier.map { "\($0).bookmarks" } ?? "swift-bookmarks"

        #expect(BookmarkLogging.defaultSubsystem == expected)
    }
}
