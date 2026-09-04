/// \file database_lifecycle.cpp
/// \brief Implementation of ida::database lifecycle functions (idalib-only).
///
/// These functions reference idalib-only symbols (init_library, open_database,
/// close_database, enable_console_messages) that are NOT exported from
/// libida.dylib.  By isolating them in a separate translation unit, plugin
/// link units that reference ida::database query APIs (input_file_path,
/// image_base, etc.) will not pull in these unresolvable symbols.

#include "detail/sdk_bridge.hpp"
#include <ida/database.hpp>

#include <chrono>
#include <filesystem>
#include <system_error>
#include <vector>

namespace ida::database {

namespace {

namespace fs = std::filesystem;

bool should_auto_analysis(OpenMode mode) {
    return mode == OpenMode::Analyze;
}

/// Releases the SDK input handle opened for loader probing.
struct InputHandleGuard {
    linput_t* handle{nullptr};

    explicit InputHandleGuard(linput_t* input_handle) : handle(input_handle) {}

    ~InputHandleGuard() {
        if (handle != nullptr)
            close_linput(handle);
    }

    InputHandleGuard(const InputHandleGuard&) = delete;
    InputHandleGuard& operator=(const InputHandleGuard&) = delete;
};

/// Releases the loader list returned by build_loaders_list().
struct LoadersListGuard {
    load_info_t* list{nullptr};

    explicit LoadersListGuard(load_info_t* loader_list) : list(loader_list) {}

    ~LoadersListGuard() {
        if (list != nullptr)
            free_loaders_list(list);
    }

