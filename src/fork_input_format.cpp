/// \file fork_input_format.cpp
/// \brief Implementation of ida::database::list_input_formats (fork-only).
///
/// Kept in its own translation unit so upstream syncs never conflict here.
/// See include/ida/fork/input_format.hpp and
/// docs/fork/evolutions/draft-shrink-fork-to-cli.md.

// Load standard headers before the SDK's forbidden-I/O macro definitions.
#include <string>
#include <vector>

#include "detail/sdk_bridge.hpp"
#include <ida/fork/input_format.hpp>

namespace ida::database {

namespace {

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

} // namespace

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

} // namespace ida::database
