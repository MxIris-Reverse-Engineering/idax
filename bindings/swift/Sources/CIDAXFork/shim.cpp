/// \file shim.cpp
/// \brief C transport implementation for this fork's Swift additions.
///
/// Deep-copies every string across the boundary, matching the ownership model
/// of upstream's C transport: the caller frees what it receives.

#include "include/idax_fork.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#include <ida/fork/input_format.hpp>

namespace {

/// Copy a std::string into a malloc'd C string. Returns null on allocation
/// failure, which callers treat as a failed conversion.
char* duplicate(const std::string& text) {
    char* copy = static_cast<char*>(std::malloc(text.size() + 1));
    if (copy == nullptr)
        return nullptr;
    std::memcpy(copy, text.c_str(), text.size() + 1);
    return copy;
}

void release_format_fields(IdaxForkInputFormat& format) {
    std::free(format.name);
    std::free(format.processor);
    std::free(format.loader_path);
    format.name = nullptr;
    format.processor = nullptr;
    format.loader_path = nullptr;
}

} // namespace

extern "C" {

int idax_fork_list_input_formats(const char* path,
                                 IdaxForkInputFormat** out_formats,
                                 size_t* out_count,
                                 char** out_error_message) {
    if (out_formats == nullptr || out_count == nullptr || out_error_message == nullptr)
        return 1;

    *out_formats = nullptr;
    *out_count = 0;
    *out_error_message = nullptr;

    if (path == nullptr) {
        *out_error_message = duplicate("Input file path is null");
        return 1;
    }

    auto formats = ida::database::list_input_formats(path);
    if (!formats) {
        const ida::Error& error = formats.error();
        std::string message = error.message;
        if (!error.context.empty())
            message += " (" + error.context + ")";
        *out_error_message = duplicate(message);
        return 1;
    }

    if (formats->empty())
        return 0;

    auto* array = static_cast<IdaxForkInputFormat*>(
        std::calloc(formats->size(), sizeof(IdaxForkInputFormat)));
    if (array == nullptr) {
        *out_error_message = duplicate("Out of memory while copying input formats");
        return 1;
    }

    for (std::size_t index = 0; index < formats->size(); ++index) {
        const ida::database::InputFormat& source = (*formats)[index];
        IdaxForkInputFormat& target = array[index];
        target.name = duplicate(source.name);
        target.processor = duplicate(source.processor);
        target.loader_path = duplicate(source.loader_path);
        target.archive_loader = source.archive_loader ? 1 : 0;

        if (target.name == nullptr || target.processor == nullptr
            || target.loader_path == nullptr) {
            for (std::size_t undo = 0; undo <= index; ++undo)
                release_format_fields(array[undo]);
            std::free(array);
            *out_error_message = duplicate("Out of memory while copying input formats");
            return 1;
        }
    }

    *out_formats = array;
    *out_count = formats->size();
    return 0;
}

void idax_fork_input_formats_free(IdaxForkInputFormat* formats, size_t count) {
    if (formats == nullptr)
        return;
    for (size_t index = 0; index < count; ++index)
        release_format_fields(formats[index]);
    std::free(formats);
}

void idax_fork_string_free(char* text) {
    std::free(text);
}

} // extern "C"
