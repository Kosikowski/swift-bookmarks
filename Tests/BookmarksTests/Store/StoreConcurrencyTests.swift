@testable import Bookmarks
import BookmarksTesting
import Foundation
import Testing

@Suite("BookmarkStore: concurrency")
struct StoreConcurrencyTests {
    @Test func mixedOperationsStayConsistentAndBalanced() async throws {
        let harness = StoreHarness(policy: StorePolicy(duplicates: .allow))
        let keys = (0..<12).map { "item-\($0)" }
        for key in keys {
            try await harness.add(key, "/Items/\(key)")
        }
        let store = harness.store
        let engine = harness.engine

        await withTaskGroup(of: Void.self) { group in
            for round in 0..<240 {
                let key = keys[round % keys.count]
                group.addTask {
                    switch round % 6 {
                    case 0, 1, 2:
                        if let lease = try? await store.lease(key) {
                            await Task.yield()
                            lease.end()
                        }
                    case 3:
                        try? await store.updateMetadata(key) { $0.name = "round \(round)" }
                    case 4:
                        engine.addItem(at: "/Regranted/\(key)")
                        _ = try? await store.regrant(key, with: engine.grant("/Regranted/\(key)", origin: .openPanel))
                    default:
                        _ = try? await store.withAccess(to: [key, keys[(round + 1) % keys.count]]) { $0.count }
                    }
                }
            }
        }

        #expect(engine.isBalanced)
        #expect(try store.keys() == keys)
        #expect(harness.saved.map(\.key) == keys)
        #expect(try store.records().map(\.data) == harness.saved.map(\.data))
        #expect(store.registry.activeKeys.isEmpty)
    }

    @Test func concurrentAddsOfTheSameItemKeepOneRecord() async throws {
        let harness = StoreHarness(policy: StorePolicy(duplicates: .returnExisting))
        harness.engine.addItem(at: "/Shared")
        let store = harness.store
        let engine = harness.engine

        let keys = await withTaskGroup(of: String?.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? await store.add(engine.grant("/Shared", origin: .openPanel), key: "k\(index)", metadata: Tag(name: "\(index)")).key
                }
            }
            return await group.reduce(into: Set<String>()) { result, key in
                if let key { result.insert(key) }
            }
        }

        #expect(keys.count == 1)
        #expect(try store.records().count == 1)
        #expect(harness.engine.isBalanced)
    }

    @Test func forgettingWhileLeasingNeverLeaksAccess() async throws {
        let harness = StoreHarness()
        let store = harness.store
        for index in 0..<10 {
            try await harness.add("k\(index)", "/Items/\(index)")
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    for _ in 0..<5 {
                        if let lease = try? await store.lease("k\(index)") {
                            lease.end()
                        }
                    }
                }
                group.addTask {
                    _ = try? await store.forget("k\(index)")
                }
            }
        }

        #expect(harness.engine.isBalanced)
        #expect(try store.records().isEmpty)
    }
}
