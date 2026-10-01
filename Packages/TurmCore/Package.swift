// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "TurmCore",
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [
        .library(name: "TurmCore", targets: ["TurmCore"]),
    ],
    targets: [
        .target(name: "TurmCore", swiftSettings: settings),
        .testTarget(name: "TurmCoreTests", dependencies: ["TurmCore"], swiftSettings: settings),
    ]
)
