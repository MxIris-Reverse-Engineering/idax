import ArgumentParser
import Foundation
import IDAX

public struct InputFormatLister: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "formats",
        abstract: "List the loaders IDA offers for a binary.",
        discussion: """
        Shows what IDA itself would put in its "load file" dialog, which for a
        universal ("fat") Mach-O is one entry per architecture slice. Useful
        when `binary` reports that it could not confirm the loaded
        architecture, or when a file's slices are not what you expect.

        This only inspects the file; no database is created.
        """
    )

    @Argument(help: ArgumentHelp("Path to the binary to inspect.", valueName: "path"))
    var binaryPath: String

    public init() {}

    public mutating func validate() throws {
        var pathIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: absoluteBinaryPath, isDirectory: &pathIsDirectory),
              !pathIsDirectory.boolValue
        else {
            throw ValidationError("The binary does not exist: \(absoluteBinaryPath)")
        }
    }

    public mutating func run() throws {
        let fatSlices = try MachOFatHeader.slices(inFileAt: URL(fileURLWithPath: absoluteBinaryPath))
        if let fatSlices {
            print("Universal binary with \(fatSlices.count) slices:")
            for slice in fatSlices {
                print("  \(slice.ordinal). \(slice.architecture)")
            }
        } else {
            print("Not a universal binary.")
        }

        // Listing requires an initialised runtime, but opens no database.
        try Database.initialize()
        let formats = try Database.listInputFormats(absoluteBinaryPath)
        if formats.isEmpty {
            print("IDA offers no loader for this file.")
        } else {
            print("IDA loaders:")
            for format in formats {
                print("  \(format.name)  [processor: \(format.processor)]")
            }
        }

        print("Host architecture: \(MachOArchitecture.current)")
        if let selected = try? SliceResolver.resolve(slices: fatSlices, requested: nil) {
            print("`idax binary` would select: \(selected.architecture) (slice \(selected.ordinal))")
        } else if fatSlices == nil {
            print("`idax binary` would let IDA choose.")
        }
    }

    var absoluteBinaryPath: String {
        BinaryDatabaseCreationPlan.absoluteFileURL(
            path: binaryPath,
            currentDirectoryPath: FileManager.default.currentDirectoryPath
        ).path
    }
}
