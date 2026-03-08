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
        .testTarget(
            name: "IDAXTests",
            dependencies: ["IDAX"],
            path: "bindings/swift/Tests/IDAXTests"
        ),
    ]
)
