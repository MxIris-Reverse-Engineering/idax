// SPM requires at least one source file per target.
// The actual shim is pre-built (libidax_shim.a) and linked via linkerSettings.
//
// Stub definitions for IDA SDK data symbols referenced by libidax.a.
// With -undefined dynamic_lookup (flat namespace), the first image to
// define a symbol wins.  These stubs are loaded before the real IDA
// libraries, so all code — including IDA's own initialisation — reads
// and writes these addresses.  When Database.initialize() triggers
// init_library(), IDA sets callui/dbg/etc. on these same locations,
// making the real values available to libidax.a transparently.
//
// Without IDA installed the stubs stay NULL/zero and the binary loads
// without crashing.  IDARuntime.isAvailable lets callers detect this.

#include <stddef.h>

void *callui = NULL;
void *dbg = NULL;
int under_debugger = 0;
