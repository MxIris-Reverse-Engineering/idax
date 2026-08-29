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

// Every call into idalib has to happen on the thread that initialised it, which
// in practice is process main — the reasoning and the evidence are in
// Sources/IDAX/Concurrency.swift. Module-wide default isolation is what turns
// that from a convention into a compile-time guarantee: one setting covers every
// declaration in the module, including ones added years from now by someone who
// never read the rule.
//
// `defaultIsolation` accepts only `MainActor.Type?` — the parameter type is
// hardcoded in PackageDescription — which is why `IDAActor` is a typealias for
// `MainActor` rather than an independent global actor.
//
// The upcoming features below are what Xcode bundles as its "Approachable
// Concurrency" switch, minus the three that Swift 6 already enables by default
// (DisableOutwardActorInference, GlobalActorIsolatedTypesUsability,
// InferSendableFromCaptures). NonisolatedNonsendingByDefault is the load-bearing
// one here: without it a `nonisolated` async function hops to the global
// executor, and hopping off the main thread is a deadlock, not a slowdown.
// Consumer mode links CIDAX as a binaryTarget, which cannot carry linkerSettings,
// so nothing puts libida on the link line — and libidax_shim.a is a single
// translation unit that unconditionally references ida::script symbols such as
// eval_expr. Developer mode gets these flags through the CIDAX target itself.
//
// These go on the executable and test targets only, never on the IDAX library.
// unsafeFlags on a library target makes the whole package unusable as a
// dependency; executables and test bundles are never depended upon, so they can
// carry them. A downstream library consumer links the IDA runtime itself, which
// is what the migration guide documents.
let runtimeLinkerSettings: [LinkerSetting] = devMode || idaRuntimeLinkerFlags.isEmpty
    ? []
    : [.unsafeFlags(idaRuntimeLinkerFlags)]

let idaxSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableExperimentalFeature("SafeInteropWrappers"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

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
            swiftSettings: idaxSwiftSettings
        ),
        .executableTarget(
            name: "idax-example",
            dependencies: ["IDAX"],
            path: "bindings/swift/Examples",
            swiftSettings: idaxSwiftSettings,
            linkerSettings: runtimeLinkerSettings
        ),
        .target(
            name: "IDAXDyldCacheDatabaseCreatorCore",
            dependencies: [
                "IDAX",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tools/DyldCacheDatabaseCreatorCore",
            swiftSettings: idaxSwiftSettings
        ),
        .executableTarget(
            name: "IDAXDyldCacheDatabaseCreator",
            dependencies: [
                "IDAXDyldCacheDatabaseCreatorCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tools/DyldCacheDatabaseCreator",
            swiftSettings: idaxSwiftSettings,
            linkerSettings: runtimeLinkerSettings
        ),
        .testTarget(
            name: "IDAXTests",
            dependencies: ["IDAX"],
            path: "bindings/swift/Tests/IDAXTests",
            swiftSettings: idaxSwiftSettings,
            linkerSettings: runtimeLinkerSettings
        ),
        .testTarget(
            name: "IDAXDyldCacheDatabaseCreatorTests",
            dependencies: [
                "IDAXDyldCacheDatabaseCreatorCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tests/IDAXDyldCacheDatabaseCreatorTests",
            swiftSettings: idaxSwiftSettings
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
