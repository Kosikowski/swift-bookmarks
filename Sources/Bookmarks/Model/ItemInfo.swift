/// What the file system reports about an item, for validation.
public struct ItemInfo: Sendable, Hashable {
    /// Whether the item is a directory.
    public var isDirectory: Bool
    /// Whether the item itself is a symbolic link.
    public var isSymbolicLink: Bool
    /// The item's path with every symbolic link resolved.
    public var canonicalPath: String

    /// Creates item information.
    public init(isDirectory: Bool, isSymbolicLink: Bool, canonicalPath: String) {
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.canonicalPath = canonicalPath
    }
}
