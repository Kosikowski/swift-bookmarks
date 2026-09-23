public import Foundation

/// Why a coordinated file operation through a lease didn't run.
public enum CoordinationError: Error, Sendable, Equatable {
    /// The URL isn't the leased item or inside it.
    case outsideLease(URL)
    /// The lease has ended.
    case leaseEnded
}

extension AccessLease {
    /// Reads an item inside the leased item through `NSFileCoordinator`.
    ///
    /// Coordination makes iCloud Drive and File Provider items download before they're read,
    /// and serialises the read with other processes presenting the same item.
    ///
    /// - Parameter item: The item to read, the leased item itself when `nil`.
    public func coordinatedRead<T>(
        _ item: URL? = nil,
        options: NSFileCoordinator.ReadingOptions = [],
        _ body: (URL) throws -> T
    ) throws -> T {
        let url = try scopedURL(for: item)
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    /// Writes an item inside the leased item through `NSFileCoordinator`.
    ///
    /// - Parameter item: The item to write, the leased item itself when `nil`.
    public func coordinatedWrite<T>(
        _ item: URL? = nil,
        options: NSFileCoordinator.WritingOptions = [],
        _ body: (URL) throws -> T
    ) throws -> T {
        let url = try scopedURL(for: item)
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    private func scopedURL(for item: URL?) throws(CoordinationError) -> URL {
        guard isActive else { throw .leaseEnded }
        guard let item else { return url }
        guard let scoped = url(forDescendant: item) else { throw .outsideLease(item) }
        return scoped
    }
}
