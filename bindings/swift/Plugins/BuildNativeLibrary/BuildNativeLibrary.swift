// BuildNativeLibrary — a command plugin that runs bindings/swift/scripts/build-libs.sh.
//
// The package links one prebuilt archive, libidax_swift_native.a. Without it
// Package.swift falls back to upstream's pkg-config route and Xcode reports
// "couldn't find pc file for idax-swift" while resolving the package. Building
// the archive is a single script invocation, but from Xcode that means leaving
// for a terminal. This plugin puts it behind the package's context menu.
//
// The plugin holds no build logic of its own. build-libs.sh remains the single
// source of truth; this only supplies the context a graphical environment does
// not have. Processes launched by Xcode inherit launchd's environment, so
// neither IDADIR nor a PATH containing Homebrew is present.
//
// See docs/fork/evolutions/draft-xcode-gui-build-libs-plugin.md.

import Foundation
import PackagePlugin

@main
struct BuildNativeLibrary: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let packageDirectory = context.package.directoryURL
        let scriptURL = packageDirectory
            .appending(path: "bindings/swift/scripts/build-libs.sh")

        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            throw PluginFailure(
                "Build script not found at \(scriptURL.path)."
            )
        }

        // Xcode passes the targets selected in its plugin dialog as
        // `--target <name>`. This plugin builds one package-wide archive and
        // has no per-target behaviour, so the selection is dropped rather than
        // forwarded — build-libs.sh rejects options it does not know.
        var argumentExtractor = ArgumentExtractor(arguments)
        _ = argumentExtractor.extractOption(named: "target")
        let scriptArguments = argumentExtractor.remainingArguments

        // The script prints its usage and exits without building, so the
        // closing advice below would be noise.
        let requestsUsage = scriptArguments.contains("--help")
            || scriptArguments.contains("-h")

        let cmakeDirectory = try locateCMakeDirectory()
        let idaRuntimeDirectory = try locateIDARuntimeDirectory()

        print("==> Using cmake from \(cmakeDirectory)")
        print("==> Using IDA runtime at \(idaRuntimeDirectory)")

        var environment = ProcessInfo.processInfo.environment
        environment["IDADIR"] = idaRuntimeDirectory
        environment["PATH"] = pathByPrepending(cmakeDirectory, to: environment["PATH"])

        // Bash rather than the script itself: the executable bit is not
        // guaranteed to survive every checkout, and the script declares bash.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + scriptArguments
        process.environment = environment
        process.currentDirectoryURL = packageDirectory
        // Inherited handles, so CMake progress reaches Xcode's plugin result
        // window as it happens rather than in one burst at the end.

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PluginFailure(
                "build-libs.sh failed with exit status \(process.terminationStatus)."
            )
        }

        guard !requestsUsage else { return }

        // Whether the archive exists is decided while the manifest is
        // evaluated, and that result is cached. The archive has only just
        // appeared, so the cached answer still says it is absent and the link
        // line still lacks its search path. Note that `swift package reset`
        // is not enough: the manifest cache SwiftPM consults is the shared one
        // under ~/Library/Caches, which reset leaves alone.
        print("""

            ==> Done. Have the manifest evaluated again so it picks up the archive:
                  Xcode:        File > Packages > Reset Package Caches
                  Command line: swift package purge-cache
            """)
    }

    // MARK: - Tool discovery

    /// The directory holding a usable `cmake`, searched in PATH first so an
    /// explicitly configured toolchain wins over the conventional locations.
    private func locateCMakeDirectory() throws -> String {
        let fileManager = FileManager.default
        func holdsCMake(_ directory: String) -> Bool {
            fileManager.isExecutableFile(atPath: "\(directory)/cmake")
        }

        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathDirectories = searchPath
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        // Homebrew on Apple silicon, Homebrew on Intel, CMake.app's own
        // command-line tools, MacPorts.
        let conventionalDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/CMake.app/Contents/bin",
            "/opt/local/bin",
        ]

        guard let directory = (pathDirectories + conventionalDirectories)
            .first(where: holdsCMake)
        else {
            throw PluginFailure("""
                cmake not found. Xcode launches plugins with launchd's PATH, which \
                does not include Homebrew, and no cmake was found in the \
                conventional locations either. Install CMake, or run the script \
                directly: bindings/swift/scripts/build-libs.sh
                """)
        }
        return directory
    }

    /// The IDA runtime directory holding libida and libidalib. Mirrors the
    /// discovery order in Package.swift's `idaRuntimeDirectory`: the manifest
    /// needs the same answer to put the runtime on the link line, and cannot
    /// share code with a plugin — a manifest is its own compilation unit.
    private func locateIDARuntimeDirectory() throws -> String {
        let fileManager = FileManager.default
        func containsRuntime(_ directory: String) -> Bool {
            fileManager.fileExists(atPath: "\(directory)/libida.dylib")
        }

        if let directory = ProcessInfo.processInfo.environment["IDADIR"],
           containsRuntime(directory) {
            return directory
        }

        let applications = (try? fileManager.contentsOfDirectory(atPath: "/Applications")) ?? []
        let discovered = applications
            .filter { $0.hasPrefix("IDA") && $0.hasSuffix(".app") }
            .sorted()
            .reversed()
            .map { "/Applications/\($0)/Contents/MacOS" }
            .first(where: containsRuntime)

        guard let discovered else {
            throw PluginFailure("""
                No IDA runtime found. Xcode does not inherit IDADIR from a shell, \
                and no /Applications/IDA*.app holds libida.dylib. Install IDA, or \
                run the script from a terminal with IDADIR set: \
                bindings/swift/scripts/build-libs.sh
                """)
        }
        return discovered
    }

    private func pathByPrepending(_ directory: String, to searchPath: String?) -> String {
        guard let searchPath, !searchPath.isEmpty else { return directory }
        let existing = searchPath.split(separator: ":").map(String.init)
        guard !existing.contains(directory) else { return searchPath }
        return ([directory] + existing).joined(separator: ":")
    }
}

private struct PluginFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
