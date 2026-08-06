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

// libidax.a calls into the IDA runtime, so anything that links — the example
// executable, the test bundle, a downstream consumer — needs libida/libidalib
// on the link line. Mirrors the discovery order in
// bindings/rust/idax-sys/build.rs: $IDADIR first, then installed applications.
//
// Do not substitute `-undefined dynamic_lookup` for this. That only appears to
// work while the archive happens to reference nothing requiring eager binding;
// upstream's IDC script domain (script.cpp, added 2026-07) references
// eval_expr, and the shim is a single translation unit that pulls it in
// unconditionally. And do not reach for DYLD_INSERT_LIBRARIES either — the
// symbol resolves, but idalib never runs its own initialisation and the first
// call into ida::database::init hits a null.
let idaRuntimeDirectory: String? = {
    let fileManager = FileManager.default
    func containsRuntime(_ directory: String) -> Bool {
        fileManager.fileExists(atPath: "\(directory)/libida.dylib")
    }

    if let directory = ProcessInfo.processInfo.environment["IDADIR"], containsRuntime(directory) {
        return directory
    }

    let applications = (try? fileManager.contentsOfDirectory(atPath: "/Applications")) ?? []
    return applications
        .filter { $0.hasPrefix("IDA") && $0.hasSuffix(".app") }
        .sorted()
        .reversed()
        .map { "/Applications/\($0)/Contents/MacOS" }
        .first(where: containsRuntime)
}()

let idaRuntimeLinkerFlags: [String] = idaRuntimeDirectory.map { directory in
    ["-L\(directory)", "-lida", "-lidalib", "-Xlinker", "-rpath", "-Xlinker", directory]
} ?? []

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
                // libidax.a is C++; SPM links CIDAX as a C target and so does
                // not pull in the C++ runtime on its own.
                "-lc++",
            ] + idaRuntimeLinkerFlags),
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
