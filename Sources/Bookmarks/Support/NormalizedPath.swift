import Foundation

struct NormalizedPath: Hashable, Sendable, CustomStringConvertible {
    let components: [String]

    init(_ url: URL) {
        components = url.standardizedFileURL.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    init(_ path: String) {
        self.init(URL(filePath: path))
    }

    var string: String {
        "/" + components.joined(separator: "/")
    }

    var description: String { string }

    func contains(_ other: NormalizedPath) -> Bool {
        other.components.starts(with: components)
    }

    func relativeComponents(of descendant: NormalizedPath) -> [String]? {
        contains(descendant) ? Array(descendant.components.dropFirst(components.count)) : nil
    }
}
