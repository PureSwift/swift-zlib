/* The header as this library's own parts must see it.
 *
 * zlib.h declares the *64 entry points — adler32_combine64, crc32_combine64,
 * crc32_combine_gen64, gzopen64, gzseek64, gztell64, gzoffset64 — only under Z_LARGE64 or
 * Z_WANT64, but the reference build exports them unconditionally, so a drop-in has to define
 * them whether or not the client asked for large-file declarations.
 *
 * Z_LARGE64 alone is what is wanted here: it declares the *64 names without Z_WANT64's macro
 * renaming, which would redirect adler32_combine to adler32_combine64 and leave the unsuffixed
 * symbol undefined. Both names are separately exported, so both must be separately defined.
 *
 * This header is for building this library. Clients still get zlib.h, unmodified, and the
 * declarations they see are unaffected by anything here.
 */

#ifndef SWIFTZLIB_SHIM_H
#define SWIFTZLIB_SHIM_H

#ifndef _LARGEFILE64_SOURCE
#define _LARGEFILE64_SOURCE 1
#endif

/* Z_LARGE64 makes zlib.h spell the *64 declarations in terms of off64_t, which is a glibc and
 * Bionic name: Darwin and musl never had a separate 64-bit off_t because their off_t always
 * was one. Supplying the typedef here is what lets those platforms compile the same
 * declarations — and on musl it is at worst an identical redeclaration, which C11 permits.
 */
#include <sys/types.h>
#if defined(__APPLE__) || (defined(__linux__) && !defined(__GLIBC__) && !defined(__ANDROID__))
typedef long long off64_t;
#endif

/* Defined with no value, exactly as zconf.h defines it for itself when the platform has
 * large-file support. An identical redefinition is allowed; `#define Z_LARGE64 1` would not be,
 * and warns. The definition is still needed here for platforms where zconf.h would not reach
 * it, because the *64 symbols are exported regardless of what the platform supports.
 */
#ifndef Z_LARGE64
#define Z_LARGE64
#endif

#include "zlib.h"

#endif /* SWIFTZLIB_SHIM_H */
