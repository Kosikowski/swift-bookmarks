import Foundation

/// A standardised absolute path that compares the way the file system does.
///
/// Components compare in Unicode canonical composition, since APFS and HFS+ treat composed
/// and decomposed names as the same name, and `/private/var`, `/private/tmp` and
/// `/private/etc` compare equal to `/var`, `/tmp` and `/etc`. Case is ignored when the
/// path's volume ignores it; the volume is described by `isCaseSensitive`, which defaults to
/// the safe answer. A path decides how it compares against another: ``contains(_:)`` and
/// ``relativeComponents(of:)`` fold the other path by this path's rule.
struct NormalizedPath: Equatable, Sendable, CustomStringConvertible {
    /// The components as spelled.
    let components: [String]
    /// Whether names on this path's volume differ by case.
    let isCaseSensitive: Bool

    init(_ url: URL, isCaseSensitive: Bool = true) {
        components = url.standardizedFileURL.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        self.isCaseSensitive = isCaseSensitive
    }

    init(_ path: String, isCaseSensitive: Bool = true) {
        self.init(URL(filePath: path), isCaseSensitive: isCaseSensitive)
    }

    var string: String {
        "/" + components.joined(separator: "/")
    }

    var description: String { string }

    func contains(_ other: NormalizedPath) -> Bool {
        other.keys(caseSensitive: isCaseSensitive).starts(with: keys(caseSensitive: isCaseSensitive))
    }

    /// Whether both paths name the same location.
    func matches(_ other: NormalizedPath) -> Bool {
        other.keys(caseSensitive: isCaseSensitive) == keys(caseSensitive: isCaseSensitive)
    }

    /// The components of `descendant` below this path, as `descendant` spells them.
    func relativeComponents(of descendant: NormalizedPath) -> [String]? {
        guard contains(descendant) else { return nil }
        let depth = keys(caseSensitive: isCaseSensitive).count
        return Array(descendant.components.dropFirst(descendant.firmlinkPrefixLength + depth))
    }

    static func == (lhs: NormalizedPath, rhs: NormalizedPath) -> Bool {
        lhs.matches(rhs) && rhs.matches(lhs)
    }

    private static let firmlinkedDirectories: Set<String> = ["var", "tmp", "etc"]

    private var firmlinkPrefixLength: Int {
        components.count >= 2 && components[0] == "private" && Self.firmlinkedDirectories.contains(components[1]) ? 1 : 0
    }

    private func keys(caseSensitive: Bool) -> [String] {
        components.dropFirst(firmlinkPrefixLength).map { component in
            let composed = component.precomposedStringWithCanonicalMapping
            return caseSensitive ? composed : composed.folding(options: .caseInsensitive, locale: nil)
        }
    }
}
