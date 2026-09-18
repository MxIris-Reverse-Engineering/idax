import Foundation
import Testing
@testable import IDAXCommandLineCore

@Suite("Database Job Runner")
struct DatabaseJobRunnerTests {
    @Test func plainWordsAreLeftAlone() {
        #expect(DatabaseJobRunner.shellQuoted("/bin/ls") == "/bin/ls")
        #expect(DatabaseJobRunner.shellQuoted("--output-dir") == "--output-dir")
    }

    /// The paths this tool deals in routinely contain spaces —
    /// `/Applications/IDA Professional 9.4.app/…` — so an unquoted rerun
    /// command is one that does not work when pasted back.
    @Test func wordsNeedingQuotesGetThem() {
        #expect(
            DatabaseJobRunner.shellQuoted("/Applications/My App.app/Contents/MacOS/My App")
                == "'/Applications/My App.app/Contents/MacOS/My App'"
        )
        #expect(DatabaseJobRunner.shellQuoted("") == "''")
        #expect(DatabaseJobRunner.shellQuoted("it's") == #"'it'\''s'"#)
    }

    @Test func theRerunCommandNamesTheToolAndItsArguments() {
        let jobRunner = DatabaseJobRunner(
            executableURL: URL(fileURLWithPath: "/Users/someone/.local/libexec/idax/idax"),
            maximumConcurrentJobs: 1
        )
        let job = DatabaseJob(
            inputFileURL: URL(fileURLWithPath: "/Applications/My App.app/Contents/MacOS/App"),
            arguments: [
                "binary",
                "/Applications/My App.app/Contents/MacOS/App",
                "--output", "/Databases/App.i64",
            ]
        )

        #expect(jobRunner.rerunCommand(for: job) == """
            idax binary '/Applications/My App.app/Contents/MacOS/App' --output /Databases/App.i64
            """)
    }

    @Test func everyJobRunsAndResultsComeBackInRequestOrder() throws {
        let jobRunner = DatabaseJobRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            maximumConcurrentJobs: 4
        )
        let jobs = (0..<6).map { jobIndex in
            DatabaseJob(
                inputFileURL: URL(fileURLWithPath: "/inputs/\(jobIndex)"),
                arguments: ["-c", "echo job \(jobIndex); exit \(jobIndex % 2)"]
            )
        }

        let results = jobRunner.run(jobs: jobs)

        #expect(results.count == jobs.count)
        #expect(results.map(\.succeeded) == [true, false, true, false, true, false])
        for (jobIndex, result) in results.enumerated() {
            #expect(result.job.inputFileURL.path == "/inputs/\(jobIndex)")
            #expect(result.capturedOutput?.contains("job \(jobIndex)") == true)
        }
    }

    @Test func aSerialRunLetsTheChildWriteStraightThrough() throws {
        let jobRunner = DatabaseJobRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            maximumConcurrentJobs: 1
        )
        let results = jobRunner.run(jobs: [
            DatabaseJob(
                inputFileURL: URL(fileURLWithPath: "/inputs/only"),
                arguments: ["-c", "exit 3"]
            ),
        ])

        #expect(results[0].terminationStatus == 3)
        #expect(results[0].capturedOutput == nil)
    }
}
