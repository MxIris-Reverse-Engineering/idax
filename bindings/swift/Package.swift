// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Pre-build libraries first: scripts/build-libs.sh
// Set IDAX_LIB_DIR to override library search path.
let libDir: String = {
    if let dir = ProcessInfo.processInfo.environment["IDAX_LIB_DIR"] {
        return dir
    }
    let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    return "\(packageDir)/.build-libs"
}()

let idaDir: String = ProcessInfo.processInfo.environment["IDADIR"] ?? {
    #if os(macOS)
    let fm = FileManager.default
    if let contents = try? fm.contentsOfDirectory(atPath: "/Applications") {
        for name in contents.sorted().reversed() {
            if name.hasPrefix("IDA") && name.hasSuffix(".app") {
                return "/Applications/\(name)/Contents/MacOS"
            }
        }
    }
    return "/Applications/IDA Professional 9.3.app/Contents/MacOS"
    #elseif os(Linux)
    return "/opt/idapro"
    #else
    return ""
    #endif
}()

let package = Package(
    name: "IDA",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IDA", targets: ["IDA"]),
    ],
    targets: [
        .target(
            name: "CIDA",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(libDir)",
                    "-lidax", "-lidax_shim",
                    "-L\(idaDir)",
                    "-lida", "-lidalib",
                ]),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "IDA",
            dependencies: ["CIDA"]
        ),
        .testTarget(
            name: "IDATests",
            dependencies: ["IDA"]
        ),
    ]
)
