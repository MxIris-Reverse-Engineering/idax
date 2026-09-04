import ArgumentParser

public nonisolated struct IDAXCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "idax",
        abstract: "Create IDA databases from binaries and dyld shared cache images.",
        subcommands: [
            BinaryDatabaseCreator.self,
            DynamicLinkerSharedCacheDatabaseCreator.self,
            InputFormatLister.self,
        ]
    )

    public init() {}
}
