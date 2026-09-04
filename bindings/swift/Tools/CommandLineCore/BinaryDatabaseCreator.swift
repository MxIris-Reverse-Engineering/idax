import ArgumentParser
import Foundation
import IDAX

public struct BinaryDatabaseCreator: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "binary",
        abstract: "Create an IDA database from a single binary.",
        discussion: """
        For a universal ("fat") Mach-O the architecture matching this host is
        selected, preferring arm64 over arm64e when the file offers both.
        Override with --arch. A file that offers neither the requested nor the
        host architecture is an error rather than a silent substitution: IDA
        left to itself takes the first slice, which for Apple's toolchain is
        x86_64.
        """
    )

    @Argument(help: ArgumentHelp("Path to the binary to load.", valueName: "path"))
    var binaryPath: String

    @Option(
        name: .customLong("arch"),
        help: ArgumentHelp(
            "Architecture to load (arm64, arm64e, x86_64). Defaults to this host's.",
            valueName: "name"
        )
    )
    var requestedArchitecture: MachOArchitecture?

    @Option(
        name: .customLong("output"),
        help: ArgumentHelp(
            "Output database path. A missing extension is completed with .i64.",
            valueName: "path"
        )
    )
    var outputDatabasePath: String?

    @Flag(
        name: .customLong("skip-final-analysis"),
        help: "Save without draining the final auto-analysis queue."
    )
    var skipFinalAnalysis = false

    @Flag(
        name: .customLong("overwrite"),
        help: "Replace an existing output database."
    )
    var overwriteExistingOutput = false

    public init() {}

    public mutating func validate() throws {
        let creationPlan = try makeCreationPlan()

        var binaryPathIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: creationPlan.binaryFileURL.path,
            isDirectory: &binaryPathIsDirectory
        ), !binaryPathIsDirectory.boolValue else {
            throw ValidationError(
                "The binary does not exist: \(creationPlan.binaryFileURL.path)"
            )
        }

        var outputParentIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: creationPlan.outputFileURL.deletingLastPathComponent().path,
            isDirectory: &outputParentIsDirectory
        ), outputParentIsDirectory.boolValue else {
            throw ValidationError(
                "The output directory does not exist: "
                    + creationPlan.outputFileURL.deletingLastPathComponent().path
            )
        }

        var outputPathIsDirectory = ObjCBool(false)
        let outputPathExists = FileManager.default.fileExists(
            atPath: creationPlan.outputFileURL.path,
            isDirectory: &outputPathIsDirectory
        )
        if outputPathExists, outputPathIsDirectory.boolValue {
            throw ValidationError(
                "The output database path is a directory: \(creationPlan.outputFileURL.path)"
            )
        }

        if outputPathExists, !overwriteExistingOutput {
            throw ValidationError(
                "The output database already exists. Pass --overwrite to replace it: "
                    + creationPlan.outputFileURL.path
            )
        }
    }

    public mutating func run() throws {
        let creationPlan = try makeCreationPlan()

        // The slice has to be chosen before IDA starts: IDA only accepts an
        // input format on the initialisation call, and its own loader list
        // cannot be built before that call. The choice is verified against IDA
        // once the database is open.
        let fatSlices = try MachOFatHeader.slices(inFileAt: creationPlan.binaryFileURL)
        let selectedSlice = try SliceResolver.resolve(
            slices: fatSlices,
            requested: requestedArchitecture
        )

        var runtimeOptions = RuntimeOptions()
        if let selectedSlice {
            runtimeOptions.inputFormat = SliceResolver.inputFormatName(for: selectedSlice)
            print("Selecting \(selectedSlice.architecture) (slice \(selectedSlice.ordinal) of \(fatSlices?.count ?? 1))")
        } else {
            print("Loading with IDA's detected format")
        }

        print("Initializing IDA runtime")
        try Database.initialize(options: runtimeOptions)

        var databaseIsOpen = false
        defer {
            if databaseIsOpen {
                try? Database.close(save: false)
            }
        }

        try Database.open(
            creationPlan.binaryFileURL.path,
            options: OpenOptions(mode: .skipAnalysis)
        )
        databaseIsOpen = true

        let loadedFormatName = try Database.fileTypeName()
        print("Loaded as: \(loadedFormatName)")
        if let selectedSlice {
            try verifyLoadedArchitecture(
                loadedFormatName: loadedFormatName,
                expected: selectedSlice.architecture
            )
        }

        if !skipFinalAnalysis {
            print("Waiting for final auto-analysis")
            try Analysis.wait()
        }

        if overwriteExistingOutput,
           FileManager.default.fileExists(atPath: creationPlan.outputFileURL.path) {
            try FileManager.default.removeItem(at: creationPlan.outputFileURL)
        }

        print("Saving database: \(creationPlan.outputFileURL.path)")
        try Database.save(to: creationPlan.outputFileURL.path)
        try Database.close(save: false)
        databaseIsOpen = false
        print("Created database: \(creationPlan.outputFileURL.path)")
    }

    /// Confirm IDA loaded the slice that was asked for.
    ///
    /// The ordinal handed to IDA is derived from the fat header, on the
    /// assumption that IDA numbers its candidate loaders in file order. That
    /// holds for every binary measured, but a slice IDA declines to load would
    /// shift the numbering — so the result is checked rather than assumed, and
    /// a mismatch fails loudly instead of producing a database for the wrong
    /// architecture.
    func verifyLoadedArchitecture(
        loadedFormatName: String,
        expected: MachOArchitecture
    ) throws {
        guard let loadedArchitecture = MachOArchitecture(formatName: loadedFormatName) else {
            throw ValidationError(
                "Could not confirm the loaded architecture: IDA reports the format as "
                    + "\(loadedFormatName), which names no architecture."
            )
        }
        guard loadedArchitecture == expected else {
            throw ValidationError(
                "IDA loaded \(loadedArchitecture) but \(expected) was selected "
                    + "(format: \(loadedFormatName)). The database was not saved."
            )
        }
    }

    func makeCreationPlan() throws -> BinaryDatabaseCreationPlan {
        try BinaryDatabaseCreationPlan(
            binaryPath: binaryPath,
            outputDatabasePath: outputDatabasePath,
            currentDirectoryPath: FileManager.default.currentDirectoryPath
        )
    }
}

