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

/* What zutil.h defines for the reference's own build, for the same reason: if the build sets
 * _FILE_OFFSET_BITS=64 — as 32-bit targets do — zlib.h would otherwise enter Z_WANT64 mode and
 * rename gztell to gztell64 out from under the definitions here. The library defines both names
 * separately, so it must see both undisturbed.
 */
#ifndef ZLIB_INTERNAL
#define ZLIB_INTERNAL
#endif

#ifndef _LARGEFILE64_SOURCE
#define _LARGEFILE64_SOURCE 1
#endif

/* Z_LARGE64 makes zlib.h spell the *64 declarations in terms of off64_t, a name Glibc and
 * Bionic provide. Darwin never had it, its off_t having always been 64-bit, so the typedef is
 * supplied. So is musl's: musl spells it as a macro over off_t, which a prebuilt module can
 * hide — and `typedef off_t off64_t` is right in every case, being an identical redeclaration
 * where the macro is visible and the missing definition where it is not.
 */
#include <sys/types.h>
#if defined(__APPLE__)
typedef long long off64_t;
#elif defined(__linux__) && !defined(__GLIBC__) && !defined(__ANDROID__)
typedef off_t off64_t;
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
