import ArgumentParser
import Foundation
import Testing
@testable import IDAXCommandLineCore

@Suite("Bundle Input")
struct BundleInputTests {
    @Test func anApplicationBundleLoadsItsExecutable() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Tool.app"),
            layout: .contents,
            executableName: "Tool"
        )

        let batchPlan = try makeBatchPlan(inputPaths: [bundleURL.path], in: rootDirectoryURL)

        #expect(batchPlan.jobs[0].binaryFileURL.path == bundleURL.path + "/Contents/MacOS/Tool")
        #expect(batchPlan.jobs[0].outputFileURL.lastPathComponent == "Tool.i64")
    }

    @Test func aVersionedFrameworkLoadsTheExecutableBehindItsTopLevelLink() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Kit.framework"),
            layout: .versionedFramework,
            executableName: "Kit"
        )

        let batchPlan = try makeBatchPlan(inputPaths: [bundleURL.path], in: rootDirectoryURL)

        #expect(
            batchPlan.jobs[0].binaryFileURL.resolvingSymlinksInPath()
                == bundleURL.appendingPathComponent("Versions/A/Kit").resolvingSymlinksInPath()
        )
        #expect(batchPlan.jobs[0].outputFileURL.lastPathComponent == "Kit.i64")
    }

    @Test func anIOSStyleBundleLoadsItsTopLevelExecutable() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Mobile.app"),
            layout: .flat,
            executableName: "Mobile"
        )

        let batchPlan = try makeBatchPlan(inputPaths: [bundleURL.path], in: rootDirectoryURL)

        #expect(batchPlan.jobs[0].binaryFileURL.path == bundleURL.path + "/Mobile")
    }

    /// The database is named after what IDA loads, so a bundle and the path
    /// of its executable produce the same name.
    @Test func theDatabaseIsNamedAfterTheExecutableRatherThanTheBundle() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Code Editor.app"),
            layout: .contents,
            executableName: "Electron"
        )
        let outputDirectoryURL = rootDirectoryURL.appendingPathComponent("Databases")

        let batchPlan = try BinaryDatabaseBatchPlan(
            binaryPaths: [bundleURL.path],
            outputDatabasePath: nil,
            outputDirectoryPath: outputDirectoryURL.path,
            currentDirectoryPath: rootDirectoryURL.path
        )

        #expect(batchPlan.jobs[0].outputFileURL.path == outputDirectoryURL.path + "/Electron.i64")
    }

    @Test func aRelativeBundlePathIsResolvedAgainstTheCurrentDirectory() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Tool.app"),
            layout: .contents,
            executableName: "Tool"
        )

        let batchPlan = try makeBatchPlan(inputPaths: ["Tool.app"], in: rootDirectoryURL)

        #expect(batchPlan.jobs[0].binaryFileURL.path == bundleURL.path + "/Contents/MacOS/Tool")
        #expect(batchPlan.jobs[0].bundleURL?.path == bundleURL.path)
    }

    @Test func aBinaryGivenDirectlyRecordsNoBundle() throws {
        let batchPlan = try BinaryDatabaseBatchPlan(
            binaryPaths: ["/bin/ls"],
            outputDatabasePath: nil,
            outputDirectoryPath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(batchPlan.jobs[0].binaryFileURL.path == "/bin/ls")
        #expect(batchPlan.jobs[0].bundleURL == nil)
    }

    @Test func aBundleAndItsOwnExecutableAreTheSameInput() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Tool.app"),
            layout: .contents,
            executableName: "Tool"
        )

        #expect(throws: ValidationError.self) {
            try makeBatchPlan(
                inputPaths: [bundleURL.path, bundleURL.path + "/Contents/MacOS/Tool"],
                in: rootDirectoryURL
            )
        }
    }

    /// AppKit.framework on disk names `AppKit` but holds no binary: since
    /// macOS 11 it is only in the dyld shared cache. The message has to say
    /// where to go instead.
    @Test func aBundleWhoseExecutableIsMissingPointsAtTheDyldCache() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Kit.framework"),
            layout: .versionedFramework,
            executableName: "Kit",
            writingExecutable: false
        )

        let error = try #require(throws: ValidationError.self) {
            try makeBatchPlan(inputPaths: [bundleURL.path], in: rootDirectoryURL)
        }
        #expect(error.message.contains("idax dyld-cache"))
    }

    @Test func aDirectoryThatIsNotABundleIsRejected() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }

        let error = try #require(throws: ValidationError.self) {
            try makeBatchPlan(inputPaths: [rootDirectoryURL.path], in: rootDirectoryURL)
        }
        #expect(error.message.contains("not a bundle"))
    }

    @Test func anEmptyPathIsRejectedAsEmptyRatherThanAsADirectory() throws {
        let error = try #require(throws: ValidationError.self) {
            try BinaryDatabaseBatchPlan(
                binaryPaths: [""],
                outputDatabasePath: nil,
                outputDirectoryPath: nil,
                currentDirectoryPath: FileManager.default.temporaryDirectory.path
            )
        }
        #expect(error.message.contains("cannot be empty"))
    }

    @Test func formatsAcceptsABundle() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let bundleURL = try makeBundle(
            at: rootDirectoryURL.appendingPathComponent("Tool.app"),
            layout: .contents,
            executableName: "Tool"
        )

        let command = try InputFormatLister.parse([bundleURL.path])

        #expect(try command.binaryFileURL().path == bundleURL.path + "/Contents/MacOS/Tool")
    }

    // MARK: - Helpers

    enum BundleLayout {
        /// `Contents/Info.plist` and `Contents/MacOS/<name>`: applications,
        /// app extensions, XPC services.
        case contents
        /// `Info.plist` and the executable at the top level: every iOS bundle.
        case flat
        /// `Versions/A/<name>` and `Versions/A/Resources/Info.plist`, reached
        /// through `Versions/Current` and top-level symbolic links: macOS
        /// frameworks.
        case versionedFramework
    }

    /// A bundle on disk whose Info.plist names `executableName`.
    ///
    /// - Parameter writingExecutable: false leaves the executable out, as the
    ///   system frameworks whose binaries exist only in the dyld shared cache
    ///   do.
    @discardableResult
    private func makeBundle(
        at bundleURL: URL,
        layout: BundleLayout,
        executableName: String,
        writingExecutable: Bool = true
    ) throws -> URL {
        let fileManager = FileManager.default
        let informationDirectoryURL: URL
        let executableDirectoryURL: URL
        switch layout {
        case .contents:
            informationDirectoryURL = bundleURL.appendingPathComponent("Contents")
            executableDirectoryURL = informationDirectoryURL.appendingPathComponent("MacOS")
        case .flat:
            informationDirectoryURL = bundleURL
            executableDirectoryURL = bundleURL
        case .versionedFramework:
            executableDirectoryURL = bundleURL.appendingPathComponent("Versions/A")
            informationDirectoryURL = executableDirectoryURL.appendingPathComponent("Resources")
        }
        try fileManager.createDirectory(at: informationDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: executableDirectoryURL, withIntermediateDirectories: true)

        let informationProperties: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.example.\(UUID().uuidString)",
            "CFBundlePackageType": layout == .versionedFramework ? "FMWK" : "APPL",
        ]
        let informationData = try PropertyListSerialization.data(
            fromPropertyList: informationProperties,
            format: .xml,
            options: 0
        )
        try informationData.write(to: informationDirectoryURL.appendingPathComponent("Info.plist"))

        if writingExecutable {
            try Data("executable".utf8).write(
                to: executableDirectoryURL.appendingPathComponent(executableName)
            )
        }

        if layout == .versionedFramework {
            try fileManager.createSymbolicLink(
                atPath: bundleURL.appendingPathComponent("Versions/Current").path,
                withDestinationPath: "A"
            )
            try fileManager.createSymbolicLink(
                atPath: bundleURL.appendingPathComponent(executableName).path,
                withDestinationPath: "Versions/Current/\(executableName)"
            )
            try fileManager.createSymbolicLink(
                atPath: bundleURL.appendingPathComponent("Resources").path,
                withDestinationPath: "Versions/Current/Resources"
            )
        }
        return bundleURL
    }

    private func makeBatchPlan(
        inputPaths: [String],
        in rootDirectoryURL: URL
    ) throws -> BinaryDatabaseBatchPlan {
        try BinaryDatabaseBatchPlan(
            binaryPaths: inputPaths,
            outputDatabasePath: nil,
            outputDirectoryPath: nil,
            currentDirectoryPath: rootDirectoryURL.path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idax-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
