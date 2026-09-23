public import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Describes the process the library runs in: the platform and whether the App Sandbox applies.
public struct SandboxEnvironment: Sendable, Hashable {
    /// The platform family, which decides which bookmark kinds exist.
    public enum Platform: Sendable, Hashable, CaseIterable {
        case macOS
        case macCatalyst
        case iOS
        case visionOS
        case other
    }

    /// The platform family.
    public var platform: Platform
    /// Whether the App Sandbox restricts file access in this process.
    public var isSandboxed: Bool

    /// Creates an explicit environment, typically for tests.
    public init(platform: Platform, isSandboxed: Bool) {
        self.platform = platform
        self.isSandboxed = isSandboxed
    }

    /// Whether security-scoped bookmarks (`.appScoped`, `.documentScoped`) exist on this platform.
    public var supportsSecurityScope: Bool {
        platform == .macOS || platform == .macCatalyst
    }

    /// The environment of the current process.
    public static let current = SandboxEnvironment(
        platform: .compiled,
        isSandboxed: detectSandbox(ProcessInfo.processInfo.environment)
    )

    static func detectSandbox(_ environment: [String: String], platform: Platform = .compiled) -> Bool {
        switch platform {
        case .macOS, .macCatalyst:
            environment["APP_SANDBOX_CONTAINER_ID"] != nil
        case .iOS, .visionOS:
            true
        case .other:
            false
        }
    }

    /// The user's real home directory, which differs from `FileManager`'s home inside the sandbox.
    public static var realHomeDirectory: URL {
        #if os(macOS)
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        #endif
        return URL.homeDirectory
    }
}

extension SandboxEnvironment.Platform {
    static var compiled: Self {
        #if targetEnvironment(macCatalyst)
        .macCatalyst
        #elseif os(macOS)
        .macOS
        #elseif os(visionOS)
        .visionOS
        #elseif os(iOS)
        .iOS
        #else
        .other
        #endif
    }
}
