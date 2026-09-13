import CIDAXFork
import Foundation

/// A loader IDA is willing to use for a given input file.
///
/// A universal ("fat") Mach-O yields one entry per architecture slice, in the
/// order the slices appear in the file. Opening such a file without naming a
/// format selects the first entry, which for Apple's toolchain is x86_64 —
/// `lipo` orders slices by CPU type, placing x86_64 ahead of arm64.
///
/// This is a fork-only addition; upstream IDAX has no equivalent.
public struct InputFormat: Sendable, Equatable {
    /// Name IDA displays for this format, carrying its own ordinal for
    /// multi-slice inputs (for example `Fat Mach-O file, 2. ARM64e-pauth1`).
    /// Pass it back verbatim as a `-T` runtime argument to select it; no
    /// parsing or renumbering is needed or correct.
    public let name: String
    /// Processor module this format wants (for example `arm`, `metapc`).
    public let processor: String
    /// Loader module that produced this entry.
    public let loaderPath: String
    /// True when the loader treats the input as an archive of members.
    public let isArchiveLoader: Bool

    public init(name: String, processor: String, loaderPath: String, isArchiveLoader: Bool) {
        self.name = name
        self.processor = processor
        self.loaderPath = loaderPath
        self.isArchiveLoader = isArchiveLoader
    }

    /// The runtime argument that selects this format.
    ///
    /// `-T` and its value form a single argv entry. No quoting is applied:
    /// only the command-line *string* form, which IDA splits on whitespace,
    /// needs quotes to survive a name like `Fat Mach-O file, 2. ARM64`.
    public var runtimeArgument: String { "-T\(name)" }
}

/// Failure listing the loaders for an input file.
public struct InputFormatError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// List the formats IDA would offer for the file at `path`, in IDA's own order.
///
/// Requires an initialised library. Returns an empty array when no loader
/// recognises the input.
public func listInputFormats(forFileAt path: String) throws -> [InputFormat] {
    var nativeFormats: UnsafeMutablePointer<IdaxForkInputFormat>?
    var formatCount = 0
    var errorMessage: UnsafeMutablePointer<CChar>?

    let status = path.withCString { pathPointer in
        idax_fork_list_input_formats(pathPointer, &nativeFormats, &formatCount, &errorMessage)
    }

    guard status == 0 else {
        defer { idax_fork_string_free(errorMessage) }
        let message = errorMessage.map { String(cString: $0) } ?? "Unknown failure listing input formats"
        throw InputFormatError(message: message)
    }

    guard let nativeFormats, formatCount > 0 else { return [] }
    defer { idax_fork_input_formats_free(nativeFormats, formatCount) }

    return UnsafeBufferPointer(start: nativeFormats, count: formatCount).map { nativeFormat in
        InputFormat(
            name: nativeFormat.name.map { String(cString: $0) } ?? "",
            processor: nativeFormat.processor.map { String(cString: $0) } ?? "",
            loaderPath: nativeFormat.loader_path.map { String(cString: $0) } ?? "",
            isArchiveLoader: nativeFormat.archive_loader != 0
        )
    }
}
