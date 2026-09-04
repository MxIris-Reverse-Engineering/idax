import ArgumentParser
import Foundation
import Testing
@testable import IDAXCommandLineCore

@Suite("Dyld Cache Database Creator")
struct DynamicLinkerSharedCacheDatabaseCreatorTests {
    @Test func defaultOutputNameJoinsImageNames() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            explicitImagePaths: [
                "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                "/System/Library/PrivateFrameworks/UIKitMacHelper.framework/Versions/A/UIKitMacHelper",
            ],
            outputDatabasePath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(creationPlan.outputFileURL.path == "/Work/AppKit+UIKitMacHelper.i64")
    }

    @Test func explicitOutputNameGetsDefaultExtension() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            explicitImagePaths: ["/usr/lib/libobjc.A.dylib"],
            outputDatabasePath: "Databases/ObjectiveCRuntime",
            currentDirectoryPath: "/Work"
        )

        #expect(creationPlan.outputFileURL.path == "/Work/Databases/ObjectiveCRuntime.i64")
    }

    @Test func explicitOutputExtensionIsPreserved() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            explicitImagePaths: ["/usr/lib/libobjc.A.dylib"],
            outputDatabasePath: "/Work/ObjectiveCRuntime.database",
            currentDirectoryPath: "/Ignored"
        )

        #expect(creationPlan.outputFileURL.path == "/Work/ObjectiveCRuntime.database")
    }

    @Test func defaultOutputNameRemovesImagePathExtension() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            explicitImagePaths: ["/usr/lib/libobjc.A.dylib"],
            outputDatabasePath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(creationPlan.outputFileURL.path == "/Work/libobjc.A.i64")
    }

    @Test func imageNameListAndAliasesParse() throws {
        let command = try DynamicLinkerSharedCacheDatabaseCreator.parse([
            "--cache", "/dev/null",
            "--image-name", "AppKit", "SwiftUI", "SwiftUICore",
            "--load-got",
            "--load-unknown-regions",
            "--load-cache-data",
            "--skip-final-analysis",
        ])

        #expect(command.imageNames == ["AppKit", "SwiftUI", "SwiftUICore"])
        #expect(command.loadGlobalOffsetTables)
        #expect(command.loadGaps)
        #expect(command.loadCacheData)
        #expect(command.skipFinalAnalysis)
    }

    @Test func imagePathListParses() throws {
        let command = try DynamicLinkerSharedCacheDatabaseCreator.parse([
            "--cache", "/dev/null",
            "--image-path",
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/usr/lib/libobjc.A.dylib",
        ])

        #expect(command.explicitImagePaths == [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/usr/lib/libobjc.A.dylib",
        ])
    }

    @Test func missingImageSelectorsAreRejected() {
        #expect(throws: ValidationError.self) {
            try DynamicLinkerSharedCacheDatabaseCreationPlan.validateImageSelectors(
                imageNames: [],
                explicitImagePaths: []
            )
        }
    }

    @Test func duplicateImageNamesAreRejected() {
        #expect(throws: ValidationError.self) {
            try DynamicLinkerSharedCacheDatabaseCreationPlan.validateImageSelectors(
                imageNames: ["AppKit", "AppKit"],
                explicitImagePaths: []
            )
        }
    }

    @Test func duplicateImagePathsAreRejected() {
        #expect(throws: ValidationError.self) {
            try DynamicLinkerSharedCacheDatabaseCreationPlan.validateImageSelectors(
                imageNames: [],
                explicitImagePaths: [
                    "/usr/lib/libobjc.A.dylib",
                    "/usr/lib/libobjc.A.dylib",
                ]
            )
        }
    }

    @Test func imagePathBasenamesAreRejected() {
        #expect(throws: ValidationError.self) {
            try DynamicLinkerSharedCacheDatabaseCreationPlan.validateImageSelectors(
                imageNames: [],
                explicitImagePaths: ["AppKit"]
            )
        }
    }

    @Test func imageNamesContainingPathSeparatorsAreRejected() {
        #expect(throws: ValidationError.self) {
            try DynamicLinkerSharedCacheDatabaseCreationPlan.validateImageSelectors(
                imageNames: ["Frameworks/AppKit"],
                explicitImagePaths: []
            )
        }
    }

    @Test func imageNamesResolveByPathComponentWithoutExtension() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            imageNames: ["AppKit", "libobjc.A"],
            outputDatabasePath: nil,
            currentDirectoryPath: "/Work"
        )

        let resolvedImagePaths = try creationPlan.resolveImagePaths(
            availableImagePaths: [
                "/usr/lib/libobjc.A.dylib",
                "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            ]
        )

        #expect(resolvedImagePaths == [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/usr/lib/libobjc.A.dylib",
        ])
        #expect(creationPlan.outputFileURL.path == "/Work/AppKit+libobjc.A.i64")
    }

    @Test func duplicateImageNamesUseTheFirstCacheOrderMatch() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            imageNames: ["Example"],
            outputDatabasePath: nil,
            currentDirectoryPath: "/Work"
        )

        let resolvedImagePaths = try creationPlan.resolveImagePaths(availableImagePaths: [
            "/System/Library/Frameworks/Example.dylib",
            "/System/Library/PrivateFrameworks/Example.framework/Example",
        ])

        #expect(resolvedImagePaths == ["/System/Library/Frameworks/Example.dylib"])
    }

    @Test func missingImageNamesAreRejected() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            imageNames: ["MissingImage"],
            outputDatabasePath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(throws: ValidationError.self) {
            try creationPlan.resolveImagePaths(availableImagePaths: [
                "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
            ])
        }
    }

    @Test func missingExplicitImagePathsAreRejected() throws {
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            explicitImagePaths: ["/usr/lib/libMissing.dylib"],
            outputDatabasePath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(throws: ValidationError.self) {
            try creationPlan.resolveImagePaths(availableImagePaths: [
                "/usr/lib/libobjc.A.dylib"
            ])
        }
    }

    @Test func combinedSelectorsCannotResolveToTheSameImage() throws {
        let imagePath = "/usr/lib/libobjc.A.dylib"
        let creationPlan = try DynamicLinkerSharedCacheDatabaseCreationPlan(
            cachePath: "/Caches/dyld_shared_cache_arm64e",
            imageNames: ["libobjc.A"],
            explicitImagePaths: [imagePath],
            outputDatabasePath: nil,
            currentDirectoryPath: "/Work"
        )

        #expect(throws: ValidationError.self) {
            try creationPlan.resolveImagePaths(availableImagePaths: [imagePath])
        }
    }

    @Test func emptyExplicitOutputPathIsRejected() {
        #expect(throws: ValidationError.self) {
            try DynamicLinkerSharedCacheDatabaseCreationPlan(
                cachePath: "/Caches/dyld_shared_cache_arm64e",
                explicitImagePaths: ["/usr/lib/libobjc.A.dylib"],
                outputDatabasePath: "",
                currentDirectoryPath: "/Work"
            )
        }
    }

    @Test func cacheCannotBeOverwrittenByOutputDatabase() {
        #expect(throws: ValidationError.self) {
            try DynamicLinkerSharedCacheDatabaseCreationPlan(
                cachePath: "/Caches/dyld_shared_cache_arm64e.i64",
                explicitImagePaths: ["/usr/lib/libobjc.A.dylib"],
                outputDatabasePath: "/Caches/dyld_shared_cache_arm64e.i64",
                currentDirectoryPath: "/Work"
            )
        }
    }

    @Test func outputDirectoryIsRejectedEvenWhenOverwriteIsEnabled() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let cacheFileURL = temporaryDirectoryURL.appendingPathComponent(
            "dyld_shared_cache_arm64e"
        )
        #expect(FileManager.default.createFile(atPath: cacheFileURL.path, contents: Data()))

        var command = DynamicLinkerSharedCacheDatabaseCreator()
        command.cachePath = cacheFileURL.path
        command.explicitImagePaths = ["/usr/lib/libobjc.A.dylib"]
        command.outputDatabasePath = temporaryDirectoryURL.path
        command.overwriteExistingOutput = true

        #expect(throws: ValidationError.self) {
            try command.validate()
        }
    }
}