    LoadersListGuard(const LoadersListGuard&) = delete;
    LoadersListGuard& operator=(const LoadersListGuard&) = delete;
};

bool wildcard_match(std::string_view text, std::string_view pattern) {
    std::size_t text_index = 0;
    std::size_t pattern_index = 0;
    std::size_t star_index = std::string_view::npos;
    std::size_t match_after_star = 0;

    while (text_index < text.size()) {
        if (pattern_index < pattern.size()
            && (pattern[pattern_index] == '?' || pattern[pattern_index] == text[text_index])) {
            ++text_index;
            ++pattern_index;
            continue;
        }

        if (pattern_index < pattern.size() && pattern[pattern_index] == '*') {
            star_index = pattern_index++;
            match_after_star = text_index;
            continue;
        }

        if (star_index != std::string_view::npos) {
            pattern_index = star_index + 1;
            text_index = ++match_after_star;
            continue;
        }

        return false;
    }

    while (pattern_index < pattern.size() && pattern[pattern_index] == '*')
        ++pattern_index;

    return pattern_index == pattern.size();
}

bool matches_any_allowlist_pattern(std::string_view name,
                                   const std::vector<std::string>& patterns) {
    for (const auto& pattern : patterns) {
        if (!pattern.empty() && wildcard_match(name, pattern))
            return true;
    }
    return false;
}

Status set_environment_variable(std::string_view name, std::string_view value) {
    if (!qsetenv(std::string(name).c_str(), std::string(value).c_str())) {
        return std::unexpected(Error::sdk("qsetenv failed",
                                          std::string(name) + "=" + std::string(value)));
    }
    return ida::ok();
}

Status mirror_entry(const fs::path& source, const fs::path& target) {
    std::error_code ec;

    if (fs::exists(target, ec)) {
        fs::remove_all(target, ec);
        ec.clear();
    }

    const bool is_dir = fs::is_directory(source, ec);
    if (ec) {
        return std::unexpected(Error::sdk("is_directory failed",
                                          source.string() + ": " + ec.message()));
    }

    if (is_dir)
        fs::create_directory_symlink(source, target, ec);
    else
        fs::create_symlink(source, target, ec);

    if (!ec)
        return ida::ok();

    // Fallback for platforms/filesystems where symlinks are restricted.
    ec.clear();
    if (is_dir) {
        fs::copy(source,
                 target,
                 fs::copy_options::recursive
                     | fs::copy_options::copy_symlinks
                     | fs::copy_options::overwrite_existing,
                 ec);
    } else {
        fs::copy_file(source, target, fs::copy_options::overwrite_existing, ec);
    }
    if (ec) {
        return std::unexpected(Error::sdk("Failed to mirror IDAUSR entry",
                                          target.string() + ": " + ec.message()));
    }
    return ida::ok();
}

Status configure_user_plugin_policy(const PluginLoadPolicy& policy) {
    const bool requested = policy.disable_user_plugins
                        || !policy.allowlist_patterns.empty();
    if (!requested)
        return ida::ok();

#ifdef _WIN32
    return std::unexpected(Error::unsupported(
        "Plugin policy controls are not implemented on Windows yet"));
#else
    fs::path source_user_dir;

    qstring idausr;
    if (qgetenv("IDAUSR", &idausr) && !idausr.empty()) {
        source_user_dir = fs::path(ida::detail::to_string(idausr));
    } else {
        qstring home;
        if (qgetenv("HOME", &home) && !home.empty()) {
            source_user_dir = fs::path(ida::detail::to_string(home)) / ".idapro";
        }
    }

    std::error_code ec;
    fs::path tmp_base = fs::temp_directory_path(ec);
    if (ec || tmp_base.empty()) {
        ec.clear();
        tmp_base = fs::path("/tmp");
    }

    const auto now = std::chrono::high_resolution_clock::now().time_since_epoch().count();
    fs::path sandbox_root = tmp_base / ("idax_idausr_" + std::to_string(now));
    fs::path sandbox_user = sandbox_root / "user";
    fs::path sandbox_plugins = sandbox_user / "plugins";

    fs::create_directories(sandbox_plugins, ec);
    if (ec) {
        return std::unexpected(Error::sdk("Failed to create plugin sandbox",
                                          sandbox_plugins.string() + ": " + ec.message()));
    }

    if (!source_user_dir.empty() && fs::exists(source_user_dir, ec) && fs::is_directory(source_user_dir, ec)) {
        for (const auto& entry : fs::directory_iterator(source_user_dir, ec)) {
            if (ec) {
                return std::unexpected(Error::sdk("Failed to enumerate IDAUSR",
                                                  source_user_dir.string() + ": " + ec.message()));
            }

            const fs::path name = entry.path().filename();
            if (name == "plugins")
                continue;

            auto mirrored = mirror_entry(entry.path(), sandbox_user / name);
            if (!mirrored)
                return std::unexpected(mirrored.error());
        }

        const fs::path source_plugins = source_user_dir / "plugins";
        if (fs::exists(source_plugins, ec) && fs::is_directory(source_plugins, ec)) {
            const bool has_allowlist = !policy.allowlist_patterns.empty();
            const bool copy_all_plugins = !policy.disable_user_plugins && !has_allowlist;
            for (const auto& entry : fs::directory_iterator(source_plugins, ec)) {
                if (ec) {
                    return std::unexpected(Error::sdk("Failed to enumerate user plugins",
                                                      source_plugins.string() + ": " + ec.message()));
                }

                if (!copy_all_plugins && !has_allowlist)
                    continue;

                const std::string name = entry.path().filename().string();
                if (has_allowlist
                    && !matches_any_allowlist_pattern(name, policy.allowlist_patterns)) {
                    continue;
                }

                auto mirrored = mirror_entry(entry.path(), sandbox_plugins / entry.path().filename());
                if (!mirrored)
                    return std::unexpected(mirrored.error());
            }
        }
    }

    auto set = set_environment_variable("IDAUSR", sandbox_user.string());
    if (!set)
        return std::unexpected(set.error());

    return ida::ok();
#endif
}

Status apply_runtime_options_pre_init(const RuntimeOptions& options) {
    return configure_user_plugin_policy(options.plugin_policy);
}

void apply_runtime_options_post_init(const RuntimeOptions& options) {
    if (options.quiet)
        enable_console_messages(false);
}

} // namespace

// ── Lifecycle (idalib-only) ─────────────────────────────────────────────

Status init(int argc, char* argv[]) {
    return init(argc, argv, RuntimeOptions{});
}

Status init(int argc, char* argv[], const RuntimeOptions& options) {
    auto pre = apply_runtime_options_pre_init(options);
    if (!pre)
        return std::unexpected(pre.error());

    // `init_library` takes the IDA command line — `idat` is nothing but a shell
    // around it. An input format therefore has to arrive here, as a `-T`
    // argument, and it must be present on the single initialisation call: the
    // library cannot be re-initialised to change it later.
    //
    // No quoting is applied. `-T` and its value form one argv entry, and only
    // the command-line *string* form (which IDA splits on whitespace) needs
    // quotes to survive a format name like `Fat Mach-O file, 2. ARM64`.
    std::vector<std::string> argument_storage;
    std::vector<char*> argument_pointers;
    if (!options.input_format.empty()) {
        argument_storage.reserve(static_cast<std::size_t>(argc) + 1);
        for (int index = 0; index < argc; ++index)
            argument_storage.emplace_back(argv[index] != nullptr ? argv[index] : "");
        if (argument_storage.empty())
            argument_storage.emplace_back("idax");
        argument_storage.emplace_back("-T" + options.input_format);

        argument_pointers.reserve(argument_storage.size() + 1);
        for (auto& argument : argument_storage)
            argument_pointers.push_back(argument.data());
        argument_pointers.push_back(nullptr);

        argc = static_cast<int>(argument_storage.size());
        argv = argument_pointers.data();
    }

    int rc = init_library(argc, argv);
    if (rc != 0)
        return std::unexpected(Error::sdk("init_library failed",
                                          "return code: " + std::to_string(rc)));

    apply_runtime_options_post_init(options);
    return ida::ok();
}

Status init(const RuntimeOptions& options) {
    return init(0, nullptr, options);
}

Status open(std::string_view path, bool auto_analysis) {
    if (path.empty())
        return std::unexpected(Error::validation("Database path cannot be empty"));

    qstring qpath = ida::detail::to_qstring(path);
    int rc = open_database(qpath.c_str(), auto_analysis);
    if (rc != 0)
        return std::unexpected(Error::sdk("open_database failed",
                                          std::string(path)));
    return ida::ok();
}

Status open(std::string_view path, OpenMode mode) {
    return open(path, should_auto_analysis(mode));
}

Status open(std::string_view path, LoadIntent intent, OpenMode mode) {
    switch (intent) {
    case LoadIntent::AutoDetect:
        return open(path, mode);
    case LoadIntent::Binary:
        return open_binary(path, mode);
    case LoadIntent::NonBinary:
        return open_non_binary(path, mode);
    }
    return std::unexpected(Error::validation("Invalid load intent"));
}

Status open_binary(std::string_view path, OpenMode mode) {
    // Intent does not select a loader on its own; open_database() detects the
    // format. Name a format through OpenOptions::file_type to control it.
    return open(path, OpenOptions{mode});
}

Status open_non_binary(std::string_view path, OpenMode mode) {
    // Same as open_binary(): the intent is documentation for the caller, not
    // an instruction to IDA.
    return open(path, OpenOptions{mode});
}

Result<std::vector<InputFormat>> list_input_formats(std::string_view path) {
    if (path.empty())
        return std::unexpected(Error::validation("Input file path cannot be empty"));

    qstring qpath = ida::detail::to_qstring(path);

    InputHandleGuard input{open_linput(qpath.c_str(), false)};
    if (input.handle == nullptr) {
        return std::unexpected(Error::sdk("open_linput failed", std::string(path)));
    }

    LoadersListGuard loaders{build_loaders_list(input.handle, qpath.c_str())};

    std::vector<InputFormat> formats;
    for (load_info_t* node = loaders.list; node != nullptr; node = node->next) {
        formats.push_back(InputFormat{
            ida::detail::to_string(node->ftypename),
            ida::detail::to_string(node->processor),
            ida::detail::to_string(node->dllname),
            node->is_archldr(),
        });
    }
    return formats;
}

// `open_database` accepts a third argument string of IDA command-line options,
// and passing `-T"<format>"` there does select the right loader. Do not use it.
// Measured on IDA 9.4: the database opens and saves correctly, but tearing it
// down afterwards aborts the process with `internal error 30500` inside
// `_ida_hexrays.so`, leaving unpacked `.id0`/`.id1`/`.nam`/`.til` files beside
// the input — a database that was never closed cleanly. It reproduces against
// the bare SDK with no idax linked in, on thin files as well as fat ones, and
// neither `close_database` nor the SDK sample's
// `set_database_flag(DBFL_KILL) + term_database()` avoids it.
//
// The format belongs on `init_library`'s argv instead; see
// RuntimeOptions::input_format.
Status open(std::string_view path, const OpenOptions& options) {
    return open(path, should_auto_analysis(options.mode));
}

Status close(bool save_first) {
    close_database(save_first);
    return ida::ok();
}

} // namespace ida::database
