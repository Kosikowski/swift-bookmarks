/// How the starts and stops a ``FakeBookmarkEngine`` saw line up.
public struct BalanceReport: Sendable, Equatable, CustomStringConvertible {
    /// Starts without a matching stop, per path.
    public let outstanding: [String: Int]
    /// Stops that had no start to balance.
    public let unbalancedStops: [String]
    /// Starts on URLs the engine didn't issue, which usually means a URL was rebuilt from a path.
    public let startsOnUnissuedURLs: [String]

    /// Whether every start was balanced by exactly one stop.
    public var isBalanced: Bool {
        outstanding.isEmpty && unbalancedStops.isEmpty
    }

    public var description: String {
        var parts: [String] = []
        if !outstanding.isEmpty {
            parts.append("outstanding: " + outstanding.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        }
        if !unbalancedStops.isEmpty {
            parts.append("unbalanced stops: " + unbalancedStops.joined(separator: ", "))
        }
        if !startsOnUnissuedURLs.isEmpty {
            parts.append("starts on unissued URLs: " + startsOnUnissuedURLs.joined(separator: ", "))
        }
        return parts.isEmpty ? "balanced" : parts.joined(separator: "; ")
    }
}
