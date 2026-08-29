internal import CIDAX

/// Source languages a registered third-party parser can handle.
///
/// An option set: a parser is selected by naming every language it must cover.
public struct ParserLanguage: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let c = ParserLanguage(rawValue: 0x01)
    public static let cpp = ParserLanguage(rawValue: 0x02)
    public static let objectiveC = ParserLanguage(rawValue: 0x04)
    public static let swift = ParserLanguage(rawValue: 0x08)
    public static let go = ParserLanguage(rawValue: 0x10)
    public static let objectiveCpp = ParserLanguage(rawValue: 0x20)
}

/// How a parser should read its input.
public enum ParserInputKind: Int32, Sendable {
    /// The input is the source text itself.
    case sourceText = 0
    /// The input is a path to a file to read.
    case filePath = 1
}

/// Everything that can be varied about one parse.
///
/// Each flag is one of the SDK's parse bits, named rather than packed into a
/// mask. Defaults match a plain declaration parse.
public struct ParserParseOptions: Sendable {
    public var inputKind: ParserInputKind
    public var discardResult: Bool
    public var defineBaseMacros: Bool
    public var suppressWarnings: Bool
    public var ignoreErrors: Bool
    public var allowRedeclarations: Bool
    public var noDecorate: Bool
    public var assumeHighLevel: Bool
    public var lowerPrototypes: Bool
    public var rawArgumentNames: Bool
    public var relaxedNamespaces: Bool
    public var excludeBaseTypes: Bool
    public var allowMissingSemicolon: Bool
    public var standaloneDeclaration: Bool
    public var allowVoid: Bool
    public var noMangle: Bool
    /// Structure packing alignment; 0 leaves the parser's default in place.
    public var packAlignment: Int

    public init(
        inputKind: ParserInputKind = .sourceText,
        discardResult: Bool = false,
        defineBaseMacros: Bool = false,
        suppressWarnings: Bool = false,
        ignoreErrors: Bool = false,
        allowRedeclarations: Bool = false,
        noDecorate: Bool = false,
        assumeHighLevel: Bool = false,
        lowerPrototypes: Bool = false,
        rawArgumentNames: Bool = false,
        relaxedNamespaces: Bool = false,
        excludeBaseTypes: Bool = false,
        allowMissingSemicolon: Bool = false,
        standaloneDeclaration: Bool = false,
        allowVoid: Bool = false,
        noMangle: Bool = false,
        packAlignment: Int = 0
    ) {
        self.inputKind = inputKind
        self.discardResult = discardResult
        self.defineBaseMacros = defineBaseMacros
        self.suppressWarnings = suppressWarnings
        self.ignoreErrors = ignoreErrors
        self.allowRedeclarations = allowRedeclarations
        self.noDecorate = noDecorate
        self.assumeHighLevel = assumeHighLevel
        self.lowerPrototypes = lowerPrototypes
        self.rawArgumentNames = rawArgumentNames
        self.relaxedNamespaces = relaxedNamespaces
        self.excludeBaseTypes = excludeBaseTypes
        self.allowMissingSemicolon = allowMissingSemicolon
        self.standaloneDeclaration = standaloneDeclaration
        self.allowVoid = allowVoid
        self.noMangle = noMangle
        self.packAlignment = packAlignment
    }

    func withRaw<CallResult>(
        _ body: (UnsafePointer<IdaxParserParseOptions>) -> CallResult
    ) -> CallResult {
        var raw = IdaxParserParseOptions()
        raw.input_kind = inputKind.rawValue
        raw.discard_result = discardResult ? 1 : 0
        raw.define_base_macros = defineBaseMacros ? 1 : 0
        raw.suppress_warnings = suppressWarnings ? 1 : 0
        raw.ignore_errors = ignoreErrors ? 1 : 0
        raw.allow_redeclarations = allowRedeclarations ? 1 : 0
        raw.no_decorate = noDecorate ? 1 : 0
        raw.assume_high_level = assumeHighLevel ? 1 : 0
        raw.lower_prototypes = lowerPrototypes ? 1 : 0
        raw.raw_argument_names = rawArgumentNames ? 1 : 0
        raw.relaxed_namespaces = relaxedNamespaces ? 1 : 0
        raw.exclude_base_types = excludeBaseTypes ? 1 : 0
        raw.allow_missing_semicolon = allowMissingSemicolon ? 1 : 0
        raw.standalone_declaration = standaloneDeclaration ? 1 : 0
        raw.allow_void = allowVoid ? 1 : 0
        raw.no_mangle = noMangle ? 1 : 0
        raw.pack_alignment = packAlignment
        return withUnsafePointer(to: &raw) { body($0) }
    }
}

