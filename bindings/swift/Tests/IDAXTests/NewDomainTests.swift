import Foundation
import Testing
@testable import IDAX

// MARK: - FilePath (no runtime required)

@Suite("IDA FilePath")
struct FilePathTests {

    @Test func basenameTakesTheFinalComponent() throws {
        #expect(try FilePath.basename("/tmp/example/file.i64") == "file.i64")
    }

    @Test func dirnameDropsTheFinalComponent() throws {
        #expect(try FilePath.dirname("/tmp/example/file.i64") == "/tmp/example")
    }

    @Test func isDirectoryDistinguishesDirectoriesFromFiles() throws {
        let root = IntegrationEnvironment.repositoryRoot.path
        #expect(try FilePath.isDirectory(root))
        try #require(IntegrationEnvironment.fixtureExists)
        #expect(try FilePath.isDirectory(IntegrationEnvironment.fixtureBinaryPath) == false)
    }

    @Test func isDirectoryIsFalseForSomethingThatDoesNotExist() throws {
        #expect(try FilePath.isDirectory("/nonexistent-\(UUID().uuidString)") == false)
    }
}

// MARK: - Domains that need a live database

@Suite(
    "IDA Problem",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct ProblemTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    @Test func everyKindHasAShortAndALongName() throws {
        // A category IDA does not name would come back empty, which is the
        // failure this catches — the enum is ours, the names are IDA's.
        for kind in [ProblemKind.disassemblyFailure, .missingName, .attention] {
            let shortName = try Problem.name(of: kind)
            let longName = try Problem.name(of: kind, longForm: true)
            #expect(!shortName.isEmpty, "no short name for \(kind)")
            #expect(!longName.isEmpty, "no long name for \(kind)")
        }
    }

    @Test func queryingAnAddressWithNoProblemIsFalseRatherThanAnError() throws {
        #expect(try Problem.contains(.disassemblyFailure, at: 0) == false)
    }

    @Test func remembersAndRemovesAProblem() throws {
        let address = try #require(try firstFunctionStart())
        // Leave nothing behind: the fixture is checked in.
        defer { _ = try? Problem.remove(.attention, at: address) }

        try Problem.remember(.attention, at: address, message: "idax test marker")
        #expect(try Problem.contains(.attention, at: address))
        #expect(try Problem.remove(.attention, at: address))
        #expect(try Problem.contains(.attention, at: address) == false)
    }
}

@Suite(
    "IDA Bookmark",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct BookmarkTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    @Test func listingBookmarksSucceedsOnAFixtureThatHasNone() throws {
        // The assertion is that the call works and the result is well-formed,
        // not that the fixture happens to be empty.
        for bookmark in try Bookmark.all() {
            #expect(bookmark.slot < Bookmark.slotCount)
        }
    }

    @Test func setsReadsBackAndRemovesABookmark() throws {
        let address = try #require(try firstFunctionStart())
        defer { _ = try? Bookmark.remove(at: address) }

        let stored = try Bookmark.set(at: address, text: "idax test bookmark")
        #expect(stored.address == address)
        #expect(stored.text == "idax test bookmark")
        #expect(stored.slot < Bookmark.slotCount)

        let readBack = try #require(try Bookmark.at(address))
        #expect(readBack.address == address)
        #expect(readBack.text == "idax test bookmark")

        let bySlot = try #require(try Bookmark.at(slot: stored.slot))
        #expect(bySlot.address == address)

        #expect(try Bookmark.remove(at: address))
        #expect(try Bookmark.at(address) == nil)
    }

    @Test func readingAnEmptySlotYieldsNilRatherThanAnError() throws {
        #expect(try Bookmark.at(slot: Bookmark.slotCount - 1) == nil)
    }
}

@Suite(
    "IDA Undo",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct UndoTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    @Test func labelsAreReadableWhetherOrNotThereIsAnythingToUndo() throws {
        // Both return the empty string when the corresponding stack is empty,
        // which is a value, not an error.
        _ = try Undo.undoActionLabel()
        _ = try Undo.redoActionLabel()
    }

    @Test func createsAnUndoPointAndSeesItInTheLabel() throws {
        let accepted = try Undo.createPoint(actionName: "idax_test", label: "idax test action")
        // IDA declines when undo is disabled for the database; that is a
        // legitimate answer, so only check the label when it accepted.
        if accepted {
            #expect(try Undo.undoActionLabel() == "idax test action")
        }
    }
}

@Suite(
    "IDA Navigation",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct NavigationTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    @Test func opensAHistoryAndReportsWhetherItWasCreated() throws {
        let history = try NavigationHistory.open(
            name: "idax_test_history_open",
            initial: NavigationEntry(address: 0x1000, channel: "test")
        )
        #expect(try history.name() == "idax_test_history_open")
        _ = try history.wasCreated()
    }

    @Test func pushMovesTheCurrentPositionAndBackReturnsToIt() throws {
        let history = try NavigationHistory.open(
            name: "idax_test_history_walk",
            initial: NavigationEntry(address: 0x1000, channel: "test")
        )
        try history.clear(newTip: NavigationEntry(address: 0x1000, channel: "test"))

        try history.push(NavigationEntry(address: 0x2000, channel: "test"))
        #expect(try history.current().address == 0x2000)

        let stepped = try #require(try history.back())
        #expect(stepped.address == 0x1000)

        let returned = try #require(try history.forward())
        #expect(returned.address == 0x2000)

        #expect(try history.count() >= 2)
        #expect(try history.entries().count == history.count())
    }

    @Test func steppingPastTheEndYieldsNilRatherThanAnError() throws {
        let history = try NavigationHistory.open(
            name: "idax_test_history_bounds",
            initial: NavigationEntry(address: 0x1000, channel: "test")
        )
        try history.clear(newTip: NavigationEntry(address: 0x1000, channel: "test"))
        // Already at the only position, so there is nowhere to go.
        #expect(try history.back(1_000) == nil)
        #expect(try history.forward(1_000) == nil)
    }

    @Test func entriesRoundTripTheirChannelAndMetadata() throws {
        let history = try NavigationHistory.open(
            name: "idax_test_history_fields",
            initial: NavigationEntry(address: 0x1000, channel: "test")
        )
        try history.clear(newTip: NavigationEntry(address: 0x1000, channel: "test"))
        let pushed = try history.push(
            NavigationEntry(address: 0x3000, channel: "pseudocode", metadata: "frame=7")
        )
        #expect(pushed.address == 0x3000)
        #expect(pushed.channel == "pseudocode")
        #expect(pushed.metadata == "frame=7")
    }
}

// MARK: - Shared helper

/// An address that certainly exists in the fixture, for tests that need one.
@MainActor
private func firstFunctionStart() throws -> Address? {
    try Function.all().first?.start
}
