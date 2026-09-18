import Foundation

/// One database to build, expressed as the command that builds it.
nonisolated struct DatabaseJob: Sendable {
    let inputFileURL: URL
    /// Arguments after the executable, forming a command that can be rerun
    /// by hand exactly as it ran here.
    let arguments: [String]
}

nonisolated struct DatabaseJobResult: Sendable {
    let job: DatabaseJob
    let terminationStatus: Int32
    /// Output held back and printed in one piece, used only when jobs run
    /// concurrently. `nil` means the job wrote straight to this process's
    /// streams.
    let capturedOutput: String?

    var succeeded: Bool { terminationStatus == 0 }
}

/// Runs each database in its own process.
///
/// Not for parallelism — for correctness. The input format that selects a
/// universal binary's architecture slice is only accepted by `init_library`,
/// once per process, so one process cannot build two databases from two
/// different slices. A loop inside this process would silently analyse the
/// wrong architecture.
///
/// What it buys on top: a malformed input that kills IDA kills one job instead
/// of the batch, and every failure prints a command that reproduces it alone.
nonisolated struct DatabaseJobRunner: Sendable {
    let executableURL: URL
    let maximumConcurrentJobs: Int

    func run(jobs: [DatabaseJob]) -> [DatabaseJobResult] {
        maximumConcurrentJobs <= 1
            ? runSequentially(jobs: jobs)
            : runConcurrently(jobs: jobs)
    }

    /// Serial jobs write straight through, so progress appears as it happens —
    /// the same output a single-input run produces today.
    private func runSequentially(jobs: [DatabaseJob]) -> [DatabaseJobResult] {
        jobs.enumerated().map { jobIndex, job in
            printFlushed(banner(jobIndex: jobIndex, jobCount: jobs.count, job: job))
            return runInheritingOutput(job: job)
        }
    }

    /// Concurrent jobs are held back and printed whole, because several IDA
    /// runs writing to one terminal at once produce output nobody can read.
    private func runConcurrently(jobs: [DatabaseJob]) -> [DatabaseJobResult] {
        let resultCollector = DatabaseJobResultCollector()
        let availableSlots = DispatchSemaphore(value: maximumConcurrentJobs)
        let runningJobs = DispatchGroup()
        let printingLock = NSLock()

        for (jobIndex, job) in jobs.enumerated() {
            availableSlots.wait()
            DispatchQueue.global(qos: .userInitiated).async(group: runningJobs) {
                let result = runCapturingOutput(job: job)

                printingLock.lock()
                var block = banner(jobIndex: jobIndex, jobCount: jobs.count, job: job)
                if let capturedOutput = result.capturedOutput, !capturedOutput.isEmpty {
                    block += "\n" + capturedOutput.trimmingCharacters(in: .newlines)
                }
                printFlushed(block)
                printingLock.unlock()

                resultCollector.record(result, at: jobIndex)
                availableSlots.signal()
            }
        }

        runningJobs.wait()
        return resultCollector.orderedResults(count: jobs.count)
    }

    private func runInheritingOutput(job: DatabaseJob) -> DatabaseJobResult {
        let process = makeProcess(for: job)
        do {
            try process.run()
        } catch {
            print("error: could not start \(executableURL.path): \(error.localizedDescription)")
            return DatabaseJobResult(job: job, terminationStatus: -1, capturedOutput: nil)
        }
        process.waitUntilExit()
        return DatabaseJobResult(
            job: job,
            terminationStatus: process.terminationStatus,
            capturedOutput: nil
        )
    }

    private func runCapturingOutput(job: DatabaseJob) -> DatabaseJobResult {
        let process = makeProcess(for: job)
        // One pipe for both streams keeps IDA's progress and its complaints in
        // the order they were written.
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return DatabaseJobResult(
                job: job,
                terminationStatus: -1,
                capturedOutput: "error: could not start \(executableURL.path): "
                    + error.localizedDescription
            )
        }

        // Drained before waiting: a child that fills the pipe buffer blocks
        // until someone reads, and waiting first would be that deadlock.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return DatabaseJobResult(
            job: job,
            terminationStatus: process.terminationStatus,
            capturedOutput: String(decoding: outputData, as: UTF8.self)
        )
    }

    private func makeProcess(for job: DatabaseJob) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = job.arguments
        return process
    }

    private func banner(jobIndex: Int, jobCount: Int, job: DatabaseJob) -> String {
        "==> [\(jobIndex + 1)/\(jobCount)] \(job.inputFileURL.path)"
    }

    /// Print and flush.
    ///
    /// The children write to the inherited descriptors directly and flush when
    /// they exit, while this process's own stdout is fully buffered whenever it
    /// is a pipe rather than a terminal. Unflushed, every line printed here
    /// would arrive after all of the children's.
    private func printFlushed(_ line: String) {
        print(line)
        fflush(stdout)
    }

    // MARK: - Reporting

    /// Report what happened, and how to retry whatever did not.
    func printSummary(results: [DatabaseJobResult]) {
        let failures = results.filter { !$0.succeeded }
        var summary = [
            "",
            "==> \(results.count) binaries: \(results.count - failures.count) succeeded, "
                + "\(failures.count) failed",
        ]
        for failure in failures {
            summary.append(
                "    failed: \(failure.job.inputFileURL.path) "
                    + "(exit status \(failure.terminationStatus))"
            )
            summary.append("      rerun: \(rerunCommand(for: failure.job))")
        }
        printFlushed(summary.joined(separator: "\n"))
    }

    func rerunCommand(for job: DatabaseJob) -> String {
        ([executableURL.lastPathComponent] + job.arguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    /// Quote a word so the printed rerun command survives a paste into a shell.
    ///
    /// Database and binary paths routinely contain spaces —
    /// `/Applications/IDA Professional 9.4.app/…` — so a command printed
    /// unquoted is a command that does not work.
    static func shellQuoted(_ word: String) -> String {
        let safeCharacters = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/=,:+@")
        guard !word.isEmpty else { return "''" }
        guard word.unicodeScalars.contains(where: { !safeCharacters.contains($0) }) else {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Results gathered from jobs finishing in whatever order they finish, handed
/// back in the order they were requested.
private final class DatabaseJobResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var resultsByIndex: [Int: DatabaseJobResult] = [:]

    func record(_ result: DatabaseJobResult, at index: Int) {
        lock.lock()
        resultsByIndex[index] = result
        lock.unlock()
    }

    func orderedResults(count: Int) -> [DatabaseJobResult] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<count).compactMap { resultsByIndex[$0] }
    }
}
