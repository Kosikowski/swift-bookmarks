/// Identifies a file system item independently of its path.
///
/// Two URLs with the same identity refer to the same item, even after a rename, a move, or
/// when the paths differ only by case on a case-insensitive volume. Items on volumes that
/// report no UUID have no identity, since file identifiers are only unique per volume.
public struct FileIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The UUID of the volume that holds the item.
    public var volumeUUID: String
    /// The item's file identifier on that volume.
    public var fileID: UInt64

    /// Creates an identity.
    public init(volumeUUID: String, fileID: UInt64) {
        self.volumeUUID = volumeUUID
        self.fileID = fileID
    }

    public var description: String { "\(volumeUUID):\(fileID)" }
}
