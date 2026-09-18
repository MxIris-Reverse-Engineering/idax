import ArgumentParser
import Foundation
import IDAX

public nonisolated struct BinaryDatabaseCreator: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "binary",
        abstract: "Create IDA databases from one or more binaries.",
        discussion: """
        For a universal ("fat") Mach-O the architecture matching this host is
        selected, preferring arm64 over arm64e when the file offers both.
        Override with --arch. A file that offers neither the requested nor the
        host architecture is an error rather than a silent substitution: IDA
        left to itself takes the first slice, which for Apple's toolchain is
        x86_64.

        Several binaries can be given at once; --output-dir then receives one
        database per input, named after it. Each runs in its own process,
        because the architecture selection is fixed when IDA initialises and
        one process therefore cannot serve two different slices. --jobs runs
        more than one of those processes at a time.
        """
    )

    @Argument(help: ArgumentHelp("Paths to the binaries to load.", valueName: "path"))
    var binaryPaths: [String]

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
            "Output database path, for a single binary. A missing extension is completed with .i64.",
            valueName: "path"
        )
    )
    var outputDatabasePath: String?

    @Option(
        name: .customLong("output-dir"),
        help: ArgumentHelp(
            "Directory to write the databases into, each named after its input. Defaults to the current directory.",
            valueName: "path"
        )
    )
    var outputDirectoryPath: String?

    @Option(
        name: .customLong("jobs"),
        help: ArgumentHelp(
            "How many binaries to build at the same time.",
            valueName: "count"
        )
    )
    var maximumConcurrentJobs: Int = 1

    @Option(
        name: .customLong("work-dir"),
        help: ArgumentHelp(
            "Where to keep IDA's working database. Must be on the same volume as the input.",
            valueName: "path"
        )
    )
    var workingDirectoryParentPath: String?

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
        guard maximumConcurrentJobs >= 1 else {
            throw ValidationError("--jobs must be at least 1.")
        }
        if let workingDirectoryParentPath {
            var workingDirectoryIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: workingDirectoryParentPath,
                isDirectory: &workingDirectoryIsDirectory
            ), workingDirectoryIsDirectory.boolValue else {
                throw ValidationError(
                    "The working directory does not exist: \(workingDirectoryParentPath)"
                )
            }
        }

        // The whole batch is checked before any of it starts. One database is
        // minutes to an hour of work, so a name collision that was knowable up
        // front must not surface after the first one finishes.
        for creationPlan in try makeBatchPlan().jobs {
            try validate(creationPlan: creationPlan)
        }
    }

    private func validate(creationPlan: BinaryDatabaseCreationPlan) throws {
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
        let batchPlan = try makeBatchPlan()
        if batchPlan.jobs.count == 1 {
            try createDatabase(creationPlan: batchPlan.jobs[0])
            return
        }

        guard let executableURL = Bundle.main.executableURL else {
            throw ValidationError(
                "Could not locate the running idax executable, which is what builds each binary."
            )
        }
        let jobRunner = DatabaseJobRunner(
            executableURL: executableURL,
            maximumConcurrentJobs: maximumConcurrentJobs
        )
        let results = jobRunner.run(jobs: batchPlan.jobs.map(job(forCreationPlan:)))
        jobRunner.printSummary(results: results)

        guard results.allSatisfy(\.succeeded) else { throw ExitCode.failure }
    }

    /// One input's database, built in this process.
    ///
    /// This is also what each child process of a multi-input run ends up
    /// doing, so the two paths cannot drift apart.
    private func createDatabase(creationPlan: BinaryDatabaseCreationPlan) throws {
        // The slice has to be chosen before IDA starts: IDA only accepts an
        // input format on the initialisation call, and its own loader list
        // cannot be built before that call. The choice is verified against IDA
        // once the database is open.
        let fatSlices = try MachOFatHeader.slices(inFileAt: creationPlan.binaryFileURL)
        let selectedSlice = try SliceResolver.resolve(
            slices: fatSlices,
            requested: requestedArchitecture
        )

        // IDA unpacks its working database beside the file it opens, so it is
        // handed a hard link in a directory of this run's own instead of the
        // original path. See WorkingDatabaseDirectory.
        let workingDirectory = try WorkingDatabaseDirectory.make(
            forInputAt: creationPlan.binaryFileURL,
            preferredParentDirectory: workingDirectoryParentURL,
            linkingSiblingParts: false
        )
        defer { workingDirectory.remove() }
        print("Working database directory: \(workingDirectory.directoryURL.path)")

        // ParsableCommand.run() runs on the process main thread, which is the
        // thread IDAX requires for every SDK call.
        //
        // The input format travels as a `-T` runtime argument rather than a
        // structured option: `init_library` takes the IDA command line, and the
        // format has to be present on that single initialisation call. Passing
        // it later through open's argument string selects the right loader but
        // corrupts teardown.
        var runtimeArguments = ["idax"]
        if let selectedSlice {
            runtimeArguments.append(SliceResolver.inputFormatArgument(for: selectedSlice))
            print("Selecting \(selectedSlice.architecture) (slice \(selectedSlice.ordinal) of \(fatSlices?.count ?? 1))")
        } else {
            print("Loading with IDA's detected format")
        }

        print("Initializing IDA runtime")
        try Database.initialize(arguments: runtimeArguments)

        var databaseIsOpen = false
        defer {
            if databaseIsOpen {
                try? Database.close(save: false)
            }
        }

        try Database.open(path: workingDirectory.inputFileURL.path, mode: .skipAnalysis)
        databaseIsOpen = true

        let loadedFormatName = try Database.fileTypeName()
        print("Loaded as: \(loadedFormatName)")
        if let selectedSlice {
            try Self.verifyLoadedArchitecture(
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
        try Database.saveTo(outputDatabasePath: creationPlan.outputFileURL.path)
        try Database.close(save: false)
        databaseIsOpen = false
        print("Created database: \(creationPlan.outputFileURL.path)")
    }

    /// The child invocation for one input.
    ///
    /// Every choice is spelled out rather than inherited, so the command in the
    /// failure summary is the command that ran.
    private func job(forCreationPlan creationPlan: BinaryDatabaseCreationPlan) -> DatabaseJob {
        var arguments = [
            Self.configuration.commandName ?? "binary",
            creationPlan.binaryFileURL.path,
            "--output", creationPlan.outputFileURL.path,
        ]
        if let requestedArchitecture {
            arguments += ["--arch", requestedArchitecture.rawValue]
        }
        if let workingDirectoryParentPath {
            arguments += ["--work-dir", workingDirectoryParentPath]
        }
        if skipFinalAnalysis {
            arguments.append("--skip-final-analysis")
        }
        if overwriteExistingOutput {
            arguments.append("--overwrite")
        }
        return DatabaseJob(inputFileURL: creationPlan.binaryFileURL, arguments: arguments)
    }

    /// Confirm IDA loaded the slice that was asked for.
    ///
    /// The ordinal handed to IDA is derived from the fat header, on the
    /// assumption that IDA numbers its candidate loaders in file order. That
    /// holds for every binary measured, but a slice IDA declines to load would
    /// shift the numbering — so the result is checked rather than assumed, and
    /// a mismatch fails loudly instead of producing a database for the wrong
    /// architecture.
    static func verifyLoadedArchitecture(
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

    var workingDirectoryParentURL: URL? {
        workingDirectoryParentPath.map {
            BinaryDatabaseCreationPlan.absoluteFileURL(
                path: $0,
                currentDirectoryPath: FileManager.default.currentDirectoryPath
            )
        }
    }

    func makeBatchPlan() throws -> BinaryDatabaseBatchPlan {
        try BinaryDatabaseBatchPlan(
            binaryPaths: binaryPaths,
            outputDatabasePath: outputDatabasePath,
            outputDirectoryPath: outputDirectoryPath,
            currentDirectoryPath: FileManager.default.currentDirectoryPath
        )
    }
}

nonisolated struct BinaryDatabaseCreationPlan: Sendable {
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
