// swift-tools-version: 6.2

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "swift-bookmarks",
    platforms: [
        .macOS(.v15),
        .macCatalyst(.v18),
        .iOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "Bookmarks", targets: ["Bookmarks"]),
        .library(name: "BookmarksUI", targets: ["BookmarksUI"]),
        .library(name: "BookmarksTesting", targets: ["BookmarksTesting"]),
    ],
    targets: [
        .target(
            name: "Bookmarks",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BookmarksUI",
            dependencies: ["Bookmarks"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BookmarksTesting",
            dependencies: ["Bookmarks"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BookmarksTests",
            dependencies: ["Bookmarks", "BookmarksTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BookmarksSystemTests",
            dependencies: ["Bookmarks"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BookmarksTestingTests",
            dependencies: ["Bookmarks", "BookmarksTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BookmarksUITests",
            dependencies: ["Bookmarks", "BookmarksUI", "BookmarksTesting"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
