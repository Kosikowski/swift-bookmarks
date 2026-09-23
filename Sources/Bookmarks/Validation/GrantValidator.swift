public import Foundation

/// Why a validator refused a granted item.
public enum GrantRefusal: Error, Sendable, Hashable, Codable {
    /// The item is `/`, a top-level system folder, the home folder or one of its ancestors.
    case tooBroad(path: String)
    /// A directory was required.
    case notDirectory(path: String)
    /// A file was required.
    case notFile(path: String)
    /// The item is a symbolic link.
    case symbolicLink(path: String)
    /// The item is already stored.
    case duplicate(path: String)
    /// The item is inside an item that is already stored.
    case insideExisting(existing: String)
    /// The item contains an item that is already stored.
    case containsExisting(existing: String)
    /// The item doesn't contain the location it's meant to cover.
    case doesNotCover(target: String)
    /// The item couldn't be inspected.
    case uninspectable(path: String)
    /// An app-specific refusal.
    case custom(String)

    /// A short English description, for logs. Apps supply their own copy for users.
    public var message: String {
        switch self {
        case .tooBroad(let path): "“\(path)” is too broad a location."
        case .notDirectory(let path): "“\(path)” isn't a folder."
        case .notFile(let path): "“\(path)” isn't a file."
        case .symbolicLink(let path): "“\(path)” is a symbolic link."
        case .duplicate(let path): "“\(path)” has already been added."
        case .insideExisting(let existing): "The item is inside “\(existing)”, which has already been added."
        case .containsExisting(let existing): "The item contains “\(existing)”, which has already been added."
        case .doesNotCover(let target): "The item doesn't contain “\(target)”."
        case .uninspectable(let path): "“\(path)” couldn't be inspected."
        case .custom(let reason): reason
        }
    }
}

/// What a validator can see besides the candidate item.
public struct ValidationContext: Sendable {
    /// Paths of the items already stored, excluding the one being re-granted.
    public var existingPaths: [String]
    /// The user's real home directory.
    public var homeDirectory: URL

    /// Creates a context.
    public init(existingPaths: [String] = [], homeDirectory: URL = SandboxEnvironment.realHomeDirectory) {
        self.existingPaths = existingPaths
        self.homeDirectory = homeDirectory
    }
}

/// Checks a granted item before it's bookmarked. Runs while access to the item is held.
public protocol GrantValidator: Sendable {
    /// Returns why `item` is refused, or `nil` to accept it.
    func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal?
}

/// Refuses `/`, every top-level folder, other users' home folders, second-level system
/// folders, and the user's home folder and its ancestors.
///
/// Volume roots such as `/Volumes/External` are accepted.
public struct NotTooBroadValidator: GrantValidator {
    /// Extra locations to refuse, in addition to the built-in rules.
    public var additionalPaths: Set<String>

    /// Creates the validator.
    public init(additionalPaths: Set<String> = []) {
        self.additionalPaths = additionalPaths
    }

    public func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal? {
        let path = NormalizedPath(item.canonicalPath)
        let home = NormalizedPath(context.homeDirectory.resolvingSymlinksInPath())
        let isRefused = Self.isSystemLocation(path)
            || path.contains(home)
            || additionalPaths.contains { NormalizedPath(URL(filePath: $0).resolvingSymlinksInPath()) == path }
        return isRefused ? .tooBroad(path: path.string) : nil
    }

    private static func isSystemLocation(_ path: NormalizedPath) -> Bool {
        switch path.components.count {
        case 0, 1: true
        case 2: ["Users", "private", "System"].contains(path.components[0])
        default: false
        }
    }
}

/// Accepts directories only.
public struct DirectoryOnlyValidator: GrantValidator {
    public init() {}

    public func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal? {
        item.isDirectory ? nil : .notDirectory(path: item.canonicalPath)
    }
}

/// Accepts files only.
public struct FileOnlyValidator: GrantValidator {
    public init() {}

    public func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal? {
        item.isDirectory ? .notFile(path: item.canonicalPath) : nil
    }
}

/// Refuses items that are symbolic links themselves.
public struct NoSymbolicLinkValidator: GrantValidator {
    public init() {}

    public func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal? {
        item.isSymbolicLink ? .symbolicLink(path: url.path(percentEncoded: false)) : nil
    }
}

/// Refuses items that duplicate, contain or sit inside an item that is already stored.
public struct NoOverlapValidator: GrantValidator {
    /// Whether nesting inside or around existing items is allowed, refusing only duplicates.
    public var allowsNesting: Bool

    /// Creates the validator.
    public init(allowsNesting: Bool = false) {
        self.allowsNesting = allowsNesting
    }

    public func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal? {
        let candidate = NormalizedPath(item.canonicalPath)
        for existingPath in context.existingPaths {
            let existing = NormalizedPath(existingPath)
            if candidate == existing {
                return .duplicate(path: item.canonicalPath)
            }
            guard !allowsNesting else { continue }
            if existing.contains(candidate) {
                return .insideExisting(existing: existingPath)
            }
            if candidate.contains(existing) {
                return .containsExisting(existing: existingPath)
            }
        }
        return nil
    }
}

/// Refuses items that don't contain `target`.
public struct CoversValidator: GrantValidator {
    /// The location the granted item must contain.
    public var target: URL

    /// Creates the validator.
    public init(target: URL) {
        self.target = target
    }

    public func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal? {
        let resolvedTarget = NormalizedPath(target.resolvingSymlinksInPath())
        return NormalizedPath(item.canonicalPath).contains(resolvedTarget)
            ? nil
            : .doesNotCover(target: target.path(percentEncoded: false))
    }
}

/// A validator built from a closure.
public struct CustomValidator: GrantValidator {
    private let check: @Sendable (ItemInfo, URL, ValidationContext) -> GrantRefusal?

    /// Creates a validator from a closure.
    public init(_ check: @escaping @Sendable (ItemInfo, URL, ValidationContext) -> GrantRefusal?) {
        self.check = check
    }

    public func refusal(for item: ItemInfo, at url: URL, in context: ValidationContext) -> GrantRefusal? {
        check(item, url, context)
    }
}

extension GrantValidator where Self == NotTooBroadValidator {
    /// Refuses `/`, top-level and system folders, home folders and their ancestors.
    public static var notTooBroad: NotTooBroadValidator { NotTooBroadValidator() }
}

extension GrantValidator where Self == DirectoryOnlyValidator {
    /// Accepts directories only.
    public static var directoryOnly: DirectoryOnlyValidator { DirectoryOnlyValidator() }
}

extension GrantValidator where Self == FileOnlyValidator {
    /// Accepts files only.
    public static var fileOnly: FileOnlyValidator { FileOnlyValidator() }
}

extension GrantValidator where Self == NoSymbolicLinkValidator {
    /// Refuses symbolic links.
    public static var noSymbolicLink: NoSymbolicLinkValidator { NoSymbolicLinkValidator() }
}

extension GrantValidator where Self == NoOverlapValidator {
    /// Refuses duplicates and items nested inside or around stored items.
    public static var noOverlap: NoOverlapValidator { NoOverlapValidator() }

    /// Refuses duplicates only.
    public static var noDuplicate: NoOverlapValidator { NoOverlapValidator(allowsNesting: true) }
}

extension GrantValidator where Self == CoversValidator {
    /// Refuses items that don't contain `target`.
    public static func covers(_ target: URL) -> CoversValidator { CoversValidator(target: target) }
}
