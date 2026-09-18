import ArgumentParser
import Foundation
import Testing
@testable import IDAXCommandLineCore

@Suite("Working Database Directory")
struct WorkingDatabaseDirectoryTests {
    // MARK: - Which files travel with the input

    @Test func cachePartsAreLinkedAlongsideTheCache() {
        let partNames = WorkingDatabaseDirectory.siblingPartNames(
            ofFileNamed: "dyld_shared_cache_arm64e",
            among: [
                "dyld_shared_cache_arm64e",
                "dyld_shared_cache_arm64e.01",
                "dyld_shared_cache_arm64e.02",
                "dyld_shared_cache_arm64e.atlas",
                "dyld_shared_cache_arm64e.map",
                "dyld_shared_cache_arm64e.symbols",
            ]
        )

        #expect(partNames == [
            "dyld_shared_cache_arm64e.01",
            "dyld_shared_cache_arm64e.02",
            "dyld_shared_cache_arm64e.atlas",
            "dyld_shared_cache_arm64e.map",
            "dyld_shared_cache_arm64e.symbols",
        ])
    }

    /// Linking a leftover database in would recreate the very failure the
    /// private directory exists to prevent: IDA refuses an input whose unpacked
    /// database is lying beside it.
    @Test func leftoverDatabaseArtefactsAreNotLinked() {
        let partNames = WorkingDatabaseDirectory.siblingPartNames(
            ofFileNamed: "dyld_shared_cache_arm64e",
            among: [
                "dyld_shared_cache_arm64e",
                "dyld_shared_cache_arm64e.01",
                "dyld_shared_cache_arm64e.i64",
                "dyld_shared_cache_arm64e.id0",
                "dyld_shared_cache_arm64e.id1",
                "dyld_shared_cache_arm64e.nam",
                "dyld_shared_cache_arm64e.til",
                "dyld_shared_cache_arm64e.01.i64",
            ]
        )

        #expect(partNames == ["dyld_shared_cache_arm64e.01"])
    }

    @Test func unrelatedNeighboursAreNotLinked() {
        let partNames = WorkingDatabaseDirectory.siblingPartNames(
            ofFileNamed: "dyld_shared_cache_arm64e",
            among: [
                "dyld_shared_cache_arm64e",
                "dyld_shared_cache_arm64e.01",
                "dyld_shared_cache_x86_64",
                "dyld_shared_cache_x86_64.01",
                "notes.txt",
            ]
        )

        #expect(partNames == ["dyld_shared_cache_arm64e.01"])
    }

    @Test func aPlainBinaryHasNoParts() {
        let partNames = WorkingDatabaseDirectory.siblingPartNames(
            ofFileNamed: "Foo",
            among: ["Foo", "Bar", "Foo.i64"]
        )

        #expect(partNames.isEmpty)
    }

    // MARK: - Where the directory goes

    @Test func theTemporaryDirectoryIsUsedWhenItIsOnTheInputVolume() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        let inputFileURL = temporaryDirectoryURL.appendingPathComponent("Input")

        let parentDirectoryURL = try WorkingDatabaseDirectory.resolveParentDirectory(
            forInputAt: inputFileURL,
            preferred: nil,
            temporaryDirectoryURL: temporaryDirectoryURL
        )

        #expect(parentDirectoryURL.path == temporaryDirectoryURL.path)
    }

    /// A hard link cannot cross volumes, so a temporary directory elsewhere is
    /// unusable and the input's own directory is the fallback.
    @Test func theInputDirectoryIsTheFallbackWhenTheTemporaryDirectoryIsElsewhere() throws {
        let inputDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: inputDirectoryURL) }

        let parentDirectoryURL = try WorkingDatabaseDirectory.resolveParentDirectory(
            forInputAt: inputDirectoryURL.appendingPathComponent("Input"),
            preferred: nil,
            temporaryDirectoryURL: URL(fileURLWithPath: "/System/Volumes/Preboot")
        )

        #expect(parentDirectoryURL.path == inputDirectoryURL.path)
    }

    @Test func aMissingWorkingDirectoryIsRejected() throws {
        let inputDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: inputDirectoryURL) }

        #expect(throws: ValidationError.self) {
            try WorkingDatabaseDirectory.resolveParentDirectory(
                forInputAt: inputDirectoryURL.appendingPathComponent("Input"),
                preferred: inputDirectoryURL.appendingPathComponent("absent"),
                temporaryDirectoryURL: FileManager.default.temporaryDirectory
            )
        }
    }

    // MARK: - The directory itself

    @Test func theInputIsHardLinkedIntoTheDirectoryUnderItsOwnName() throws {
        let inputDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: inputDirectoryURL) }

        let originalInputFileURL = inputDirectoryURL.appendingPathComponent("Payload")
        try Data("payload".utf8).write(to: originalInputFileURL)

        let workingDirectory = try WorkingDatabaseDirectory.make(
            forInputAt: originalInputFileURL,
            preferredParentDirectory: inputDirectoryURL,
            linkingSiblingParts: false
        )

        #expect(workingDirectory.inputFileURL.lastPathComponent == "Payload")
        #expect(workingDirectory.inputFileURL.path != originalInputFileURL.path)
        #expect(FileManager.default.contentsEqual(
            atPath: workingDirectory.inputFileURL.path,
            andPath: originalInputFileURL.path
        ))

        let originalIdentifier = try fileIdentifier(ofFileAt: originalInputFileURL)
        let linkedIdentifier = try fileIdentifier(ofFileAt: workingDirectory.inputFileURL)
        #expect(originalIdentifier == linkedIdentifier)

        workingDirectory.remove()
        #expect(!FileManager.default.fileExists(atPath: workingDirectory.directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: originalInputFileURL.path))
    }

    /// The system volume is sealed, so its files cannot gain a hard link. They
    /// are exactly the files that could not be opened at all before, since IDA
    /// cannot write its working database into a read-only directory either.
    @Test func anInputOnTheSealedSystemVolumeIsCopiedInstead() throws {
        let workingDirectory = try WorkingDatabaseDirectory.make(
            forInputAt: URL(fileURLWithPath: "/bin/ls"),
            preferredParentDirectory: nil,
            linkingSiblingParts: false
        )
        defer { workingDirectory.remove() }

        #expect(workingDirectory.inputWasCopied)
        #expect(FileManager.default.contentsEqual(
            atPath: workingDirectory.inputFileURL.path,
            andPath: "/bin/ls"
        ))
    }

    @Test func partsTravelWithTheInputButLeftoversDoNot() throws {
        let inputDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: inputDirectoryURL) }

        for fileName in ["Cache", "Cache.01", "Cache.map", "Cache.i64"] {
            try Data(fileName.utf8).write(to: inputDirectoryURL.appendingPathComponent(fileName))
        }

        let workingDirectory = try WorkingDatabaseDirectory.make(
            forInputAt: inputDirectoryURL.appendingPathComponent("Cache"),
            preferredParentDirectory: inputDirectoryURL,
            linkingSiblingParts: true
        )
        defer { workingDirectory.remove() }

        let linkedNames = try FileManager.default
            .contentsOfDirectory(atPath: workingDirectory.directoryURL.path)
            .sorted()
        #expect(linkedNames == ["Cache", "Cache.01", "Cache.map"])
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("idax-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// Inode number, which two names for one file share and two copies do not.
    private func fileIdentifier(ofFileAt url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.systemFileNumber] as? UInt64 ?? 0
    }
}
