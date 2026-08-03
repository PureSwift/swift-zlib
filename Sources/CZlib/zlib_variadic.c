/* The two entry points that have to be C.
 *
 * Swift cannot define a C variadic function, and cannot usefully define one taking a va_list
 * either, so these stay here permanently rather than being generated as stubs. Only the
 * argument list is what cannot move: the formatting happens here and the result goes straight
 * to gzwrite, which is Swift.
 */

#include "czlib_shim.h"

#include <stdarg.h>
#include <stdio.h>

int gzvprintf(gzFile file, const char *format, va_list va) {
    /* The reference formats into a buffer of the file's own size; a fixed one of the default
     * size is the same thing for every caller that has not asked for something unusual, and
     * vsnprintf tells us when it did not fit rather than overrunning it. */
    char buffer[8192];
    int written = vsnprintf(buffer, sizeof buffer, format, va);

    if (written < 0) {
        return written;
    }

    /* vsnprintf reports what it *would* have written, so a longer result was truncated. The
     * reference truncates here too rather than growing without limit. */
    if ((size_t)written >= sizeof buffer) {
        written = (int)sizeof buffer - 1;
    }

    if (written == 0) {
        return 0;
    }

    return gzwrite(file, buffer, (unsigned)written);
}

int gzprintf(gzFile file, const char *format, ...) {
    va_list va;
    int written;

    va_start(va, format);
    written = gzvprintf(file, format, va);
    va_end(va);

    return written;
}
