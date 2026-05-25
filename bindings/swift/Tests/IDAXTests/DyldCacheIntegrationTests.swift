import Testing
import Foundation
@testable import IDAX

/// Integration walkthrough of `ida::dyld_cache`.
///
/// Requires:
///   - IDA Pro installed (so `IDARuntime.isAvailable` returns true)
///   - `IDAX_TEST_DSC_DATABASE` environment variable pointing at a `.i64`
///     database that was opened from a dyld shared cache with the
///     "single module" option.
///
/// When either prerequisite is missing the test prints a skip notice and
/// passes — `swift test` can be run without any setup; only developers
/// who provide a DSC fixture exercise the dscu driver end-to-end.
@Suite("IDA DyldCache Integration")
struct DyldCacheIntegrationTests {

    @Test func dscuDriverWalkthrough() async throws {
//        guard let databasePath = ProcessInfo.processInfo.environment["IDAX_TEST_DSC_DATABASE"] else {
//            print("IDAX_TEST_DSC_DATABASE not set — skipping dyld-cache integration test")
//            return
//        }
        let databasePath = "/Volumes/RE/Dyld-Shared-Cache/macOS/26.5/dyld_shared_cache_arm64e"

        guard IDARuntime.isAvailable else {
            print("IDA runtime not available — skipping dyld-cache integration test")
            return
        }

        // IDA's Mach-O loader picks the cache image via an environment
        // variable; without it, opening the raw cache file fails outright.
        // The dscu plugin is only registered when the database is opened
        // this way (the "single module" option in the GUI).
        //   IDA_DYLD_CACHE_MODULE — module path inside the cache
        //   IDA_DYLD_CACHE_DEPTH  — dependency depth (0 = module only,
        //                            -1 = all)
        let modulePath = ProcessInfo.processInfo.environment["IDAX_TEST_DSC_MODULE"]
            ?? "/usr/lib/libobjc.A.dylib"
        setenv("IDA_DYLD_CACHE_MODULE", modulePath, 1)
        setenv("IDA_DYLD_CACHE_DEPTH", "0", 1)
        defer {
            unsetenv("IDA_DYLD_CACHE_MODULE")
            unsetenv("IDA_DYLD_CACHE_DEPTH")
        }

        print("=== DyldCache Integration ===")
        print("Cache:  \(databasePath)")
        print("Module: \(modulePath)")

        try Database.initialize()
        try Database.open(databasePath, autoAnalysis: false)
        defer { try? Database.close() }

        try #require(
            DyldCache.isAvailable(),
            "dscu plugin not loaded — open the database from a dyld shared cache with the 'single module' option"
        )

        // 1) Enumerate every image in the cache. Parses the DSC header on
        //    disk, so it works before any module is loaded.
        let cachedModules = try DyldCache.listModules()
        #expect(!cachedModules.isEmpty, "Expected at least one image in the cache header")
        print("Modules in cache: \(cachedModules.count)")
        for cachedModule in cachedModules.prefix(5) {
            let loadAddressHex = String(cachedModule.loadAddress, radix: 16)
            print("  0x\(loadAddressHex): \(cachedModule.path)")
        }

        // 2) Load a single module by its full cache path.
        //    `IDA_DYLD_CACHE_DEPTH=0` already materialised `modulePath`, so
        //    asking dscu to load it again would fail — pick any other
        //    image from the header.
        if let candidateModule = cachedModules.first(where: { $0.path != modulePath }) {
            print("Loading module: \(candidateModule.path)")
            try DyldCache.loadModule(candidateModule.path)
        } else {
            print("No additional modules to load — cache only contains \(modulePath)")
        }

        // 3) Materialise the formatted `dyld_cache_header` structure.
        //    Tolerated as best-effort because mode 6 requires the initial
        //    auto-analysis to have completed.
        do {
            try DyldCache.loadDyldHeader()
            print("Loaded dyld_cache_header")
        } catch {
            print("loadDyldHeader skipped: \(error)")
        }

        // 4) Bulk-load each region kind. Returning 0 is valid for caches
        //    that simply do not contain that kind of region.
        let branchIslandCount = try DyldCache.loadBranchIslands()
        print("Branch islands loaded: \(branchIslandCount)")

//        let branchMappingCount = try DyldCache.loadBranchMappings()
//        print("Branch mappings loaded: \(branchMappingCount)")

        let globalOffsetTableCount = try DyldCache.loadGlobalOffsetTables()
        print("Global offset tables loaded: \(globalOffsetTableCount)")

        let gapCount = try DyldCache.loadGaps()
        print("Gaps loaded: \(gapCount)")

        // 5) `loadSection(at:)` resolves a single region by address. It is
        //    not exercised here because a deterministic target address
        //    depends on the specific cache. Typical usage:
        //
        //        try DyldCache.loadSection(at: 0x1AECFF7F9)
        //
        //    The wrapper auto-detects the region kind and creates a
        //    segment covering the address.
        try Database.save()
    }
}
