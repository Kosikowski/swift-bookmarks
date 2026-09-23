import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BalanceReport")
struct BalanceReportTests {
    @Test func describesABalancedEngine() {
        let engine = FakeBookmarkEngine()

        #expect(engine.balanceReport.isBalanced)
        #expect(engine.balanceReport.description == "balanced")
    }

    @Test func describesEveryProblem() {
        let engine = FakeBookmarkEngine()
        engine.addItem(at: "/b")
        engine.addItem(at: "/a")
        _ = engine.grant("/b", origin: .openPanel)
        _ = engine.grant("/a", origin: .appKitDrop)
        _ = engine.grant("/a", origin: .appKitDrop)
        engine.stopAccessing(URL(filePath: "/stray"))
        _ = engine.startAccessing(URL(filePath: "/rebuilt"))

        let report = engine.balanceReport

        #expect(!report.isBalanced)
        #expect(report.outstanding == ["/a": 2, "/b": 1])
        #expect(report.description == "outstanding: /a ×2, /b ×1; unbalanced stops: /stray; starts on unissued URLs: /rebuilt")
    }

    @Test func startsOnUnissuedURLsAloneDontUnbalance() {
        let engine = FakeBookmarkEngine()
        _ = engine.startAccessing(URL(filePath: "/rebuilt"))

        #expect(engine.isBalanced)
        #expect(engine.balanceReport.description == "starts on unissued URLs: /rebuilt")
    }
}
