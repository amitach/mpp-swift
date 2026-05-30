// Intentionally a single translation unit so SwiftPM treats CTempoTxFFI as a buildable
// C target rather than erroring on a headers-only target. The real symbols live in
// libtempo_tx_ffi.a, linked by MPPTempoFFI on Linux; this only surfaces the declarations.
#include "tempo_tx_ffiFFI.h"
