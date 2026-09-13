/// \file fork/input_format.hpp
/// \brief Loader inventory for an input file — fork-only addition.
///
/// Upstream `19h/idax` has no equivalent. Everything under `include/ida/fork/`
/// belongs to this fork and is deliberately kept out of the `<ida/idax.hpp>`
/// umbrella so upstream syncs never touch it. Include this header explicitly.
///
/// A selected format reaches IDA as a `-T` entry on the initialisation command
/// line, not as a structured option: `init_library` takes the IDA command line,
/// and the format must be present on that single call. Passing it later through
/// `open_database`'s argument string selects the right loader but corrupts
/// teardown.
///
/// Example — pick the arm64 slice of a universal Mach-O:
/// ```cpp
/// #include <ida/fork/input_format.hpp>
///
/// auto formats = ida::database::list_input_formats("/bin/ls");
/// if (formats) {
///     std::string selected;
///     for (const auto& format : *formats) {
///         if (format.processor == "arm")
///             selected = "-T" + format.name;
///     }
///     std::vector<char*> arguments{const_cast<char*>("idax"),
///                                  selected.data()};
///     ida::database::init(static_cast<int>(arguments.size()), arguments.data());
/// }
/// ```

#ifndef IDAX_FORK_INPUT_FORMAT_HPP
#define IDAX_FORK_INPUT_FORMAT_HPP

#include <ida/error.hpp>
#include <string>
#include <string_view>
#include <vector>

namespace ida::database {

/// A loader IDA is willing to use for a given input file.
///
/// A universal ("fat") Mach-O yields one entry per architecture slice, in the
/// order the slices appear in the file. Opening such a file without naming a
/// format selects the first entry, which for Apple's toolchain is x86_64 —
/// `lipo` orders slices by CPU type, placing x86_64 ahead of arm64.
struct InputFormat {
    /// Name IDA displays for this format, carrying its own ordinal for
    /// multi-slice inputs (for example `Fat Mach-O file, 2. ARM64e-pauth1`).
    /// Prefix it with `-T` and pass that as one initialisation argument to
    /// select it; no parsing or renumbering is needed or correct.
    std::string name;
    /// Processor module this format wants (for example `arm`, `metapc`).
    std::string processor;
    /// Loader module that produced this entry.
    std::string loader_path;
    /// True when the loader treats the input as an archive of members.
    bool archive_loader{false};
};

/// List the formats IDA would offer for \p path, in IDA's own order.
///
/// Requires an initialised library — call init() first. Returns an empty list
/// when no loader recognises the input.
Result<std::vector<InputFormat>> list_input_formats(std::string_view path);

} // namespace ida::database

#endif // IDAX_FORK_INPUT_FORMAT_HPP
