// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MuxiCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "MuxiCore",
            targets: ["MuxiCore"]
        ),
    ],
    targets: [
        // C target: VT Parser (symlinked from ../../core/vt_parser)
        .target(
            name: "CVTParser",
            path: "CSources_VTParser",
            sources: ["vt_parser.c"],
            publicHeadersPath: "include"
        ),

        // C target: Tmux Protocol (symlinked from ../../core/tmux_protocol)
        .target(
            name: "CTmuxProtocol",
            path: "CSources_TmuxProtocol",
            sources: ["tmux_protocol.c"],
            publicHeadersPath: "include"
        ),

        // Swift wrapper that re-exports the C targets
        .target(
            name: "MuxiCore",
            dependencies: ["CVTParser", "CTmuxProtocol"],
            path: "Sources/MuxiCore"
        ),

        // Tests
        .testTarget(
            name: "MuxiCoreTests",
            dependencies: ["MuxiCore", "CVTParser", "CTmuxProtocol"],
            path: "Tests/MuxiCoreTests"
        ),
    ]
)
