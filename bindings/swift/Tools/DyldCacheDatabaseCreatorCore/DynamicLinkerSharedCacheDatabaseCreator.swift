import ArgumentParser
import Darwin
import Foundation
import IDAX

public struct DynamicLinkerSharedCacheDatabaseCreator: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "idax-dyld-cache-database-creator",
        abstract: "Create an IDA database from selected dyld shared cache images.",
        discussion: """
        Select images by name with --image-name or by their complete cache path
        with --image-path. Each option accepts a space-separated list. Image
        names match the path's final component after removing its extension.
        """
    )

    @Option(
        name: .customLong("cache"),
        help: ArgumentHelp("Path to the dyld shared cache file.", valueName: "path")
    )
    var cachePath: String

    @Option(
        name: .customLong("image-name"),
        parsing: .upToNextOption,
        help: ArgumentHelp(
            "Image names to load. Names match path basenames without extensions; the first cache-order match is used.",
            valueName: "name"
        )
    )
    var imageNames: [String] = []

    @Option(
        name: .customLong("image-path"),
        parsing: .upToNextOption,
        help: ArgumentHelp(
            "Complete image paths stored in the cache.",
            valueName: "path"
        )
    )
    var explicitImagePaths: [String] = []

    @Option(
        name: .customLong("output"),
        help: ArgumentHelp(
            "Output database path. A missing extension is completed with .i64.",
            valueName: "path"
        )
    )
    var outputDatabasePath: String?

    @Flag(
        name: .customLong("load-dyld-header"),
        help: "Load and format the dyld cache header."
    )
    var loadDynamicLinkerHeader = false

    @Flag(
        name: .customLong("load-branch-islands"),
        help: "Load every branch-island region."
    )
    var loadBranchIslands = false

    @Flag(
        name: .customLong("load-branch-mappings"),
        help: "Load every branch-mapping region."
    )
    var loadBranchMappings = false

    @Flag(
        name: [
            .customLong("load-global-offset-tables"),
            .customLong("load-got"),
        ],
        help: "Load every global offset table region."
    )
    var loadGlobalOffsetTables = false

    @Flag(
        name: [
            .customLong("load-gaps"),
            .customLong("load-gap"),
            .customLong("load-unknown-regions"),
            .customLong("load-unknown-region"),
        ],
        help: "Load every unknown region (called a gap by IDA 9.3)."
    )
    var loadGaps = false

    @Flag(
        name: .customLong("load-cache-data"),
        help: "Load every cache-wide data region (IDA 9.4 or newer)."
    )
    var loadCacheData = false

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
        if let outputDatabasePath {
            let explicitOutputURL = DynamicLinkerSharedCacheDatabaseCreationPlan.absoluteFileURL(
                path: outputDatabasePath,
                currentDirectoryPath: FileManager.default.currentDirectoryPath
            )
            var explicitOutputIsDirectory = ObjCBool(false)
            if FileManager.default.fileExists(
                atPath: explicitOutputURL.path,
                isDirectory: &explicitOutputIsDirectory
            ), explicitOutputIsDirectory.boolValue {
                throw ValidationError(
                    "The output database path is a directory: \(explicitOutputURL.path)"
                )
            }
        }

        let creationPlan = try makeCreationPlan()
        var cachePathIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: creationPlan.cacheFileURL.path,
            isDirectory: &cachePathIsDirectory
        ), !cachePathIsDirectory.boolValue else {
            throw ValidationError(
                "The dyld shared cache file does not exist: \(creationPlan.cacheFileURL.path)"
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
                "The output database path is a directory: "
                    + creationPlan.outputFileURL.path
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
        print("Initializing IDA runtime")
        try Database.initialize()

        print("Resolving cache images")
        let availableImagePaths = try DyldCache.listModules(
            in: creationPlan.cacheFileURL.path
        ).map(\.path)
        let resolvedImagePaths = try creationPlan.resolveImagePaths(
            availableImagePaths: availableImagePaths
        )

        let moduleEnvironmentSnapshot = EnvironmentVariableSnapshot(
            name: "IDA_DYLD_CACHE_MODULE"
        )
        let depthEnvironmentSnapshot = EnvironmentVariableSnapshot(
            name: "IDA_DYLD_CACHE_DEPTH"
        )
        defer {
            moduleEnvironmentSnapshot.restore()
            depthEnvironmentSnapshot.restore()
        }

        setenv("IDA_DYLD_CACHE_MODULE", resolvedImagePaths[0], 1)
        setenv("IDA_DYLD_CACHE_DEPTH", "0", 1)

        var databaseIsOpen = false
        defer {
            if databaseIsOpen {
                try? Database.close(save: false)
            }
        }

        print("Opening cache: \(creationPlan.cacheFileURL.path)")
        try Database.open(creationPlan.cacheFileURL.path, autoAnalysis: false)
        databaseIsOpen = true

        guard DyldCache.isAvailable() else {
            throw ValidationError(
                "IDA dyld shared cache utilities are unavailable for the opened cache."
            )
        }

        for additionalImagePath in resolvedImagePaths.dropFirst() {
            print("Loading image: \(additionalImagePath)")
            try DyldCache.loadModule(additionalImagePath, waitForAnalysis: false)
        }

        if loadDynamicLinkerHeader {
            print("Waiting for initial analysis before loading the dyld header")
            try Analysis.wait()
            try DyldCache.loadDyldHeader(waitForAnalysis: false)
        }

        if loadBranchIslands {
            let loadedRegionCount = try DyldCache.loadBranchIslands(waitForAnalysis: false)
            print("Loaded branch-island regions: \(loadedRegionCount)")
        }

        if loadBranchMappings {
            let loadedRegionCount = try DyldCache.loadBranchMappings(waitForAnalysis: false)
            print("Loaded branch-mapping regions: \(loadedRegionCount)")
        }

        if loadGlobalOffsetTables {
            let loadedRegionCount = try DyldCache.loadGlobalOffsetTables(waitForAnalysis: false)
            print("Loaded global offset table regions: \(loadedRegionCount)")
        }

        if loadGaps {
            let loadedRegionCount = try DyldCache.loadGaps(waitForAnalysis: false)
            print("Loaded unknown regions: \(loadedRegionCount)")
        }

        if loadCacheData {
            let loadedRegionCount = try DyldCache.loadCacheData(waitForAnalysis: false)
            print("Loaded cache-wide data regions: \(loadedRegionCount)")
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

    func makeCreationPlan() throws -> DynamicLinkerSharedCacheDatabaseCreationPlan {
        try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: cachePath,
            imageNames: imageNames,
            explicitImagePaths: explicitImagePaths,
            outputDatabasePath: outputDatabasePath,
            currentDirectoryPath: FileManager.default.currentDirectoryPath
        )
    }
}

struct DynamicLinkerSharedCacheDatabaseCreationPlan {
    let cacheFileURL: URL
    let imageNames: [String]
    let explicitImagePaths: [String]
    let outputFileURL: URL

    init(
        cachePath: String,
        imageNames: [String] = [],
        explicitImagePaths: [String] = [],
        outputDatabasePath: String?,
        currentDirectoryPath: String
    ) throws {
        try Self.validateImageSelectors(
            imageNames: imageNames,
            explicitImagePaths: explicitImagePaths
        )
        let cacheFileURL = Self.absoluteFileURL(
            path: cachePath,
            currentDirectoryPath: currentDirectoryPath
        )
        let outputFileURL = try Self.outputFileURL(
            imageNames: imageNames,
            explicitImagePaths: explicitImagePaths,
            outputDatabasePath: outputDatabasePath,
            currentDirectoryPath: currentDirectoryPath
        )
        guard cacheFileURL != outputFileURL else {
            throw ValidationError("The output database path must differ from the cache path.")
        }
        self.cacheFileURL = cacheFileURL
        self.imageNames = imageNames
        self.explicitImagePaths = explicitImagePaths
        self.outputFileURL = outputFileURL
    }

    static func validateImageSelectors(
        imageNames: [String],
        explicitImagePaths: [String]
    ) throws {
        guard !imageNames.isEmpty || !explicitImagePaths.isEmpty else {
            throw ValidationError(
                "At least one --image-name or --image-path value is required."
            )
        }
        guard imageNames.allSatisfy({ !$0.isEmpty && !$0.contains("/") }) else {
            throw ValidationError(
                "Every --image-name value must be a nonempty path component."
            )
        }
        guard Set(imageNames).count == imageNames.count else {
            throw ValidationError("Duplicate --image-name values are not allowed.")
        }
        guard explicitImagePaths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ValidationError(
                "Every --image-path value must be a complete image path stored in the cache."
            )
        }
        guard Set(explicitImagePaths).count == explicitImagePaths.count else {
            throw ValidationError("Duplicate --image-path values are not allowed.")
        }
    }

    func resolveImagePaths(availableImagePaths: [String]) throws -> [String] {
        let imagePathsByName = Dictionary(grouping: availableImagePaths) {
            Self.imageName(forImagePath: $0)
        }
        var resolvedImagePaths: [String] = []

        for imageName in imageNames {
            guard let matchingImagePath = imagePathsByName[imageName]?.first else {
                throw ValidationError(
                    "No cache image matches --image-name \(imageName)."
                )
            }
            resolvedImagePaths.append(matchingImagePath)
        }

        let availableImagePathSet = Set(availableImagePaths)
        let missingExplicitImagePaths = explicitImagePaths.filter {
            !availableImagePathSet.contains($0)
        }
        guard missingExplicitImagePaths.isEmpty else {
            throw ValidationError(
                "The following --image-path values are not present in the cache: "
                    + missingExplicitImagePaths.joined(separator: ", ")
            )
        }
        resolvedImagePaths.append(contentsOf: explicitImagePaths)

        guard Set(resolvedImagePaths).count == resolvedImagePaths.count else {
            throw ValidationError(
                "The image selectors resolve to duplicate cache images."
            )
        }
        return resolvedImagePaths
    }

    static func outputFileURL(
        imageNames: [String],
        explicitImagePaths: [String],
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

        let outputImageNames = imageNames + explicitImagePaths.map {
            imageName(forImagePath: $0)
        }
        guard outputImageNames.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError("Unable to derive an output name from the image paths.")
        }
        let outputFilename = outputImageNames.joined(separator: "+") + ".i64"
        return absoluteFileURL(
            path: outputFilename,
            currentDirectoryPath: currentDirectoryPath
        )
    }

    static func imageName(forImagePath imagePath: String) -> String {
        URL(fileURLWithPath: imagePath)
            .deletingPathExtension()
            .lastPathComponent
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

private struct EnvironmentVariableSnapshot {
    let name: String
    let value: String?

    init(name: String) {
        self.name = name
        self.value = getenv(name).map { String(cString: $0) }
    }

    func restore() {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }
}
