<!-- Fork-local records. See .agents/fork/README.md. -->

# Api Catalog (fork)

Entries this fork added to `.agents/api_catalog.md`, moved here so that file can track
upstream byte for byte. Numbering is whatever it was before the move; it is
independent of upstream's, which is exactly why these live in a separate file
— upstream's Phase 23 is an ida-trida port, ours was the Swift dyld cache
tool, and both had claimed `P23.1`.

---

- Hex-Rays event subscriptions including popup-population callbacks for dynamic decompiler menus
### 17.25 `ida::database` extensions
- 通过 `save_to` 显式保存到指定输出路径，并保持 Swift `Database.save(to:)`、Node `database.saveTo` 与 Rust `database::save_to` 的接口一致性
- `ProcessorId` enum + typed `processor()` helper
- `ProcessorId` tracks full current SDK `PLFM_*` coverage (through `PLFM_MCORE`)
### 17.26 `ida::dyld_cache`
- Programmatic driver for IDA's bundled "dscu" (dyld shared cache utils) plugin
- Availability probe (`is_available`) — gated on a database opened from a dyld shared cache with the "single module" option
- Module enumeration (`list_modules`) via direct DSC header parsing (old `image_info` + newer `image_text_info` layouts)
- Pre-open cache-file enumeration (`list_modules(cache_path)`) with Swift `DyldCache.listModules(in:)` parity，用于在 database 打开前解析 image name
- Single-item loading: `load_module`, `load_section` (auto-detected region kind), `load_dyld_header`
- Bulk loading: `load_branch_islands`, `load_branch_mappings`, `load_global_offset_tables`, `load_gaps`, `load_cache_data` — IDA 9.4 uses the public `dscu_svc_t` region service; IDA 9.3 source builds retain the headless legacy dscu backend, and `load_cache_data` reports Unsupported there
- Companion `ida::plugin` invocation helpers: `is_plugin_available`, `run_plugin` (wrap SDK `find_plugin` / `load_and_run_plugin`)
