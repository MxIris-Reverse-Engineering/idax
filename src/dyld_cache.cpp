/// \file dyld_cache.cpp
/// \brief Implementation of ida::dyld_cache — a programmatic driver for the
///        bundled IDA "dscu" (dyld shared cache utils) plugin.
///
/// The dscu plugin is controlled through a private netnode named "$ dscu":
/// inputs are staged into specific netnode keys/tags, then one of the
/// plugin's numeric run modes is triggered via load_and_run_plugin. The
/// protocol and the region-table format used below were established by
/// reverse-engineering dscu.dylib.

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
#include <ida/dyld_cache.hpp>
#include <ida/plugin.hpp>

namespace ida::dyld_cache {

namespace {

// ── dscu protocol constants ─────────────────────────────────────────────

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

/// Whether `header` starts with the dyld shared cache magic ("dyld_v...").
bool has_dyld_magic(const unsigned char* header) {
    static const char magic[] = "dyld_v";
    for (std::size_t i = 0; i < 6; ++i) {
        if (header[i] != static_cast<unsigned char>(magic[i]))
            return false;
    }
    return true;
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

/// Open (creating if absent) the "$ dscu" communication netnode.
netnode dscu_netnode() {
    return netnode(kDscuNetnode, 0, /*do_create=*/true);
}

/// Run the dscu plugin with the given mode, then drain auto-analysis so the
/// newly mapped regions are fully analysed before control returns.
bool run_dscu(std::size_t mode) {
    bool succeeded = ::load_and_run_plugin(kDscuPlugin, mode);
    ::auto_wait();
    return succeeded;
}

// ── DSC input-file parsing ──────────────────────────────────────────────

Result<std::string> input_file_path() {
    char buffer[4096];
    ssize_t length = ::get_input_file_path(buffer, sizeof(buffer));
    if (length <= 0)
        return std::unexpected(Error::not_found("Input file path is unavailable"));
    return std::string(buffer);  // NUL-terminated by the SDK
}

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

/// Parse the old-format dyld_cache_image_info array. Each 32-byte entry is
/// address[8] modTime[8] inode[8] pathFileOffset[4] pad[4].
std::vector<ModuleInfo> parse_image_info(std::ifstream& file,
                                         std::uint32_t offset,
                                         std::uint32_t count) {
    std::vector<ModuleInfo> modules;
    for (std::uint32_t index = 0; index < count; ++index) {
        unsigned char entry[32];
        if (!read_record(file, std::uint64_t{offset} + std::uint64_t{index} * 32,
                          entry, sizeof(entry)))
            break;
        ModuleInfo info;
        info.load_address = static_cast<Address>(read_le64(entry));
        info.path = read_file_cstring(file, read_le32(entry + 0x18));
        modules.push_back(std::move(info));
    }
    return modules;
}

/// Parse the newer dyld_cache_image_text_info array. Each 32-byte entry is
/// uuid[16] loadAddress[8] textSegmentSize[4] pathOffset[4].
std::vector<ModuleInfo> parse_image_text_info(std::ifstream& file,
                                              std::uint64_t offset,
                                              std::uint64_t count) {
    std::vector<ModuleInfo> modules;
    for (std::uint64_t index = 0; index < count; ++index) {
        unsigned char entry[32];
        if (!read_record(file, offset + index * 32, entry, sizeof(entry)))
            break;
        ModuleInfo info;
        info.load_address = static_cast<Address>(read_le64(entry + 0x10));
        info.path = read_file_cstring(file, read_le32(entry + 0x1C));
        modules.push_back(std::move(info));
    }
    return modules;
}

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

// ── region table enumeration ────────────────────────────────────────────

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
                                     uchar tag, std::size_t mode) {
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
    run_dscu(mode);  // result ignored — verified via segment presence below

    std::size_t loaded = 0;
    for (const Region& region : regions) {
        if (::getseg(static_cast<ea_t>(region.start)) != nullptr)
            ++loaded;
    }
    return loaded;
}

}  // namespace

// ── public API ──────────────────────────────────────────────────────────

bool is_available() {
    return ida::plugin::is_plugin_available(kDscuPlugin);
}

Result<std::vector<ModuleInfo>> list_modules() {
    auto path = input_file_path();
    if (!path)
        return std::unexpected(path.error());

    std::ifstream file(path->c_str(), std::ios::binary);
    if (!file.is_open())
        return std::unexpected(Error::not_found("Cannot open the input file", *path));

    unsigned char header[0x98] = {};
    file.read(reinterpret_cast<char*>(header), sizeof(header));
    std::streamsize header_size = file.gcount();
    if (header_size < 0x20)
        return std::unexpected(Error::validation(
            "Input file is too small to be a dyld shared cache", *path));
    if (!has_dyld_magic(header))
        return std::unexpected(Error::validation(
            "Input file is not a dyld shared cache", *path));

    // Strategy 1: old dyld_cache_image_info array (uint32 offset/count @ 0x18).
    std::vector<ModuleInfo> modules;
    std::uint32_t images_offset = read_le32(header + 0x18);
    std::uint32_t images_count  = read_le32(header + 0x1C);
    if (images_offset > 0 && images_count > 0) {
        modules = parse_image_info(file, images_offset, images_count);
    } else if (header_size >= 0x98) {
        // Strategy 2: dyld_cache_image_text_info array (uint64 offset/count @ 0x88).
        std::uint64_t text_offset = read_le64(header + 0x88);
        std::uint64_t text_count  = read_le64(header + 0x90);
        if (text_offset > 0 && text_count > 0 && text_count < 0x100000)
            modules = parse_image_text_info(file, text_offset, text_count);
    }

    if (modules.empty())
        return std::unexpected(Error::not_found(
            "No images found in the dyld shared cache header", *path));
    return modules;
}

Status load_module(std::string_view module_path) {
    if (module_path.empty())
        return std::unexpected(Error::validation("Module path cannot be empty"));
    if (auto status = ensure_available(); !status)
        return status;

    std::string path(module_path);
    netnode node = dscu_netnode();
    // dscu mode 1 reads the module path from supval key 2 (NUL-terminated).
    node.supset(kKeyModulePath, path.c_str(), path.size() + 1);
    if (!run_dscu(kModeLoadModule))
        return std::unexpected(Error::sdk("dscu failed to load the module", path));
    return ida::ok();
}

Status load_section(Address address) {
    if (auto status = ensure_available(); !status)
        return status;

    netnode node = dscu_netnode();
    // dscu mode 2 reads the target address from altval key 3.
    node.altset(kKeyRegionAddr, static_cast<uval_t>(address));
    // dscu mode 2 reports failure in headless mode even on success, so the
    // outcome is verified by checking for a segment covering `address`.
    run_dscu(kModeLoadSection);
    if (::getseg(static_cast<ea_t>(address)) == nullptr) {
        return std::unexpected(Error::not_found(
            "No dyld shared cache region was loaded for the address; it may "
            "not belong to any cache region", hex_address(address)));
    }
    return ida::ok();
}

Status load_dyld_header() {
    if (auto status = ensure_available(); !status)
        return status;
    if (!run_dscu(kModeLoadHeader)) {
        return std::unexpected(Error::sdk(
            "dscu failed to load the dyld cache header; the initial "
            "auto-analysis must have completed first"));
    }
    return ida::ok();
}

Result<std::size_t> load_branch_islands() {
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
    run_dscu(kModeLoadIsland);  // result ignored — headless reports false
    return static_cast<std::size_t>(pool_count);
}

Result<std::size_t> load_branch_mappings() {
    return load_all_regions(kRegionMapping, kTagMapping, kModeLoadMapping);
}

Result<std::size_t> load_global_offset_tables() {
    return load_all_regions(kRegionGot, kTagGot, kModeLoadGot);
}

Result<std::size_t> load_gaps() {
    return load_all_regions(kRegionGap, kTagGap, kModeLoadGap);
}

}  // namespace ida::dyld_cache
