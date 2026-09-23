/// What a bookmark recorded about its target when it was created.
///
/// These values come from the bookmark bytes alone, so they are available even when the
/// bookmark can't be resolved. Use them for display and for re-grant prompts, never for
/// file access.
public struct RecordedValues: Sendable, Hashable, Codable {
    /// The item's path when the bookmark was created.
    public var path: String?
    /// The item's name when the bookmark was created.
    public var name: String?
    /// The mount point of the volume that held the item.
    public var volumePath: String?
    /// The display name of that volume.
    public var volumeName: String?
    /// Whether the item was a directory.
    public var isDirectory: Bool?

    /// Creates recorded values.
    public init(
        path: String? = nil,
        name: String? = nil,
        volumePath: String? = nil,
        volumeName: String? = nil,
        isDirectory: Bool? = nil
    ) {
        self.path = path
        self.name = name
        self.volumePath = volumePath
        self.volumeName = volumeName
        self.isDirectory = isDirectory
    }

    /// Whether the item lived on the boot volume.
    public var isOnBootVolume: Bool {
        volumePath == nil || volumePath == "/"
    }
}
