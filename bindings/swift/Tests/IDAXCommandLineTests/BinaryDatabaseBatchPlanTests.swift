import ArgumentParser
import Foundation
import Testing
@testable import IDAXCommandLineCore

@Suite("Binary Database Batch Plan")
struct BinaryDatabaseBatchPlanTests {
    @Test func singleBinaryKeepsTheDerivedOutputName() throws {
        let batchPlan = try BinaryDatabaseBatchPlan(
            binaryPaths: ["/Applications/Foo.app/Contents/MacOS/Foo"],
            outputDatabasePath: nil,
            outputDirectoryPath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(batchPlan.jobs.count == 1)
        #expect(batchPlan.jobs[0].outputFileURL.path == "/Work/Foo.i64")
    }

    @Test func singleBinaryStillAcceptsAnExplicitOutput() throws {
        let batchPlan = try BinaryDatabaseBatchPlan(
            binaryPaths: ["/bin/ls"],
            outputDatabasePath: "Databases/Listing",
            outputDirectoryPath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(batchPlan.jobs[0].outputFileURL.path == "/Work/Databases/Listing.i64")
    }

    @Test func eachBinaryIsNamedAfterItselfInTheOutputDirectory() throws {
        let batchPlan = try BinaryDatabaseBatchPlan(
            binaryPaths: ["/bin/ls", "/bin/cat", "relative/tool.dylib"],
            outputDatabasePath: nil,
            outputDirectoryPath: "/Databases",
            currentDirectoryPath: "/Work"
        )

        #expect(batchPlan.jobs.map(\.outputFileURL.path) == [
            "/Databases/ls.i64",
            "/Databases/cat.i64",
            "/Databases/tool.i64",
        ])
        #expect(batchPlan.jobs[2].binaryFileURL.path == "/Work/relative/tool.dylib")
    }

    @Test func outputDirectoryIsRelativeToTheCurrentDirectory() throws {
        let batchPlan = try BinaryDatabaseBatchPlan(
            binaryPaths: ["/bin/ls", "/bin/cat"],
            outputDatabasePath: nil,
            outputDirectoryPath: "databases",
            currentDirectoryPath: "/Work"
        )

        #expect(batchPlan.jobs[0].outputFileURL.path == "/Work/databases/ls.i64")
    }

    @Test func severalBinariesWithoutAnOutputDirectoryLandInTheCurrentDirectory() throws {
        let batchPlan = try BinaryDatabaseBatchPlan(
            binaryPaths: ["/bin/ls", "/bin/cat"],
            outputDatabasePath: nil,
            outputDirectoryPath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(batchPlan.jobs.map(\.outputFileURL.path) == ["/Work/ls.i64", "/Work/cat.i64"])
    }

    @Test func severalBinariesRejectASingleOutputPath() {
        #expect(throws: ValidationError.self) {
            try BinaryDatabaseBatchPlan(
                binaryPaths: ["/bin/ls", "/bin/cat"],
                outputDatabasePath: "/Databases/Everything.i64",
                outputDirectoryPath: nil,
                currentDirectoryPath: "/Work"
            )
        }
    }

    @Test func outputAndOutputDirectoryCannotBeCombined() {
        #expect(throws: ValidationError.self) {
            try BinaryDatabaseBatchPlan(
                binaryPaths: ["/bin/ls"],
                outputDatabasePath: "/Databases/Listing.i64",
                outputDirectoryPath: "/Databases",
                currentDirectoryPath: "/Work"
            )
        }
    }

    /// Every application bundle names its executable after the bundle, so this
    /// collision is the common case rather than a contrived one.
    @Test func binariesSharingAnOutputNameAreRejected() {
        #expect(throws: ValidationError.self) {
            try BinaryDatabaseBatchPlan(
                binaryPaths: [
                    "/Applications/A.app/Contents/MacOS/App",
                    "/Applications/B.app/Contents/MacOS/App",
                ],
                outputDatabasePath: nil,
                outputDirectoryPath: "/Databases",
                currentDirectoryPath: "/Work"
            )
        }
    }

    @Test func theSameBinaryTwiceIsRejected() {
        #expect(throws: ValidationError.self) {
            try BinaryDatabaseBatchPlan(
                binaryPaths: ["/bin/ls", "/bin/ls"],
                outputDatabasePath: nil,
                outputDirectoryPath: "/Databases",
                currentDirectoryPath: "/Work"
            )
        }
    }

    @Test func noBinariesIsRejected() {
        #expect(throws: ValidationError.self) {
            try BinaryDatabaseBatchPlan(
                binaryPaths: [],
                outputDatabasePath: nil,
                outputDirectoryPath: nil,
                currentDirectoryPath: "/Work"
            )
        }
    }

    // Parsing goes through validate(), so these use paths that exist.

    @Test func severalPathsAndOptionsParse() throws {
        let outputDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectoryURL) }

        let command = try BinaryDatabaseCreator.parse([
            "/bin/ls", "/bin/cat",
            "--output-dir", outputDirectoryURL.path,
            "--jobs", "3",
            "--arch", "x86_64",
            "--overwrite",
        ])

        #expect(command.binaryPaths == ["/bin/ls", "/bin/cat"])
        #expect(command.outputDirectoryPath == outputDirectoryURL.path)
        #expect(command.maximumConcurrentJobs == 3)
        #expect(command.requestedArchitecture == .x86_64)
        #expect(command.overwriteExistingOutput)
    }

    @Test func pathsAfterAnOptionStillParse() throws {
        let outputDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectoryURL) }

        let command = try BinaryDatabaseCreator.parse([
            "--output-dir", outputDirectoryURL.path,
            "/bin/ls", "/bin/cat",
        ])

        #expect(command.binaryPaths == ["/bin/ls", "/bin/cat"])
    }

    @Test func aJobCountBelowOneIsRejected() {
        #expect(throws: (any Error).self) {
            try BinaryDatabaseCreator.parse(["/bin/ls", "--jobs", "0"])
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idax-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    @Test func jobCountDefaultsToOne() throws {
        let command = try BinaryDatabaseCreator.parse(["/bin/ls"])

        #expect(command.maximumConcurrentJobs == 1)
    }
}
