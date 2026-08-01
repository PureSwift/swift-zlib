/* Declarations this library needs among its own parts, and never publishes.
 *
 * Nothing here appears in the export list, so a client cannot reach any of it. It exists
 * because a few things have to be C — reporting a gap to stderr before the Swift runtime is
 * necessarily up, and the variadic entry points Swift cannot define — and those still need to
 * agree with each other about their declarations.
 */

#ifndef SWIFTZLIB_INTERNAL_H
#define SWIFTZLIB_INTERNAL_H

/* Reports that an exported entry point is not implemented yet.
 *
 * Written to stderr once per distinct name, so a program calling one in a loop says so once
 * rather than drowning its own output. The call still returns the library's normal error value
 * afterwards: a diagnostic a caller cannot see in its own error handling is not a contract.
 */
void swiftzlib_report_unimplemented(const char *name);

#endif /* SWIFTZLIB_INTERNAL_H */
