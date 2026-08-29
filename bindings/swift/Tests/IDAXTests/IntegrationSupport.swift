import Foundation
import Testing
@testable import IDAX

/// Locates the prerequisites for tests that need a live IDA runtime.
///
/// Tests gated on ``isAvailable`` are *skipped*, visibly, when the runtime or
/// the fixture is missing. They must never silently return and report success:
/// a green suite that verified nothing is worse than a red one, because it
/// takes the place of the signal instead of merely lacking it.
nonisolated enum IntegrationEnvironment {

    /// Repository root, derived from this file's location rather than from the
    /// working directory, which `swift test` does not guarantee.
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // IDAXTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // swift
        .deletingLastPathComponent()   // bindings
        .deletingLastPathComponent()   // <repo root>

    /// The fixture as checked into the repository.
    static let sourceFixturePath: String = repositoryRoot
        .appendingPathComponent("tests/fixtures/simple_appcall_linux64")
        .path

    /// A private copy of the fixture, which is what the tests actually open.
    ///
    /// Working on a copy is not tidiness, it is correctness. The fixture's
    /// unpacked form — `.id0`, `.id1`, `.id2`, `.nam`, `.til` — is tracked in
    /// git, and IDA writes netnode changes straight through to `.id0`. A single
    /// `Bookmark.set` against the checked-in fixture therefore shows up as a
    /// modified file, which is how this was found. Neither `close(save: false)`
    /// nor confining tests to reads is enough, because the write has already
    /// landed by the time either would help.
    ///
    /// Deliberately the executable and not the `.i64` beside it: IDA associates
    /// the two itself, and opening the binary is what the C++ suites do.
    static let fixtureBinaryPath: String = {
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("idax-swift-tests", isDirectory: true)
        let source = URL(fileURLWithPath: sourceFixturePath)
        let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)

        try? FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true
        )
        // The database is the executable plus its sidecars; copy the whole set.
        for suffix in ["", ".i64", ".id0", ".id1", ".id2", ".nam", ".til"] {
            let sourceFile = URL(fileURLWithPath: sourceFixturePath + suffix)
            let destinationFile = URL(fileURLWithPath: destination.path + suffix)
            guard FileManager.default.fileExists(atPath: sourceFile.path) else { continue }
            try? FileManager.default.removeItem(at: destinationFile)
            try? FileManager.default.copyItem(at: sourceFile, to: destinationFile)
        }
        return destination.path
    }()

    static var fixtureExists: Bool {
        FileManager.default.fileExists(atPath: sourceFixturePath)
    }

    static var isAvailable: Bool {
        IDARuntime.isAvailable && fixtureExists
    }

    /// Why the integration tests are not running, for the skip message.
    static var unavailableReason: String {
        switch (IDARuntime.isAvailable, fixtureExists) {
        case (false, false): "no IDA runtime and no fixture at \(fixtureBinaryPath)"
        case (false, true):  "no IDA runtime (set IDADIR or install IDA Pro)"
        case (true, false):  "no fixture at \(fixtureBinaryPath)"
        case (true, true):   "available"
        }
    }
}

/// Opens the fixture database once for the whole test process.
///
/// idalib initialises per process and wants every call on the thread that
/// initialised it, so this is a single shared database rather than one per
/// suite. Suites that use it must be `.serialized`.
///
/// Nothing here closes the database. The C++ suites close with `save: false`
/// for the same reason this does not save at all: the fixture is checked in,
/// including its unpacked form, and writing it back would show up as a dirty
/// working tree on every test run. Tests must therefore leave no persistent
/// change behind — undo whatever they write.
@MainActor
enum IntegrationDatabase {
    private static var isOpen = false

    /// Opens the fixture if it is not already open. Idempotent.
    static func ensureOpen() throws(IDAError) {
        guard !isOpen else { return }
        try Database.initialize()
        try Database.open(IntegrationEnvironment.fixtureBinaryPath, autoAnalysis: true)
        isOpen = true
    }
}
