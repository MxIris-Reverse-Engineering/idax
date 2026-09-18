// swift-tools-version: 6.0
import PackageDescription
import Foundation

// This manifest is fork-only. Upstream's version declares the library targets
// alone and expects consumers to run CMake and set PKG_CONFIG_PATH first. This
// fork adds the `idax` command-line tool and a prebuilt-artifact route so the
// tool can be built and installed without a CMake round-trip every time.
//
// See docs/fork/evolutions/draft-shrink-fork-to-cli.md.

// The native transport archive built by bindings/swift/CMakeLists.txt as the
// `idax_swift_native` target. When a prebuilt copy is present, link it
// directly; otherwise fall back to upstream's pkg-config route.
//
// Build one with bindings/swift/scripts/build-libs.sh.
let prebuiltNativeDirectory: String? = {
    let fileManager = FileManager.default
    func containsArchive(_ directory: String) -> Bool {
        fileManager.fileExists(atPath: "\(directory)/libidax_swift_native.a")
    }

    if let directory = ProcessInfo.processInfo.environment["IDAX_LIB_DIR"], containsArchive(directory) {
        return directory
    }

    let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    let conventionalDirectory = "\(packageDirectory)/bindings/swift/.build-libs"
    return containsArchive(conventionalDirectory) ? conventionalDirectory : nil
}()

// The native archive calls into the IDA runtime, so anything that links it —
// the command-line tool, the examples, the test bundles — needs libida and
// libidalib on the link line. Mirrors the discovery order in
// bindings/rust/idax-sys/build.rs: $IDADIR first, then installed applications.
//
// Do not substitute `-undefined dynamic_lookup` for this. That only appears to
// work while the archive happens to reference nothing requiring eager binding;
// the IDC script domain references eval_expr, and the transport is compiled as
// one unit that pulls it in unconditionally. And do not reach for
// DYLD_INSERT_LIBRARIES either — the symbol resolves, but idalib never runs its
// own initialisation and the first call into ida::database::init hits a null.
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

// These go on executable and test targets only, never on the IDAX library.
// unsafeFlags on a library target makes the whole package unusable as a
// dependency; executables and test bundles are never depended upon, so they can
// carry them. A downstream library consumer supplies these itself, which is
// what upstream's pkg-config route documents.
let nativeLinkerFlags: [String] = {
    var flags: [String] = []
    if let prebuiltNativeDirectory {
        // The module map already carries `link "idax_swift_native"`, so only the
        // search path is needed here.
        flags += ["-L\(prebuiltNativeDirectory)", "-lc++"]
    }
    if let idaRuntimeDirectory {
        flags += [
            "-L\(idaRuntimeDirectory)", "-lida", "-lidalib",
            "-Xlinker", "-rpath", "-Xlinker", idaRuntimeDirectory,
        ]
    }
    return flags
}()

let clientLinkerSettings: [LinkerSetting] =
    nativeLinkerFlags.isEmpty ? [] : [.unsafeFlags(nativeLinkerFlags)]

// Without a prebuilt archive, fall back to upstream's pkg-config metadata,
// which bindings/swift/CMakeLists.txt generates next to the archive.
let cidaxTarget: Target = prebuiltNativeDirectory == nil
    ? .systemLibrary(
        name: "CIDAX",
        path: "bindings/swift/Sources/CIDAX",
        pkgConfig: "idax-swift"
    )
    : .systemLibrary(
        name: "CIDAX",
        path: "bindings/swift/Sources/CIDAX"
    )

let package = Package(
    name: "IDAX",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IDAX", targets: ["IDAX"]),
        .executable(name: "idax", targets: ["IDAXCommandLine"]),
        // Upstream also exports an `IDAXShared` dynamic library, the support
        // image its native plugin/loader/processor add-ons link against. This
        // fork does not build add-ons, and a dynamic product cannot carry the
        // linker settings the prebuilt-artifact route needs — a product is not
        // a target — so it would fail to link here. Build add-ons from
        // upstream, or from a checkout using upstream's pkg-config route.
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
            path: "bindings/swift/Sources/IDAX"
        ),
        .testTarget(
            name: "IDAXTests",
            dependencies: ["IDAX", "CIDAX"],
            path: "bindings/swift/Tests/IDAXTests",
            linkerSettings: clientLinkerSettings
        ),
        .executableTarget(
            name: "IDAXRuntimeTests",
            dependencies: ["IDAX", "CIDAX"],
            path: "bindings/swift/Tests/Runtime",
            linkerSettings: clientLinkerSettings
        ),
        .executableTarget(
            name: "IDAXInventory",
            dependencies: ["IDAX"],
            path: "bindings/swift/Examples/Inventory",
            linkerSettings: clientLinkerSettings
        ),

        // Fork-only: C transport for additions upstream does not have.
        // A separate module rather than an addition to upstream's CIDAX
        // umbrella, so upstream syncs never conflict here.
        .target(
            name: "CIDAXFork",
            path: "bindings/swift/Sources/CIDAXFork",
            publicHeadersPath: "include",
            cxxSettings: [
                // The repository's public C++ headers, reached from this
                // target's directory. Used by shim.cpp only; the module's own
                // header is plain C.
                .headerSearchPath("../../../../include"),
            ]
        ),

        // Fork-only: the idax command-line tool.
        .target(
            name: "IDAXCommandLineCore",
            dependencies: [
                "IDAX",
                "CIDAXFork",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tools/CommandLineCore"
        ),
        .executableTarget(
            name: "IDAXCommandLine",
            dependencies: [
                "IDAXCommandLineCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tools/CommandLine",
            linkerSettings: clientLinkerSettings
        ),
        .testTarget(
            name: "IDAXCommandLineTests",
            dependencies: [
                "IDAXCommandLineCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "bindings/swift/Tests/IDAXCommandLineTests",
            linkerSettings: clientLinkerSettings
        ),

        // Fork-only: runs bindings/swift/scripts/build-libs.sh from Xcode's
        // package context menu, so the prebuilt archive can be produced without
        // leaving for a terminal. The script stays the single source of truth;
        // the plugin only supplies the IDA runtime path and a PATH holding
        // cmake, neither of which a process launched by Xcode inherits.
        //
        // Network access is requested because CMake fetches the IDA SDK when
        // IDASDK is unset.
        .plugin(
            name: "BuildNativeLibrary",
            capability: .command(
                intent: .custom(
                    verb: "build-libs",
                    description: "Build libidax_swift_native.a for the Swift package"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Writes the CMake build tree and the built archive under bindings/swift/"
                    ),
                    .allowNetworkConnections(
                        scope: .all(ports: []),
                        reason: "CMake fetches the pinned IDA SDK when IDASDK is unset"
                    ),
                ]
            ),
            path: "bindings/swift/Plugins/BuildNativeLibrary"
        ),
    ],
    swiftLanguageModes: [.v6],
    // CIDAXFork's shim.cpp includes the repository's C++23 public headers.
    cxxLanguageStandard: .cxx2b
)
