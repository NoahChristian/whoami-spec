/*
 * whoami_core.h - emitting a whoami report, minus anything platform-specific.
 *
 * SPDX-License-Identifier: MIT
 *
 * WHY THIS EXISTS, STATED PLAINLY. The format was implemented three times by
 * hand before this file was written, and all three then turned out to share a
 * defect: each did I/O on the request path. One did a 31 KB flash CRC on every
 * call to an ungated HTTP endpoint. The bug was not in any of the three -- it
 * was in writing the same structure three times and hoping the copies stayed
 * right.
 *
 * A specification that describes only OUTPUT leaves the structure to be rebuilt
 * per board, and a rebuilt structure is a re-derived set of bugs. The
 * conformance checker catches format drift; it cannot catch three
 * implementations being independently expensive, because expensive is
 * conformant.
 *
 * PLATFORM-FREE, AND THAT IS A RULE, NOT A DESCRIPTION. Standard C only: no
 * RTOS, no vendor SDK, no allocation, no I/O of its own. It cannot read a reset
 * reason or an image header, because those differ per platform and are exactly
 * what the caller supplies.
 *
 * THE SEAM IS ONE CALLBACK. The caller supplies emit(), which writes one
 * finished line. Zephyr passes shell_print, Arduino passes Serial.println, an
 * HTTP handler appends to a buffer. The core never learns which.
 *
 * Reading a report is whoami_parse.h. This header only writes them.
 */
#ifndef WHOAMI_CORE_H
#define WHOAMI_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The schema this core emits. The core writes the preamble itself, so the
 * version in a report is the version of the code that produced it rather than
 * a constant someone remembered to bump. */
#define WHOAMI_CORE_SCHEMA "1.0005"
#define WHOAMI_CORE_MAJOR  1

/* Columns 1-11 hold the label, value from column 12. SPEC.md "Grammar". */
#define WHOAMI_CORE_GRID   11

/* One finished line, no trailing newline. */
typedef void (*whoami_emit_fn)(void *ctx, const char *line);

/*
 * Everything the required fields need. All strings are borrowed for the
 * duration of the call and are never stored.
 *
 * NOTHING HERE IS FETCHED BY THE CORE, deliberately. The caller assembles these
 * once, at init -- and that is where the three-implementations bug came from:
 * values that look free to read (an image header, a crash-dump CRC) are flash
 * I/O, and doing them per request put flash work on the service path of a board
 * that was already busy. A struct of ready values makes the cheap thing the
 * easy thing.
 */
struct whoami_info {
	const char *token;    /* registered appid token; see tokens.example.txt */
	int         unit;     /* physical unit number, or < 0 to omit the field */
	const char *fw;       /* firmware version, emitted last on the appid line */
	const char *project;  /* human-readable name */
	const char *board;    /* build target or hardware identifier */
	const char *built;    /* when THIS firmware was compiled */
	const char *uptime;   /* preformatted; the core does no time arithmetic */
	const char *attest;   /* capability list; "none" is valid and common */

	/*
	 * Every major this DEVICE can emit, ascending. NULL means "this core's
	 * major only", which is the common case and needs no array.
	 *
	 * Declaring a major costs nothing and is not a promise this core can
	 * produce it -- see whoami_render()'s -1 return. It is how a reader that
	 * has fallen behind finds out, instead of never learning.
	 */
	const int  *speaks;
	size_t      speaks_count;
};

/*
 * Build the appid line, padded into the grid, without a trailing newline.
 *
 * This is also what a standalone `appid` command should print, so the command
 * and the report's line are the same bytes rather than two spellings that agree
 * until one is edited.
 *
 * Returns the length written, or negative if it did not fit.
 */
int whoami_appid_line(char *buf, size_t cap, const struct whoami_info *info);

/*
 * Emit one grid-formatted line. For the caller's own extra fields, so they sit
 * in the same columns as the required ones.
 *
 * A label of WHOAMI_CORE_GRID characters or more is refused rather than
 * silently widening the grid, because a widened grid is a format change that no
 * reader was told about.
 */
void whoami_field(whoami_emit_fn emit, void *ctx,
		  const char *label, const char *value);

/*
 * Emit a special block: the `special <count> <tag>` header, then count lines
 * verbatim.
 *
 * Content is opaque by design -- no grid, no escaping, no structure. The count
 * is the only thing a reader needs, which is what turns an unknown block from a
 * desync into a shrug. A reader that does not know the tag skips count lines
 * and continues.
 *
 * NOTHING IN A BLOCK MAY BE LOAD-BEARING. If an implementation needs a reader
 * to act on something, that belongs in a field and in a major version. A block
 * is how you say something; it is not how you agree on something.
 *
 * Returns 1 if emitted. Returns 0 WITHOUT EMITTING ANYTHING if the tag is
 * malformed or the count is implausible -- a half-written block is worse than
 * none, because its header has already told the reader how far to skip.
 */
int whoami_special(whoami_emit_fn emit, void *ctx, const char *tag,
		   const char *const *lines, size_t count);

/*
 * Emit the preamble and, if the caller may read it, the required fields.
 *
 * requested_major is what the caller asked for: the major from
 * `whoami <major>`, or WHOAMI_CORE_MAJOR for a bare request.
 *
 * Returns:
 *    1  body emitted in this core's major. The platform may now emit its own
 *       extras and special blocks.
 *    0  REFUSED: the requested major is not in speaks. The preamble has been
 *       emitted, which is the conformant refusal, and the caller must emit
 *       nothing further.
 *   -1  the requested major IS declared in speaks but is not the one this core
 *       emits. The preamble has been emitted; the caller owns the body for that
 *       major. A device that declares only its own major never sees this.
 *
 * THAT RETURN VALUE IS THE NEGOTIATION, and it lives here rather than in each
 * platform because "answer in the major you were asked for, or answer with the
 * preamble alone" is a rule about the protocol, not about a board. A board that
 * gets it wrong hands a caller a body it has already said it cannot parse --
 * which SPEC.md calls the violation, not a lenient kindness.
 */
int whoami_render(whoami_emit_fn emit, void *ctx,
		  const struct whoami_info *info, int requested_major);

#ifdef __cplusplus
}
#endif

#endif /* WHOAMI_CORE_H */
