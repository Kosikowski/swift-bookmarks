import Foundation
import os
import Synchronization

/// Where the library's log messages go.
public enum BookmarkLogging {
    private static let configuredSubsystem = Mutex(defaultSubsystem)

    /// The `os.Logger` subsystem of the library's messages.
    ///
    /// Defaults to the main bundle identifier followed by `.bookmarks`. Set it at launch,
    /// before the library logs anything.
    public static var subsystem: String {
        get { configuredSubsystem.withLock { $0 } }
        set { configuredSubsystem.withLock { $0 = newValue } }
    }

    static var defaultSubsystem: String {
        Bundle.main.bundleIdentifier.map { "\($0).bookmarks" } ?? "swift-bookmarks"
    }
}

enum Log {
    static var access: Logger { logger("access") }
    static var resolution: Logger { logger("resolution") }
    static var store: Logger { logger("store") }
    static var persistence: Logger { logger("persistence") }

    private static func logger(_ category: String) -> Logger {
        Logger(subsystem: BookmarkLogging.subsystem, category: category)
    }
}
