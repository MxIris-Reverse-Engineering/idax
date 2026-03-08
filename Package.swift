// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Pre-build libraries first: bindings/swift/scripts/build-libs.sh
// Set IDAX_LIB_DIR to override library search path.
let libDir: String = {
    if let dir = ProcessInfo.processInfo.environment["IDAX_LIB_DIR"] {
        return dir
    }
    let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    return "\(packageDir)/bindings/swift/.build-libs"
}()

let package = Package(
    name: "IDAX",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IDAX", targets: ["IDAX"]),
    ],
    targets: [
        .target(
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
                    "-Xlinker", "-undefined",
                    "-Xlinker", "dynamic_lookup",
                ]),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "IDAX",
            dependencies: ["CIDAX"],
            path: "bindings/swift/Sources/IDAX",
            swiftSettings: [
                .enableExperimentalFeature("SafeInteropWrappers"),
            ]
        ),
        .testTarget(
            name: "IDAXTests",
            dependencies: ["IDAX"],
            path: "bindings/swift/Tests/IDAXTests"
        ),
    ]
)
