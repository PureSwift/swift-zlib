/* The two entry points that have to be C.
 *
 * Swift cannot define a C variadic function, and cannot usefully define one taking a va_list
 * either, so these stay here permanently rather than being generated as stubs. When the gz
 * write path exists, the formatting happens here and the result is handed to gzwrite; what
 * cannot move to Swift is only the argument list itself.
 */

#include "czlib_shim.h"

#include <stdarg.h>

int gzvprintf(gzFile file, const char *format, va_list va) {
    (void)file;
    (void)format;
    (void)va;

    swiftzlib_report_unimplemented("gzvprintf");
    return Z_STREAM_ERROR;
}

int gzprintf(gzFile file, const char *format, ...) {
    va_list va;
    int written;

    va_start(va, format);
    written = gzvprintf(file, format, va);
    va_end(va);

    return written;
}
