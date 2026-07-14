// swift-tools-version: 6.2
import PackageDescription
import Foundation

// IDAX_DEV=1 swift build  → developer mode (link pre-built .a files)
// swift build              → consumer mode  (use XCFramework)
let devMode = ProcessInfo.processInfo.environment["IDAX_DEV"] != nil

let libDir: String = {
    if let dir = ProcessInfo.processInfo.environment["IDAX_LIB_DIR"] {
        return dir
    }
    let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    return "\(packageDir)/bindings/swift/.build-libs"
}()

let cidaxTarget: Target = devMode
    ? .target(
        name: "CIDAX",
        path: "bindings/swift/Sources/CIDAX",
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("include"),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L\(libDir)",
                "-lidax", "-lidax_shim",
            ]),
        ]
    )
    : .binaryTarget(
        name: "CIDAX",
        path: "bindings/swift/Frameworks/CIDAX.xcframework"
    )

let package = Package(
    name: "IDAX",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IDAX", targets: ["IDAX"]),
        .executable(
            name: "idax-dyld-cache-database-creator",
            targets: ["IDAXDyldCacheDatabaseCreator"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.8.2"
        ),
    ],
    targets: [
        cidaxTarget,
        .target(
            name: "IDAX",
            dependencies: ["CIDAX"],
            path: "bindings/swift/Sources/IDAX",
            swiftSettings: [
                .enableExperimentalFeature("SafeInteropWrappers"),
            ]
        ),
        .executableTarget(
            name: "idax-example",
            dependencies: ["IDAX"],
            path: "bindings/swift/Examples"
        ),
        .target(
            name: "IDAXDyldCacheDatabaseCreatorCore",
            dependencies: [
                "IDAX",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tools/DyldCacheDatabaseCreatorCore"
        ),
        .executableTarget(
            name: "IDAXDyldCacheDatabaseCreator",
            dependencies: ["IDAXDyldCacheDatabaseCreatorCore"],
            path: "bindings/swift/Tools/DyldCacheDatabaseCreator"
        ),
        .testTarget(
            name: "IDAXTests",
            dependencies: ["IDAX"],
            path: "bindings/swift/Tests/IDAXTests"
        ),
        .testTarget(
            name: "IDAXDyldCacheDatabaseCreatorTests",
            dependencies: [
                "IDAXDyldCacheDatabaseCreatorCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tests/IDAXDyldCacheDatabaseCreatorTests"
        ),
        .plugin(
            name: "BuildXCFramework",
            capability: .command(
                intent: .custom(
                    verb: "build-xcframework",
                    description: "Build CIDAX.xcframework (macOS arm64 + x86_64) from the C++ sources."
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Write the generated CIDAX.xcframework and CMake build artifacts into the package directory."
                    ),
                    .allowNetworkConnections(
                        scope: .all(),
                        reason: "CMake FetchContent may download the IDA SDK when IDASDK is unset."
                    ),
                ]
            ),
            path: "bindings/swift/Plugins/BuildXCFramework"
        ),
    ]
)