struct BinaryDatabaseCreationPlan {
    let binaryFileURL: URL
    let outputFileURL: URL

    init(
        binaryPath: String,
        outputDatabasePath: String?,
        currentDirectoryPath: String
    ) throws {
        guard !binaryPath.isEmpty else {
            throw ValidationError("The binary path cannot be empty.")
        }
        let binaryFileURL = Self.absoluteFileURL(
            path: binaryPath,
            currentDirectoryPath: currentDirectoryPath
        )
        let outputFileURL = try Self.outputFileURL(
            binaryFileURL: binaryFileURL,
            outputDatabasePath: outputDatabasePath,
            currentDirectoryPath: currentDirectoryPath
        )
        guard binaryFileURL != outputFileURL else {
            throw ValidationError("The output database path must differ from the binary path.")
        }
        self.binaryFileURL = binaryFileURL
        self.outputFileURL = outputFileURL
    }

    static func outputFileURL(
        binaryFileURL: URL,
        outputDatabasePath: String?,
        currentDirectoryPath: String
    ) throws -> URL {
        if let outputDatabasePath {
            guard !outputDatabasePath.isEmpty else {
                throw ValidationError("The output database path cannot be empty.")
            }
            var explicitOutputFileURL = absoluteFileURL(
                path: outputDatabasePath,
                currentDirectoryPath: currentDirectoryPath
            )
            if explicitOutputFileURL.pathExtension.isEmpty {
                explicitOutputFileURL.appendPathExtension("i64")
            }
            return explicitOutputFileURL
        }

        let outputName = binaryFileURL.deletingPathExtension().lastPathComponent
        guard !outputName.isEmpty else {
            throw ValidationError("Unable to derive an output name from the binary path.")
        }
        return absoluteFileURL(
            path: outputName + ".i64",
            currentDirectoryPath: currentDirectoryPath
        )
    }

    static func absoluteFileURL(path: String, currentDirectoryPath: String) -> URL {
        let fileURL: URL
        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(path)
        }
        return fileURL.standardizedFileURL
    }
}
