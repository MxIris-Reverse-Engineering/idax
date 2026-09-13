/// \file idax_fork.h
/// \brief C transport for this fork's additions to the IDAX Swift surface.
///
/// Upstream has no equivalent. Kept as a separate module rather than added to
/// upstream's CIDAX umbrella so upstream syncs never conflict here.
///
/// The implementation lives in shim.cpp and forwards to
/// ida::database::list_input_formats (include/ida/fork/input_format.hpp).

#ifndef IDAX_FORK_H
#define IDAX_FORK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One loader IDA is willing to use for an input file.
/// Every string is owned by the array and freed by idax_fork_input_formats_free.
typedef struct {
    char* name;
    char* processor;
    char* loader_path;
    int archive_loader;
} IdaxForkInputFormat;

/// List the formats IDA would offer for `path`, in IDA's own order.
///
/// Requires an initialised library. Returns 0 on success, in which case
/// `*out_formats` and `*out_count` describe an array the caller must release
/// with idax_fork_input_formats_free. A count of zero means no loader
/// recognised the input and leaves `*out_formats` null.
///
/// Returns non-zero on failure and stores a message in `*out_error_message`,
/// which the caller must release with idax_fork_string_free.
int idax_fork_list_input_formats(const char* path,
                                 IdaxForkInputFormat** out_formats,
                                 size_t* out_count,
                                 char** out_error_message);

/// Release an array returned by idax_fork_list_input_formats.
void idax_fork_input_formats_free(IdaxForkInputFormat* formats, size_t count);

/// Release a string returned through an out-parameter of this module.
void idax_fork_string_free(char* text);

#ifdef __cplusplus
}
#endif

#endif // IDAX_FORK_H
