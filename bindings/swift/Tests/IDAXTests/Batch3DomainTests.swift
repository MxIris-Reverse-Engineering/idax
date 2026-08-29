import Foundation
import Testing
@testable import IDAX

// MARK: - Offset

@Suite(
    "IDA Offset",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct OffsetTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    private func addressInsideAFunction() throws -> Address? {
        guard let function = try Function.all().first(where: { $0.end > $0.start + 4 }) else {
            return nil
        }
        return function.start
    }

    @Test func listsTheProcessorsReferenceFormats() throws {
        let types = try Offset.referenceTypes()
        // Every processor offers the standard widths, so an empty list would
        // mean the enumeration failed rather than that none exist.
        #expect(!types.isEmpty)
        for descriptor in types {
            #expect(!descriptor.name.isEmpty)
        }
        // The standard kinds carry no custom name; only `.custom` does.
        for descriptor in types where descriptor.type.kind != .custom {
            #expect(descriptor.type.customName.isEmpty)
        }
    }

    @Test func reportsADefaultReferenceFormatForAnAddress() throws {
        let address = try #require(try addressInsideAFunction())
        let type = try Offset.defaultReferenceType(at: address)
        if type.kind == .custom {
            #expect(!type.customName.isEmpty)
        } else {
            #expect(type.customName.isEmpty)
        }
    }

    @Test func anOperandWithoutAReferenceReadsAsNil() throws {
        let address = try #require(try addressInsideAFunction())
        // The fixture is plain C with no offset annotations applied, so the
        // absence must come back as nil rather than as a zeroed struct.
        #expect(try Offset.referenceInfo(at: address, operandIndex: 0) == nil)
    }

    @Test func baseValueCalculationIsPureArithmetic() throws {
        // Independent of the database: target minus base, when representable.
        let value = try Offset.calculateBaseValue(target: 0x2000, base: 0x1000)
        #expect(value != nil)
    }

    @Test func calculatesAReferenceWithoutApplyingIt() throws {
        // Must be a mapped address: resolving consults the segment layout, and
        // an unmapped base is rejected with NotFound rather than computed.
        let address = try #require(try addressInsideAFunction())
        let info = OffsetReferenceInfo(kind: .offset32, base: address)
        _ = try Offset.calculateReference(info, from: address, operandValue: 0x40)
        // Resolving must not have written anything to the database.
        #expect(try Offset.referenceInfo(at: address, operandIndex: 0) == nil)
    }

    @Test func removingAnAbsentReferenceReportsFalse() throws {
        let address = try #require(try addressInsideAFunction())
        #expect(try Offset.removeReference(at: address, operandIndex: 0) == false)
    }
}

// MARK: - Parser

/// What these can and cannot verify.
///
/// Third-party source parsers are registered plugins; a stock IDA installation
/// may have none, in which case selection and parsing report `NotFound` or
/// `Unsupported`. These tests pin that the entry points behave — a clean typed
/// error or a real answer, never a trap or a fabricated success. Verifying an
/// actual parse needs an installation with a parser configured, which is not
/// something the suite can assume.
@Suite(
    "IDA Parser",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct ParserTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    private func expectCleanOutcome(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch let error as IDAError {
            #expect(
                [.notFound, .unsupported, .validation].contains(error.category),
                "\(label) failed with \(error.category), which is not an expected absence"
            )
        } catch {
            Issue.record("\(label) threw a non-IDAError: \(error)")
        }
    }

    @Test func readingTheSelectedParserIsWellBehaved() throws {
        expectCleanOutcome("selectedName") {
            _ = try Parser.selectedName()
        }
    }

    @Test func selectingByLanguageIsWellBehaved() throws {
        expectCleanOutcome("select(for:)") {
            try Parser.select(for: [.c, .cpp])
        }
    }

    @Test func selectingAParserThatCannotExistFailsCleanly() throws {
        do {
            try Parser.select("idax_no_such_parser")
            Issue.record("selecting a nonexistent parser should not succeed")
        } catch {
            // `Parser.select` uses typed throws, so `error` is already an
            // IDAError. Writing `catch let error as IDAError` here makes the
            // cast statically redundant and crashes swift-frontend 6.3.3 in
            // SILGenCleanup with "Found outside of lifetime use?!".
            #expect([.notFound, .validation, .unsupported].contains(error.category))
        }
    }

    @Test func languageSetCombinesAsAnOptionSet() {
        // Pure value semantics, no runtime involved.
        let combined: ParserLanguage = [.c, .cpp, .swift]
        #expect(combined.contains(.swift))
        #expect(combined.rawValue == 0x01 | 0x02 | 0x08)
        #expect(!ParserLanguage.go.contains(.c))
    }

    @Test func parseOptionsDefaultToAPlainDeclarationParse() {
        let options = ParserParseOptions()
        #expect(options.inputKind == .sourceText)
        #expect(options.discardResult == false)
        #expect(options.packAlignment == 0)
    }
}

