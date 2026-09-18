import ArgumentParser
import Foundation

/// Every database `idax binary` was asked to produce in one invocation.
///
/// The whole batch is resolved before any of it runs. A database takes minutes
/// to an hour, so a mistake that is knowable up front — two inputs landing on
/// one output name, an output that already exists — has to be reported up
/// front rather than after the first hour of analysis.
nonisolated struct BinaryDatabaseBatchPlan: Sendable {
    let jobs: [BinaryDatabaseCreationPlan]

    init(
        binaryPaths: [String],
        outputDatabasePath: String?,
        outputDirectoryPath: String?,
        currentDirectoryPath: String
    ) throws {
        guard !binaryPaths.isEmpty else {
            throw ValidationError("At least one binary path is required.")
        }
        if binaryPaths.count > 1, outputDatabasePath != nil {
            throw ValidationError(
                "--output names one database, but \(binaryPaths.count) binaries were given. "
                    + "Use --output-dir instead."
            )
        }
        if outputDatabasePath != nil, outputDirectoryPath != nil {
            throw ValidationError("--output and --output-dir cannot be combined.")
        }

        let outputDirectoryURL = outputDirectoryPath.map {
            BinaryDatabaseCreationPlan.absoluteFileURL(
                path: $0,
                currentDirectoryPath: currentDirectoryPath
            )
        }

        var jobs: [BinaryDatabaseCreationPlan] = []
        for binaryPath in binaryPaths {
            let resolvedOutputPath = try Self.outputPath(
                forBinaryAt: binaryPath,
                outputDatabasePath: outputDatabasePath,
                outputDirectoryURL: outputDirectoryURL,
                currentDirectoryPath: currentDirectoryPath
            )
            jobs.append(
                try BinaryDatabaseCreationPlan(
                    binaryPath: binaryPath,
                    outputDatabasePath: resolvedOutputPath,
                    currentDirectoryPath: currentDirectoryPath
                )
            )
        }

        try Self.rejectSharedOutputs(jobs: jobs)
        self.jobs = jobs
    }

    /// Where one input's database goes.
    ///
    /// `nil` hands the decision back to `BinaryDatabaseCreationPlan`, which
    /// names it after the input in the current directory — the single-input
    /// default, unchanged.
    private static func outputPath(
        forBinaryAt binaryPath: String,
        outputDatabasePath: String?,
        outputDirectoryURL: URL?,
        currentDirectoryPath: String
    ) throws -> String? {
        if let outputDatabasePath { return outputDatabasePath }
        guard let outputDirectoryURL else { return nil }

        let binaryFileURL = BinaryDatabaseCreationPlan.absoluteFileURL(
            path: binaryPath,
            currentDirectoryPath: currentDirectoryPath
        )
        let outputName = binaryFileURL.deletingPathExtension().lastPathComponent
        guard !outputName.isEmpty else {
            throw ValidationError("Unable to derive an output name from \(binaryPath).")
        }
        return outputDirectoryURL
            .appendingPathComponent(outputName + ".i64")
            .path
    }

    /// Two inputs writing to one database is a mistake, never an intent.
    ///
    /// It is easy to arrive at by accident: every application bundle names its
    /// executable after the bundle, so `A.app/Contents/MacOS/App` and
    /// `B.app/Contents/MacOS/App` both derive `App.i64`. Renaming one
    /// automatically would leave nobody able to say which database came from
    /// which input.
    private static func rejectSharedOutputs(jobs: [BinaryDatabaseCreationPlan]) throws {
        var binaryPathsByOutputPath: [String: String] = [:]
        for job in jobs {
            let outputPath = job.outputFileURL.path
            if let firstBinaryPath = binaryPathsByOutputPath[outputPath] {
                throw ValidationError("""
                    Two binaries would produce the same database. \
                    \(firstBinaryPath) and \(job.binaryFileURL.path) both produce \
                    \(outputPath). Give them separate runs with --output, or separate \
                    --output-dir directories.
                    """)
            }
            binaryPathsByOutputPath[outputPath] = job.binaryFileURL.path
        }
    }
}