/// What a parse produced.
///
/// A parse that reports errors still succeeds as a call — the errors are in the
/// report, not thrown — so check ``errorCount`` rather than relying on `try`.
public struct ParserParseReport: Sendable {
    public let errorCount: Int

    public var parsedCleanly: Bool { errorCount == 0 }

    init(raw: IdaxParserParseReport) {
        self.errorCount = raw.error_count
    }
}

/// Selection and driving of IDA's registered third-party source parsers.
public enum Parser {

    /// Selects the parser called `name` as the active one.
    public static func select(_ name: String) throws(IDAError) {
        try checkStatus(idax_parser_select(name), "parser.select")
    }

    /// Selects whichever parser covers `languages`.
    public static func select(for languages: ParserLanguage) throws(IDAError) {
        try checkStatus(idax_parser_select_for(languages.rawValue), "parser.selectFor")
    }

    /// The name of the currently selected parser.
    public static func selectedName() throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_parser_selected_name(&out), "parser.selectedName")
        return takeCString(out)
    }

    /// Sets the command-line arguments a parser is invoked with.
    public static func setArguments(
        _ arguments: String,
        for parserName: String
    ) throws(IDAError) {
        try checkStatus(
            idax_parser_set_arguments(parserName, arguments),
            "parser.setArguments"
        )
    }

    // MARK: - Parsing

    /// Parses `input` with whichever parser covers `languages`.
    @discardableResult
    public static func parse(
        _ input: String,
        for languages: ParserLanguage,
        inputKind: ParserInputKind = .sourceText
    ) throws(IDAError) -> ParserParseReport {
        var raw = IdaxParserParseReport()
        try checkStatus(
            idax_parser_parse_for(languages.rawValue, input, inputKind.rawValue, &raw),
            "parser.parseFor"
        )
        return ParserParseReport(raw: raw)
    }

    /// Parses `input` with a named parser.
    @discardableResult
    public static func parse(
        _ input: String,
        with parserName: String,
        inputKind: ParserInputKind = .sourceText
    ) throws(IDAError) -> ParserParseReport {
        var raw = IdaxParserParseReport()
        try checkStatus(
            idax_parser_parse_with(parserName, input, inputKind.rawValue, &raw),
            "parser.parseWith"
        )
        return ParserParseReport(raw: raw)
    }

    /// Parses `input` with a named parser and explicit options.
    @discardableResult
    public static func parse(
        _ input: String,
        with parserName: String,
        options: ParserParseOptions
    ) throws(IDAError) -> ParserParseReport {
        var raw = IdaxParserParseReport()
        try checkStatus(
            options.withRaw { idax_parser_parse_with_options(parserName, input, $0, &raw) },
            "parser.parseWithOptions"
        )
        return ParserParseReport(raw: raw)
    }

    // MARK: - Parser-specific options

    /// Reads one of a parser's own named options.
    public static func option(
        _ optionName: String,
        of parserName: String
    ) throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(
            idax_parser_option(parserName, optionName, &out),
            "parser.option"
        )
        return takeCString(out)
    }

    /// Writes one of a parser's own named options.
    public static func setOption(
        _ optionName: String,
        to value: String,
        of parserName: String
    ) throws(IDAError) {
        try checkStatus(
            idax_parser_set_option(parserName, optionName, value),
            "parser.setOption"
        )
    }
}
