import os

enum Log {
    static let access = Logger(subsystem: "swift-bookmarks", category: "access")
    static let resolution = Logger(subsystem: "swift-bookmarks", category: "resolution")
    static let store = Logger(subsystem: "swift-bookmarks", category: "store")
    static let persistence = Logger(subsystem: "swift-bookmarks", category: "persistence")
}
