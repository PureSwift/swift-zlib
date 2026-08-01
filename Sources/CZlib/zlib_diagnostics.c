/* Reporting a gap in the API surface.
 *
 * C rather than Swift because a stub is the one thing that must work when nothing else does,
 * including before or after the Swift runtime is in a state to format a string.
 */

#include "zlib_internal.h"

#include <stdio.h>
#include <string.h>

/* Names already reported, so a call in a loop says so once.
 *
 * The pointers stored are the string literals the generated stubs pass, which live for the
 * life of the program, so nothing here owns or copies them. A fixed table with no eviction is
 * enough: there are 88 exported symbols, so it cannot be outgrown.
 */
#define SWIFTZLIB_MAX_REPORTED 128

static const char *reported[SWIFTZLIB_MAX_REPORTED];
static int reported_count = 0;

void swiftzlib_report_unimplemented(const char *name) {
    for (int i = 0; i < reported_count; i++) {
        if (strcmp(reported[i], name) == 0) {
            return;
        }
    }

    if (reported_count < SWIFTZLIB_MAX_REPORTED) {
        reported[reported_count++] = name;
    }

    fprintf(stderr,
            "swift-zlib: %s is not implemented yet; returning an error.\n",
            name);
    fflush(stderr);
}
