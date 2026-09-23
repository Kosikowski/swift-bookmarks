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
    /// and serialises the read with other processes presenting the same item. The calling
    /// thread blocks until the read finishes.
    ///
    /// - Parameter item: The item to read, the leased item itself when `nil`.
    public func coordinatedRead<T>(
        _ item: URL? = nil,
        options: NSFileCoordinator.ReadingOptions = [],
        _ body: (URL) throws -> T
    ) throws -> T {
        try Coordination.read(at: scopedURL(for: item), options: options, body)
    }

    /// Writes an item inside the leased item through `NSFileCoordinator`.
    ///
    /// The calling thread blocks until the write finishes.
    ///
    /// - Parameter item: The item to write, the leased item itself when `nil`.
    public func coordinatedWrite<T>(
        _ item: URL? = nil,
        options: NSFileCoordinator.WritingOptions = [],
        _ body: (URL) throws -> T
    ) throws -> T {
        try Coordination.write(at: scopedURL(for: item), options: options, body)
    }

    private func scopedURL(for item: URL?) throws(CoordinationError) -> URL {
        guard isActive else { throw .leaseEnded }
        guard let item else { return url }
        guard let scoped = url(forDescendant: item) else { throw .outsideLease(item) }
        return scoped
    }
}

enum Coordination {
    static func read<T>(at url: URL, options: NSFileCoordinator.ReadingOptions, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func write<T>(at url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
