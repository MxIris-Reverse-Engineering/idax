/// \file dyld_cache.cpp
/// \brief Implementation of ida::dyld_cache — a programmatic driver for the
///        bundled IDA "dscu" (dyld shared cache utils) plugin.
///
/// IDA 9.4 and newer expose the supported dscu_svc_t API from dscu.h. Older
/// SDKs are supported through the private "$ dscu" netnode protocol that was
/// established by reverse-engineering dscu.dylib.

// Standard library headers must be included before the SDK bridge: the IDA
// SDK's pro.h poisons C stdio identifiers (e.g. `fopen` → `dont_use_fopen`)
// to steer callers towards its own qfile API. Pulling in libc++ headers that
// reference those identifiers afterwards would fail to compile, so <fstream>
// and friends are processed here while the names are still intact.
#include <algorithm>
#include <fstream>
#include <ios>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include "detail/sdk_bridge.hpp"
#if IDA_SDK_VERSION >= 940
#include <dscu.h>
#endif
#include <ida/dyld_cache.hpp>
#include <ida/plugin.hpp>

namespace ida::dyld_cache {

namespace {

// ── dscu protocol constants ─────────────────────────────────────────────

#if IDA_SDK_VERSION < 940
constexpr const char* kDscuPlugin  = "dscu";
constexpr const char* kDscuNetnode = "$ dscu";

// dscu plugin run modes (established by reverse-engineering dscu.dylib).
constexpr std::size_t kModeLoadModule  = 1;  // module path     ← supval key 2
constexpr std::size_t kModeLoadSection = 2;  // region address  ← altval key 3
constexpr std::size_t kModeLoadIsland  = 4;  // branch islands  ← tag 'g'
constexpr std::size_t kModeLoadHeader  = 6;  // dyld header     (no input)
constexpr std::size_t kModeLoadMapping = 7;  // branch mappings ← tag 'h'
constexpr std::size_t kModeLoadGap     = 8;  // gaps            ← tag 'p'
constexpr std::size_t kModeLoadGot     = 9;  // GOTs            ← tag 'f'

// Netnode keys for the single-item modes.
constexpr nodeidx_t kKeyModulePath = 2;  // supval, mode 1
constexpr nodeidx_t kKeyRegionAddr = 3;  // altval, mode 2

// Netnode tags pre-populated to bypass the GUI chooser for "load all" modes.
constexpr uchar kTagIsland  = 'g';  // branch-island slot flags
constexpr uchar kTagMapping = 'h';  // branch-mapping start → flag
constexpr uchar kTagGot     = 'f';  // GOT start → end
constexpr uchar kTagGap     = 'p';  // gap start → end
constexpr uchar kTagRegion  = 'r';  // region-info table (read-only)

// Region type codes stored in the tag 'r' region table.
constexpr std::uint32_t kRegionMapping = 3;
constexpr std::uint32_t kRegionGap     = 4;
constexpr std::uint32_t kRegionGot     = 5;
#endif

// ── small helpers ───────────────────────────────────────────────────────

std::string hex_address(Address address) {
    std::ostringstream stream;
    stream << "0x" << std::hex << address;
    return stream.str();
}

std::uint32_t read_le32(const unsigned char* bytes) {
    return static_cast<std::uint32_t>(bytes[0])
         | (static_cast<std::uint32_t>(bytes[1]) << 8)
         | (static_cast<std::uint32_t>(bytes[2]) << 16)
         | (static_cast<std::uint32_t>(bytes[3]) << 24);
}

std::uint64_t read_le64(const unsigned char* bytes) {
    return static_cast<std::uint64_t>(read_le32(bytes))
         | (static_cast<std::uint64_t>(read_le32(bytes + 4)) << 32);
}

/// Whether `header` carries a well-formed dyld shared cache magic.
///
/// The magic is a 16-byte NUL-padded field: "dyld_v" then a version digit,
/// a space, and an architecture name such as "arm64e". Matching only the
/// "dyld_v" prefix accepts files whose remaining magic bytes are garbage,
/// which then get parsed as a cache.
bool has_dyld_magic(const unsigned char* header) {
    static const char prefix[] = "dyld_v";
    for (std::size_t index = 0; index < 6; ++index) {
        if (header[index] != static_cast<unsigned char>(prefix[index]))
            return false;
    }
    if (header[6] != '0' && header[6] != '1')
        return false;
    if (header[7] != ' ')
        return false;

    bool has_architecture = false;
    bool terminated = false;
    for (std::size_t index = 8; index < 16; ++index) {
        const unsigned char value = header[index];
        if (value == '\0') {
            terminated = true;
            continue;
        }
        // Padding follows the name; nothing may follow the padding.
        if (terminated)
            return false;
        if (value == ' ' && !has_architecture)
            continue;
        const bool is_name_character =
            (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z')
            || (value >= '0' && value <= '9') || value == '_';
        if (!is_name_character)
            return false;
        has_architecture = true;
    }
    return has_architecture;
}

// ── dscu plugin / netnode access ────────────────────────────────────────

Status ensure_available() {
    if (!is_available()) {
        return std::unexpected(Error::unsupported(
            "dyld shared cache utilities are unavailable; the database must "
            "be opened from a dyld shared cache with the 'single module' "
            "option"));
    }
    return ida::ok();
}

#if IDA_SDK_VERSION < 940

/// Open (creating if absent) the "$ dscu" communication netnode.
netnode dscu_netnode() {
    return netnode(kDscuNetnode, 0, /*do_create=*/true);
}

/// Run the dscu plugin with the given mode.
///
/// dscu maps the requested regions and creates the corresponding segments
/// *synchronously* inside load_and_run_plugin. It then queues auto-analysis
/// for the new code. `wait_for_analysis` controls whether to drain that
/// queue before returning. The default (false) avoids what can look like a
/// hang on multi-gigabyte macOS shared caches, where cascading analysis can
/// take tens of minutes.
bool run_dscu(std::size_t mode, bool wait_for_analysis) {
    bool succeeded = ::load_and_run_plugin(kDscuPlugin, mode);
    if (wait_for_analysis)
        ::auto_wait();
    return succeeded;
}

#endif

#if IDA_SDK_VERSION >= 940

/// Return IDA 9.4's public dyld shared cache service for the current database.
dscu_svc_t* dynamic_linker_shared_cache_service() {
    return ::get_dscu_svc();
}

std::size_t load_request_item_count(const dscu_load_request_t& load_request) {
    return load_request.images.size()
         + load_request.islands.size()
         + load_request.mappings.size()
         + load_request.gots.size()
         + load_request.unknown_regions.size()
         + load_request.cache_data.size();
}

bool load_request_is_satisfied(const dscu_svc_t& service,
                               const dscu_load_request_t& load_request) {
    for (int image_index : load_request.images) {
        if (!service.is_image_loaded(image_index))
            return false;
    }
    for (int island_index : load_request.islands) {
        if (!service.is_island_loaded(island_index))
            return false;
    }
    for (ea_t mapping_address : load_request.mappings) {
        if (!service.is_mapping_loaded(mapping_address))
            return false;
    }
    for (ea_t global_offset_table_address : load_request.gots) {
        if (!service.is_got_loaded(global_offset_table_address))
            return false;
    }
    for (ea_t unknown_region_address : load_request.unknown_regions) {
        if (!service.is_unknown_region_loaded(unknown_region_address))
            return false;
    }
    for (ea_t cache_data_address : load_request.cache_data) {
        if (!service.is_cache_data_loaded(cache_data_address))
            return false;
    }
    return true;
}

Result<std::size_t> load_all_service_regions(region_type_t requested_region_type,
                                             bool wait_for_analysis) {
    dscu_svc_t* service = dynamic_linker_shared_cache_service();
    if (service == nullptr) {
        return std::unexpected(Error::unsupported(
            "IDA 9.4 dyld shared cache services are unavailable for the current database"));
    }

    region_info_vec_t all_region_information;
    service->get_regions(&all_region_information);

    dscu_load_request_t load_request(DLRF_DEFAULT);
    for (const region_info_t& region_information : all_region_information) {
        if (region_information.type == requested_region_type)
            load_request.add_region(region_information);
    }

    if (load_request.empty())
        return std::size_t{0};

    if (!service->load_regions(load_request)) {
        return std::unexpected(Error::sdk(
            "IDA 9.4 dscu failed to load the requested dyld shared cache regions"));
    }
    if (wait_for_analysis)
        ::auto_wait();

    if (!load_request_is_satisfied(*service, load_request)) {
        return std::unexpected(Error::sdk(
            "IDA 9.4 dscu reported success but at least one requested region is not loaded"));
    }
    return load_request_item_count(load_request);
}

#endif

// ── DSC input-file parsing ──────────────────────────────────────────────

#if IDA_SDK_VERSION < 940

Result<std::string> input_file_path() {
    char buffer[4096];
    ssize_t length = ::get_input_file_path(buffer, sizeof(buffer));
    if (length <= 0)
        return std::unexpected(Error::not_found("Input file path is unavailable"));
    return std::string(buffer);  // NUL-terminated by the SDK
}

#endif

/// Read a NUL-terminated string from `file` starting at absolute `offset`.
std::string read_file_cstring(std::ifstream& file, std::uint64_t offset,
                              std::size_t max_length = 4096) {
    file.clear();
    file.seekg(static_cast<std::streamoff>(offset));
    std::string result;
    char ch = 0;
    while (result.size() < max_length && file.get(ch)) {
        if (ch == '\0')
            break;
        result.push_back(ch);
    }
    return result;
}

/// Read a fixed-size record from `file` at absolute `offset`.
/// Returns false if the full record could not be read.
bool read_record(std::ifstream& file, std::uint64_t offset,
                 unsigned char* buffer, std::size_t size) {
    file.clear();
    file.seekg(static_cast<std::streamoff>(offset));
    file.read(reinterpret_cast<char*>(buffer),
              static_cast<std::streamsize>(size));
    return file.gcount() == static_cast<std::streamsize>(size);
}

/// Read a NUL-terminated absolute image path from the cache file.
///
/// A cache path is absolute, NUL-terminated and bounded. Anything else means
/// the image table is pointing at something that is not a path, which is a
/// malformed cache rather than an image to skip.
Result<std::string> read_image_path(std::ifstream& file, std::uint64_t offset,
                                    std::uint64_t file_size) {
    constexpr std::size_t kMaximumImagePathLength = 65536;

    if (offset >= file_size) {
        return std::unexpected(Error::validation(
            "Dyld cache image path lies outside the file"));
    }

    file.clear();
    file.seekg(static_cast<std::streamoff>(offset));
    std::string path;
    char character = 0;
    while (path.size() < kMaximumImagePathLength && file.get(character)) {
        if (character != '\0') {
            path.push_back(character);
            continue;
        }
        if (path.empty())
            return std::unexpected(Error::validation("Dyld cache image path is empty"));
        if (path.front() != '/') {
            return std::unexpected(Error::validation(
                "Dyld cache image path is not absolute", path));
        }
        return path;
    }
    return std::unexpected(Error::validation(
        "Dyld cache image path is not NUL-terminated"));
}

#if IDA_SDK_VERSION < 940

/// Read the branch-pool count from the DSC header (uint32 at offset 0x74).
std::uint32_t read_branch_pool_count(const std::string& path) {
    std::ifstream file(path.c_str(), std::ios::binary);
    if (!file.is_open())
        return 0;
    unsigned char header[0x78];
    if (!read_record(file, 0, header, sizeof(header)))
        return 0;
    if (!has_dyld_magic(header))
        return 0;
    return read_le32(header + 0x74);
}

#endif

// ── region table enumeration ────────────────────────────────────────────

#if IDA_SDK_VERSION < 940

struct Region {
    Address start{BadAddress};
    Address end{BadAddress};
};

/// Enumerate the dscu region table (tag 'r'), returning regions of one type.
///
/// Each entry is keyed by (end_address - 1) and stores an IDA-packed blob:
///   pack_dd(version) pack_dq(start) pack_dq(size) pack_dd(type) ...
/// The packed values are decoded with the SDK's own unpack_* primitives so
/// the encoding always matches whatever IDA used to write them.
std::vector<Region> enumerate_regions(std::uint32_t wanted_type) {
    std::vector<Region> regions;
    netnode node = dscu_netnode();

    for (nodeidx_t index = node.supfirst(kTagRegion);
         index != BADNODE;
         index = node.supnext(index, kTagRegion)) {
        uchar buffer[256];
        ssize_t length = node.supval(index, buffer, sizeof(buffer), kTagRegion);
        if (length <= 0)
            continue;

        const uchar* cursor = buffer;
        const uchar* end = buffer + std::min<ssize_t>(length, sizeof(buffer));

        std::uint32_t version = ::unpack_dd(&cursor, end);
        if (version != 1)
            continue;
        std::uint64_t start = ::unpack_dq(&cursor, end);
        (void)::unpack_dq(&cursor, end);  // region size — unused (end from key)
        std::uint32_t type = ::unpack_dd(&cursor, end);
        if (type != wanted_type)
            continue;

        Region region;
        region.start = static_cast<Address>(start);
        region.end   = static_cast<Address>(index) + 1;
        regions.push_back(region);
    }
    return regions;
}

/// Pre-populate `tag` with one (start → end) entry per region of `region_type`,
/// then trigger `mode`. dscu skips its GUI chooser when the tag already holds
/// entries. dscu reports failure in headless mode even on success, so the
/// number of regions that actually produced a segment is returned instead.
Result<std::size_t> load_all_regions(std::uint32_t region_type,
                                     uchar tag, std::size_t mode,
                                     bool wait_for_analysis) {
    if (auto status = ensure_available(); !status)
        return std::unexpected(status.error());

    std::vector<Region> regions = enumerate_regions(region_type);
    if (regions.empty())
        return std::size_t{0};

    netnode node = dscu_netnode();
    for (const Region& region : regions) {
        std::uint64_t end_value = region.end;
        node.supset(static_cast<nodeidx_t>(region.start),
                    &end_value, sizeof(end_value), tag);
    }
    run_dscu(mode, wait_for_analysis);  // result ignored — verified via segment presence below

    std::size_t loaded = 0;
    for (const Region& region : regions) {
        if (::getseg(static_cast<ea_t>(region.start)) != nullptr)
            ++loaded;
    }
    return loaded;
}

#endif

}  // namespace

// ── public API ──────────────────────────────────────────────────────────

bool is_available() {
#if IDA_SDK_VERSION >= 940
    return dynamic_linker_shared_cache_service() != nullptr;
#else
    return ida::plugin::is_plugin_available(kDscuPlugin);
#endif
}

Result<std::vector<ModuleInfo>> list_modules() {
#if IDA_SDK_VERSION >= 940
    dscu_svc_t* service = dynamic_linker_shared_cache_service();
    if (service == nullptr) {
        return std::unexpected(Error::unsupported(
            "IDA 9.4 dyld shared cache services are unavailable for the current database"));
    }

    const int image_count = service->get_images_count();
    if (image_count <= 0)
        return std::unexpected(Error::not_found("No images found in the dyld shared cache"));

    std::vector<ModuleInfo> modules;
    modules.reserve(static_cast<std::size_t>(image_count));
    for (int image_index = 0; image_index < image_count; ++image_index) {
        qstring image_path;
        if (!service->get_image_name(&image_path, image_index))
            continue;

        ModuleInfo module_information;
        module_information.path = ida::detail::to_string(image_path);
        module_information.load_address = static_cast<Address>(
            service->get_image_address(image_index));
        modules.push_back(std::move(module_information));
    }

    if (modules.empty())
        return std::unexpected(Error::not_found("No images found in the dyld shared cache"));
    return modules;
#else
    auto path = input_file_path();
    if (!path)
        return std::unexpected(path.error());

    return list_modules(*path);
#endif
}

Result<std::vector<ModuleInfo>> list_modules(std::string_view cache_path) {
    if (cache_path.empty())
        return std::unexpected(Error::validation("Dyld shared cache path cannot be empty"));
    if (cache_path.find('\0') != std::string_view::npos) {
        return std::unexpected(Error::validation(
            "Dyld shared cache path contains an embedded NUL"));
    }

    std::string cache_path_string(cache_path);

    std::ifstream file(cache_path_string.c_str(), std::ios::binary);
    if (!file.is_open())
        return std::unexpected(Error::not_found(
            "Cannot open the dyld shared cache", cache_path_string));

    file.seekg(0, std::ios::end);
    const auto file_size = static_cast<std::uint64_t>(file.tellg());

    unsigned char header[0x1c8] = {};
    if (!read_record(file, 0, header, 0x20) || !has_dyld_magic(header)) {
        return std::unexpected(Error::validation(
            "Input file is not a dyld shared cache", cache_path_string));
    }

    // The header grows with the cache format, and mappingOffset records how far
    // it actually extends. Fields beyond it are absent, not zero, so the header
    // length decides which image tables may be read at all.
    const std::uint64_t header_size = read_le32(header + 0x10);
    if (header_size < 0x20 || header_size > file_size) {
        return std::unexpected(Error::validation(
            "Invalid dyld cache mapping offset", cache_path_string));
    }
    const std::uint64_t mapping_count = read_le32(header + 0x14);
    if (mapping_count > (file_size - header_size) / 32) {
        return std::unexpected(Error::validation(
            "Dyld cache mapping table exceeds the file", cache_path_string));
    }

    const auto readable_header =
        static_cast<std::size_t>(std::min<std::uint64_t>(sizeof(header), header_size));
    if (!read_record(file, 0, header, readable_header)) {
        return std::unexpected(Error::validation(
            "Cannot read the dyld cache header", cache_path_string));
    }

    // Three image tables can coexist, and the modern one wins. A legacy table
    // often survives as a stale backward-compatibility subset of the real
    // contents, so "whichever is found first" silently truncates the inventory.
    std::uint64_t table_offset = 0;
    std::uint64_t table_count = 0;
    bool text_table = false;
    if (header_size >= 0x1c8) {
        table_offset = read_le32(header + 0x1c0);
        table_count  = read_le32(header + 0x1c4);
    }
    if (table_offset == 0 && table_count == 0) {
        table_offset = read_le32(header + 0x18);
        table_count  = read_le32(header + 0x1c);
    }
    if (table_offset == 0 && table_count == 0 && header_size >= 0x98) {
        table_offset = read_le64(header + 0x88);
        table_count  = read_le64(header + 0x90);
        text_table   = true;
    }

    if ((table_offset == 0) != (table_count == 0)) {
        return std::unexpected(Error::validation(
            "Dyld cache image offset/count pair is inconsistent", cache_path_string));
    }
    // A cache that declares no images is empty, not broken.
    if (table_count == 0)
        return std::vector<ModuleInfo>{};
    if (table_offset < header_size || table_offset > file_size
        || table_count > (file_size - table_offset) / 32) {
        return std::unexpected(Error::validation(
            "Dyld cache image table exceeds the file", cache_path_string));
    }

    // Entry layout is 32 bytes either way:
    //   dyld_cache_image_info:      address[8] modTime[8] inode[8] pathOffset[4] pad[4]
    //   dyld_cache_image_text_info: uuid[16] loadAddress[8] textSize[4] pathOffset[4]
    const std::size_t load_address_field = text_table ? 16 : 0;
    const std::size_t path_offset_field  = text_table ? 28 : 24;

    std::vector<ModuleInfo> modules;
    modules.reserve(static_cast<std::size_t>(table_count));
    for (std::uint64_t index = 0; index < table_count; ++index) {
        unsigned char entry[32];
        if (!read_record(file, table_offset + index * 32, entry, sizeof(entry))) {
            return std::unexpected(Error::validation(
                "Cannot read the dyld cache image table", cache_path_string));
        }

        const std::uint64_t path_offset = read_le32(entry + path_offset_field);
        if (path_offset < header_size) {
            return std::unexpected(Error::validation(
                "Dyld cache image path overlaps its header", cache_path_string));
        }
        auto path = read_image_path(file, path_offset, file_size);
        if (!path)
            return std::unexpected(path.error());

        ModuleInfo info;
        info.path = std::move(*path);
        info.load_address = static_cast<Address>(read_le64(entry + load_address_field));
        modules.push_back(std::move(info));
    }
    return modules;
}

Status load_module(std::string_view module_path, bool wait_for_analysis) {
    if (module_path.empty())
        return std::unexpected(Error::validation("Module path cannot be empty"));
    if (auto status = ensure_available(); !status)
        return status;

#if IDA_SDK_VERSION >= 940
    dscu_svc_t* service = dynamic_linker_shared_cache_service();
    if (service == nullptr) {
        return std::unexpected(Error::unsupported(
            "IDA 9.4 dyld shared cache services are unavailable for the current database"));
    }

    std::string module_path_string(module_path);
    const int image_index = service->get_image_index(module_path_string.c_str());
    if (image_index < 0) {
        return std::unexpected(Error::not_found(
            "Module is not present in the dyld shared cache", module_path_string));
    }
    if (!service->load_image(image_index, DLRF_DEFAULT)) {
        return std::unexpected(Error::sdk(
            "IDA 9.4 dscu failed to load the module", module_path_string));
    }
    if (wait_for_analysis)
        ::auto_wait();
    if (!service->is_image_loaded(image_index)) {
        return std::unexpected(Error::sdk(
            "IDA 9.4 dscu reported success but the module is not loaded",
            module_path_string));
    }
    return ida::ok();
#else
    // dscu mode 1 validates the input path against the cache state's
    // `dyld_cache_image_info` (old-format) list. On modern macOS caches
    // that list is a backward-compat subset of the actual contents — modules
    // that only appear in `dyld_cache_image_text_info` or in subcaches
    // produce `Invalid module: ...` and a false return even when the
    // underlying Mach-O loader would happily load them. To recover the
    // ground truth, look up the expected load address up front and verify
    // success by segment presence (the same pattern as `load_section`).
    auto modules = list_modules();
    if (!modules)
        return std::unexpected(modules.error());

    std::string path(module_path);
    auto entry = std::find_if(
        modules->begin(), modules->end(),
        [&](const ModuleInfo& m) { return m.path == path; });
    if (entry == modules->end())
        return std::unexpected(Error::not_found(
            "Module is not present in the dyld shared cache", path));

    netnode node = dscu_netnode();
    // dscu mode 1 reads the module path from supval key 2 (NUL-terminated).
    node.supset(kKeyModulePath, path.c_str(), path.size() + 1);
    // dscu mode 1 reports failure in headless mode even on success (when the
    // path is only in the new-format image_text_info table), so the outcome
    // is verified by checking for a segment at the module's load address.
    run_dscu(kModeLoadModule, wait_for_analysis);
    if (::getseg(static_cast<ea_t>(entry->load_address)) == nullptr)
        return std::unexpected(Error::sdk("dscu failed to load the module", path));
    return ida::ok();
#endif
}

Status load_section(Address address, bool wait_for_analysis) {
    if (auto status = ensure_available(); !status)
        return status;

#if IDA_SDK_VERSION >= 940
    dscu_svc_t* service = dynamic_linker_shared_cache_service();
    if (service == nullptr) {
        return std::unexpected(Error::unsupported(
            "IDA 9.4 dyld shared cache services are unavailable for the current database"));
    }

    region_info_t region_information;
    if (!service->get_region_by_ea(
            &region_information,
            static_cast<ea_t>(address))) {
        return std::unexpected(Error::not_found(
            "No dyld shared cache region contains the address", hex_address(address)));
    }

    // The IDA 9.4 DSC loader always loads the cache header while creating the
    // initial database, so there is no additional request to perform here.
    if (region_information.type == rt_header) {
        if (wait_for_analysis)
            ::auto_wait();
        return ida::ok();
    }

    dscu_load_request_t load_request(DLRF_DEFAULT);
    load_request.add_region(region_information);
    if (load_request.empty() || !service->load_regions(load_request)) {
        return std::unexpected(Error::sdk(
            "IDA 9.4 dscu failed to load the region", hex_address(address)));
    }
    if (wait_for_analysis)
        ::auto_wait();
    if (!load_request_is_satisfied(*service, load_request)) {
        return std::unexpected(Error::sdk(
            "IDA 9.4 dscu reported success but the region is not loaded",
            hex_address(address)));
    }
    return ida::ok();
#else
    netnode node = dscu_netnode();
    // dscu mode 2 reads the target address from altval key 3.
    node.altset(kKeyRegionAddr, static_cast<uval_t>(address));
    // dscu mode 2 reports failure in headless mode even on success, so the
    // outcome is verified by checking for a segment covering `address`.
    run_dscu(kModeLoadSection, wait_for_analysis);
    if (::getseg(static_cast<ea_t>(address)) == nullptr) {
        return std::unexpected(Error::not_found(
            "No dyld shared cache region was loaded for the address; it may "
            "not belong to any cache region", hex_address(address)));
    }
    return ida::ok();
#endif
}

Status load_dyld_header(bool wait_for_analysis) {
    if (auto status = ensure_available(); !status)
        return status;
#if IDA_SDK_VERSION >= 940
    // IDA 9.4's dedicated DSC loader creates the formatted header as part of
    // the initial database. Preserve the API as an idempotent operation.
    if (wait_for_analysis)
        ::auto_wait();
    return ida::ok();
#else
    if (!run_dscu(kModeLoadHeader, wait_for_analysis)) {
        return std::unexpected(Error::sdk(
            "dscu failed to load the dyld cache header; the initial "
            "auto-analysis must have completed first"));
    }
    return ida::ok();
#endif
}

Result<std::size_t> load_branch_islands(bool wait_for_analysis) {
#if IDA_SDK_VERSION >= 940
    if (auto status = ensure_available(); !status)
        return std::unexpected(status.error());
    return load_all_service_regions(rt_island, wait_for_analysis);
#else
    if (auto status = ensure_available(); !status)
        return std::unexpected(status.error());

    auto path = input_file_path();
    if (!path)
        return std::unexpected(path.error());

    std::uint32_t pool_count = read_branch_pool_count(*path);
    if (pool_count == 0)
        return std::size_t{0};

    netnode node = dscu_netnode();
    std::uint64_t slot_flag = 1;
    for (std::uint32_t index = 0; index < pool_count; ++index) {
        node.supset(static_cast<nodeidx_t>(index),
                    &slot_flag, sizeof(slot_flag), kTagIsland);
    }
    run_dscu(kModeLoadIsland, wait_for_analysis);  // result ignored — headless reports false
    return static_cast<std::size_t>(pool_count);
#endif
}

Result<std::size_t> load_branch_mappings(bool wait_for_analysis) {
#if IDA_SDK_VERSION >= 940
    if (auto status = ensure_available(); !status)
        return std::unexpected(status.error());
    return load_all_service_regions(rt_mapping, wait_for_analysis);
#else
    return load_all_regions(kRegionMapping, kTagMapping, kModeLoadMapping,
                            wait_for_analysis);
#endif
}

Result<std::size_t> load_global_offset_tables(bool wait_for_analysis) {
#if IDA_SDK_VERSION >= 940
    if (auto status = ensure_available(); !status)
        return std::unexpected(status.error());
    return load_all_service_regions(rt_got, wait_for_analysis);
#else
    return load_all_regions(kRegionGot, kTagGot, kModeLoadGot,
                            wait_for_analysis);
#endif
}

Result<std::size_t> load_gaps(bool wait_for_analysis) {
#if IDA_SDK_VERSION >= 940
    if (auto status = ensure_available(); !status)
        return std::unexpected(status.error());
    return load_all_service_regions(rt_unknown, wait_for_analysis);
#else
    return load_all_regions(kRegionGap, kTagGap, kModeLoadGap,
                            wait_for_analysis);
#endif
}

Result<std::size_t> load_cache_data(bool wait_for_analysis) {
#if IDA_SDK_VERSION >= 940
    if (auto status = ensure_available(); !status)
        return std::unexpected(status.error());
    return load_all_service_regions(rt_cache_data, wait_for_analysis);
#else
    static_cast<void>(wait_for_analysis);
    return std::unexpected(Error::unsupported(
        "Cache-wide data regions require IDA SDK 9.4 or newer"));
#endif
}

}  // namespace ida::dyld_cache
