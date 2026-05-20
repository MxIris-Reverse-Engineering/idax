internal import CIDAX

/// A single image (module) contained in a dyld shared cache.
///
/// Maps directly to C `IdaxDyldCacheModule`.
public struct DyldCacheModule: Sendable {
    /// Full path inside the cache (e.g. "/usr/lib/libobjc.A.dylib").
    public let path: String
    /// Mach-O header address of the image within the cache.
    public let loadAddress: Address
}

/// dyld shared cache utilities — programmatic access to IDA's bundled "dscu"
/// (dyld shared cache utils) plugin.
///
/// Every operation requires the current database to have been opened from a
/// dyld shared cache with the "single module" option. Check `isAvailable()`
/// first; otherwise each call throws `IDAError` with category `.unsupported`.
///
/// Mirrors C++ `ida::dyld_cache`.
public enum DyldCache {

    /// Whether dyld shared cache utilities are available for the current
    /// database (i.e. the "dscu" plugin is loaded).
    public static func isAvailable() -> Bool {
        idax_dyld_cache_is_available() != 0
    }

    /// Enumerate every module (image) contained in the dyld shared cache.
    ///
    /// Parses the cache header of the input file directly, so it works before
    /// any module has been loaded. Use the returned paths with `loadModule`.
    public static func listModules() throws(IDAError) -> [DyldCacheModule] {
        var modulesPointer: UnsafeMutablePointer<IdaxDyldCacheModule>? = nil
        var count: Int = 0
        let returnCode = idax_dyld_cache_list_modules(&modulesPointer, &count)
        if returnCode != 0 {
            throw consumeLastError(fallback: "dyldCache.listModules")
        }
        defer { idax_dyld_cache_list_modules_free(modulesPointer, count) }
        guard let modulesPointer, count > 0 else { return [] }
        return (0..<count).map { index in
            let rawModule = modulesPointer[index]
            return DyldCacheModule(
                path: borrowCString(rawModule.path),
                loadAddress: rawModule.load_address
            )
        }
    }

    /// Load one module (image) from the shared cache by its full path.
    ///
    /// - Parameter modulePath: Full path inside the cache, e.g.
    ///   "/usr/lib/libobjc.A.dylib" (see `listModules`).
    public static func loadModule(_ modulePath: String) throws(IDAError) {
        try checkStatus(
            modulePath.withCString { idax_dyld_cache_load_module($0) },
            "dyldCache.loadModule"
        )
    }

    /// Load the shared-cache region that contains `address`.
    ///
    /// The region kind — a module section, branch island, branch mapping,
    /// global offset table, or gap — is detected automatically.
    ///
    /// - Parameter address: Any address that falls inside the desired region.
    public static func loadSection(at address: Address) throws(IDAError) {
        try checkStatus(
            idax_dyld_cache_load_section(address),
            "dyldCache.loadSection"
        )
    }

    /// Load the formatted `dyld_cache_header` structure into the database.
    ///
    /// Requires the initial auto-analysis to have completed.
    public static func loadDyldHeader() throws(IDAError) {
        try checkStatus(
            idax_dyld_cache_load_dyld_header(),
            "dyldCache.loadDyldHeader"
        )
    }

    /// Load every branch-island region from the shared cache.
    ///
    /// - Returns: The number of branch-island regions loaded.
    @discardableResult
    public static func loadBranchIslands() throws(IDAError) -> Int {
        try withOutput("dyldCache.loadBranchIslands", 0) {
            idax_dyld_cache_load_branch_islands($0)
        }
    }

    /// Load every branch-mapping region from the shared cache (iOS 16+).
    ///
    /// - Returns: The number of branch-mapping regions loaded.
    @discardableResult
    public static func loadBranchMappings() throws(IDAError) -> Int {
        try withOutput("dyldCache.loadBranchMappings", 0) {
            idax_dyld_cache_load_branch_mappings($0)
        }
    }

    /// Load every global-offset-table region from the shared cache (iOS 16+).
    ///
    /// - Returns: The number of global-offset-table regions loaded.
    @discardableResult
    public static func loadGlobalOffsetTables() throws(IDAError) -> Int {
        try withOutput("dyldCache.loadGlobalOffsetTables", 0) {
            idax_dyld_cache_load_global_offset_tables($0)
        }
    }

    /// Load every gap region from the shared cache.
    ///
    /// - Returns: The number of gap regions loaded.
    @discardableResult
    public static func loadGaps() throws(IDAError) -> Int {
        try withOutput("dyldCache.loadGaps", 0) {
            idax_dyld_cache_load_gaps($0)
        }
    }
}
