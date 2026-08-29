import Foundation
import Testing
@testable import IDAX

// MARK: - Registry

/// Registry tests write to IDA's *global* configuration, not to the database,
/// so unlike everything else here the fixture copy does not isolate them. Every
/// test therefore works under one clearly-marked key and erases the whole tree
/// afterwards.
@Suite(
    "IDA Registry",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct RegistryTests {

    private static let testKey = "idax_swift_test_scratch"

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    private func scratchStore() throws -> RegistryStore {
        try RegistryStore.open(Self.testKey)
    }

    @Test func roundTripsEachValueKind() throws {
        let store = try scratchStore()
        defer { _ = try? store.eraseTree() }

        try store.writeString("hello", to: "stringValue")
        try store.writeInteger(-42, to: "integerValue")
        try store.writeBoolean(true, to: "booleanValue")
        try store.writeBinary([0x00, 0xFF, 0x10], to: "binaryValue")

        #expect(try store.readString("stringValue") == "hello")
        #expect(try store.readInteger("integerValue") == -42)
        #expect(try store.readBoolean("booleanValue") == true)
        #expect(try store.readBinary("binaryValue") == [0x00, 0xFF, 0x10])
    }

    @Test func absentValuesReadAsNilRatherThanThrowing() throws {
        let store = try scratchStore()
        defer { _ = try? store.eraseTree() }

        #expect(try store.readString("neverWritten") == nil)
        #expect(try store.readInteger("neverWritten") == nil)
        #expect(try store.readBoolean("neverWritten") == nil)
        #expect(try store.readBinary("neverWritten") == nil)
        #expect(try store.valueKind(of: "neverWritten") == nil)
    }

    @Test func reportsTheStorageKindOfEachValue() throws {
        let store = try scratchStore()
        defer { _ = try? store.eraseTree() }

        try store.writeString("text", to: "stringValue")
        try store.writeInteger(7, to: "integerValue")
        // Booleans share integer storage — there is no separate kind.
        try store.writeBoolean(false, to: "booleanValue")

        #expect(try store.valueKind(of: "stringValue") == .string)
        #expect(try store.valueKind(of: "integerValue") == .integer)
        #expect(try store.valueKind(of: "booleanValue") == .integer)
    }

    @Test func listsValueNamesAndErasesThem() throws {
        let store = try scratchStore()
        defer { _ = try? store.eraseTree() }

        try store.writeString("a", to: "first")
        try store.writeString("b", to: "second")

        let names = try store.valueNames()
        #expect(names.contains("first"))
        #expect(names.contains("second"))

        #expect(try store.contains("first"))
        #expect(try store.eraseValue("first"))
        #expect(try store.contains("first") == false)
    }

    @Test func anEmptyBinaryValueRoundTripsAsEmptyNotAbsent() throws {
        let store = try scratchStore()
        defer { _ = try? store.eraseTree() }

        try store.writeBinary([], to: "emptyBinary")
        // The distinction that matters: written-but-empty is [] , never nil.
        #expect(try store.readBinary("emptyBinary") == [])
    }

    @Test func derivesChildStores() throws {
        let store = try scratchStore()
        defer { _ = try? store.eraseTree() }

        let child = try store.child("nested")
        #expect(child.key.contains("nested"))
        try child.writeString("inner", to: "value")
        #expect(try child.readString("value") == "inner")
    }
}

// MARK: - Directory

@Suite(
    "IDA Directory",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct DirectoryTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    @Test func opensEveryCollectionKind() throws {
        // Each kind must at least open and report whether it can be ordered;
        // a kind IDA does not recognise would throw here.
        for kind in [
            DirectoryKind.localTypes, .functions, .names, .imports,
            .idaPlaceBookmarks, .breakpoints, .localTypeBookmarks, .snippets,
        ] {
            let tree = try DirectoryTree.open(kind)
            _ = try tree.isOrderable()
        }
    }

    @Test func readsTheRootOfTheFunctionTree() throws {
        let tree = try DirectoryTree.open(.functions)
        let root = try tree.currentDirectory()
        #expect(!root.isEmpty)
        #expect(try tree.contains(root))

        // The fixture has functions, so the root has children.
        let children = try tree.children(of: root)
        #expect(!children.isEmpty)
        for child in children {
            #expect(!child.path.isEmpty)
            #expect(!child.name.isEmpty)
        }
    }

    @Test func createsAndRemovesADirectory() throws {
        let tree = try DirectoryTree.open(.functions)
        let root = try tree.currentDirectory()
        let path = root.hasSuffix("/") ? root + "idax_test_dir" : root + "/idax_test_dir"
        defer { try? tree.removeDirectory(at: path) }

        try tree.createDirectory(at: path)
        #expect(try tree.contains(path))

        let entry = try tree.entry(at: path)
        #expect(entry.kind == .directory)
        #expect(entry.name == "idax_test_dir")

        try tree.removeDirectory(at: path)
        #expect(try tree.contains(path) == false)
    }

    @Test func snapshotIsAtLeastAsLargeAsTheDirectChildren() throws {
        let tree = try DirectoryTree.open(.functions)
        let root = try tree.currentDirectory()
        let children = try tree.children(of: root)
        let snapshot = try tree.snapshot(of: root)
        #expect(snapshot.count >= children.count)
    }

    @Test func removingAMissingPathIsReportedNotThrown() throws {
        let tree = try DirectoryTree.open(.functions)
        // Bulk operations are partial by design: the failure belongs in the
        // report, not in a thrown error.
        let report = try tree.remove(["/idax_definitely_absent_path"])
        #expect(report.succeededEntirely == false)
        #expect(report.failures.first?.inputIndex == 0)
    }
}

// MARK: - RegisterTracking

/// What these can and cannot verify.
///
/// Register-value tracking is processor-specific, and the shared fixture is
/// x86-64, where IDA reports `Unsupported`. The repository does carry an
/// `aarch64` fixture for this — the C++ `register_tracking_roundtrip` suite uses
/// it — but that works because every CTest target is its own process and can
/// open its own database. All Swift tests share one process, and idalib holds
/// one database at a time, so the aarch64 fixture is out of reach here.
///
/// These tests therefore pin the *unsupported* path: every entry point must
/// report `Unsupported` cleanly rather than crashing, returning a fabricated
/// value, or reporting success with empty results. Verifying tracking against a
/// processor that supports it needs a separate test executable and is recorded
/// as outstanding work, not covered here.
@Suite(
    "IDA RegisterTracking",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct RegisterTrackingTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    private func addressInsideAFunction() throws -> Address? {
        guard let function = try Function.all().first(where: { $0.end > $0.start + 4 }) else {
            return nil
        }
        return function.start + 4
    }

    /// Runs `body` and requires that it either succeeds or fails as
    /// `Unsupported` — never any other error, and never a trap.
    private func expectSupportedOrUnsupported(
        _ label: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
        } catch let error as IDAError {
            #expect(
                error.category == .unsupported,
                "\(label) failed with \(error.category), expected success or Unsupported"
            )
        } catch {
            Issue.record("\(label) threw a non-IDAError: \(error)")
        }
    }

    @Test func trackReportsUnsupportedRatherThanFailingOpaquely() throws {
        let address = try #require(try addressInsideAFunction())
        expectSupportedOrUnsupported("track") {
            let tracked = try RegisterTracking.track("rax", at: address, maximumDepth: 8)
            #expect(!tracked.description.isEmpty)
        }
    }

    @Test func constantQueryIsWellBehavedOnAnUnsupportedProcessor() throws {
        let address = try #require(try addressInsideAFunction())
        expectSupportedOrUnsupported("constant") {
            _ = try RegisterTracking.constant(of: "rax", at: address, maximumDepth: 4)
        }
    }

    @Test func stackPointerDeltaIsWellBehavedOnAnUnsupportedProcessor() throws {
        let address = try #require(try addressInsideAFunction())
        expectSupportedOrUnsupported("stackPointerDelta") {
            _ = try RegisterTracking.stackPointerDelta(of: "rsp", at: address)
        }
    }

    @Test func nearestIsWellBehavedOnAnUnsupportedProcessor() throws {
        let address = try #require(try addressInsideAFunction())
        expectSupportedOrUnsupported("nearest") {
            if let nearest = try RegisterTracking.nearest("rax", or: "rbx", at: address) {
                #expect(nearest.selectedIndex <= 1)
                #expect(!nearest.registerName.isEmpty)
            }
        }
    }

    /// Cache maintenance is processor-independent, so these must actually work.
    @Test func cachesCanBeClearedAndInvalidated() throws {
        try RegisterTracking.clearControlFlowCache()
        try RegisterTracking.clearDataReferenceCache()
        let address = try #require(try addressInsideAFunction())
        try RegisterTracking.controlFlowReferenceChanged(
            from: address, to: address, mutation: .added
        )
        try RegisterTracking.dataReferenceChanged(to: address, mutation: .removed)
    }
}