// MARK: - ExceptionRegion

@Suite(
    "IDA ExceptionRegion",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct ExceptionRegionTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    private func functionRange() throws -> (start: Address, end: Address)? {
        guard let function = try Function.all().first(where: { $0.end > $0.start + 16 }) else {
            return nil
        }
        return (function.start, function.end)
    }

    @Test func listingAFixtureWithNoExceptionsYieldsAnEmptyResult() throws {
        let range = try #require(try functionRange())
        // Plain C with no exception tables: the call must succeed and return
        // nothing, not fail.
        #expect(try ExceptionRegion.list(start: range.start, end: range.end).isEmpty)
    }

    @Test func containsIsFalseWhereThereAreNoRegions() throws {
        let range = try #require(try functionRange())
        #expect(try ExceptionRegion.contains(range.start) == false)
        #expect(try ExceptionRegion.contains(range.start, locations: .cppTry) == false)
    }

    @Test func addsReadsBackAndRemovesACppBlock() throws {
        let range = try #require(try functionRange())
        let protectedRegion = ExceptionRange(start: range.start, end: range.start + 8)
        let handlerRegion = ExceptionRange(start: range.start + 8, end: range.start + 12)
        defer { try? ExceptionRegion.remove(start: range.start, end: range.end) }

        try ExceptionRegion.add(
            ExceptionBlockDefinition(
                protectedRegions: [protectedRegion],
                handlers: .cppCatches([
                    ExceptionCatchHandler(
                        metadata: ExceptionHandlerMetadata(regions: [handlerRegion]),
                        selectorKind: .catchAll
                    )
                ])
            )
        )

        let blocks = try ExceptionRegion.list(start: range.start, end: range.end)
        let block = try #require(blocks.first)
        #expect(block.definition.protectedRegions.contains(protectedRegion))
        guard case .cppCatches(let catches) = block.definition.handlers else {
            Issue.record("expected C++ catches, got a structured handler")
            return
        }
        #expect(catches.count == 1)
        #expect(catches.first?.selectorKind == .catchAll)

        try ExceptionRegion.remove(start: range.start, end: range.end)
        #expect(try ExceptionRegion.list(start: range.start, end: range.end).isEmpty)
    }

    @Test func addsAndReadsBackAStructuredHandler() throws {
        let range = try #require(try functionRange())
        defer { try? ExceptionRegion.remove(start: range.start, end: range.end) }

        try ExceptionRegion.add(
            ExceptionBlockDefinition(
                protectedRegions: [
                    ExceptionRange(start: range.start, end: range.start + 8)
                ],
                handlers: .structuredHandler(
                    ExceptionSehHandler(
                        metadata: ExceptionHandlerMetadata(
                            regions: [
                                ExceptionRange(start: range.start + 8, end: range.start + 12)
                            ],
                            stackDisplacement: 16
                        ),
                        // A filter and a fixed disposition are mutually
                        // exclusive; supplying both is a Validation error.
                        filterRegions: [
                            ExceptionRange(start: range.start + 12, end: range.start + 16)
                        ]
                    )
                )
            )
        )

        let blocks = try ExceptionRegion.list(start: range.start, end: range.end)
        let block = try #require(blocks.first)
        guard case .structuredHandler(let handler) = block.definition.handlers else {
            Issue.record("expected a structured handler, got C++ catches")
            return
        }
        #expect(handler.metadata.stackDisplacement == 16)
        #expect(handler.filterRegions.count == 1)
        #expect(handler.disposition == nil)
    }

    @Test func locationSetCombinesAsAnOptionSet() {
        #expect(ExceptionLocation.any.contains(.cppTry))
        #expect(ExceptionLocation.any.contains(.sehFilter))
        // `any` deliberately excludes unwind fallthrough.
        #expect(!ExceptionLocation.any.contains(.unwindFallthrough))
    }
}
