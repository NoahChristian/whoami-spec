/*
 * whoami_core.h - the parts of a whoami report that are not platform-specific.
 *
 * SPDX-License-Identifier: MIT
 *
 * WHY THIS EXISTS, STATED PLAINLY. The format was implemented three times by
 * hand before this file was written, and all three implementations then
 * turned out to share a defect: each did I/O on the request path. One of them
 * did a 31 KB flash CRC on every call to an ungated HTTP endpoint. The bug was
 * not in any of the three -- it was in writing the same structure three times
 * and hoping the copies would stay right.
 *
 * A specification that only describes OUTPUT leaves the structure to be
 * rebuilt per board. This file is the structure. Everything the spec mandates
 * -- the frozen preamble, the 11-column grid, the appid grammar, the
 * negotiation decision, the required-field order -- happens here, once.
 *
 * PLATFORM-FREE, AND THAT IS A RULE, NOT A DESCRIPTION. Standard C only: no
 * RTOS, no vendor SDK, no allocation, no printf of its own. It cannot read a
 * reset reason or an image header, because those differ per platform and are
 * exactly what the caller is for.
 *
 * THE SEAM IS ONE CALLBACK. The caller supplies emit(), which writes one
 * finished line. A Zephyr implementation passes shell_print; an Arduino one
 * passes Serial.println; an HTTP one appends to a buffer. The core never
 * learns which.
 *
 * WHAT THE CALLER STILL OWNS: every value in the struct below, and any extra
 * fields it wants after the required ones. Extras are emitted by the caller,
 * after whoami_render() returns, using whoami_field() so they land in the same
 * grid.
 */
#ifndef WHOAMI_CORE_H
#define WHOAMI_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The schema this core implements. A caller does not get to disagree: the
 * core emits the preamble, so the version in a report is the version of the
 * code that produced it rather than a constant someone remembered to bump. */
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
 * NOTHING HERE IS FETCHED BY THE CORE, deliberately. The caller assembles
 * these once, at init, from whatever its platform uses -- and that is where
 * the three-implementations bug came from: values that look free to read
 * (an image header, a crash-dump CRC) are flash I/O, and doing them per
 * request put flash work on the service path of a board that was already
 * busy. A struct of ready values makes the cheap thing the easy thing.
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
};

/*
 * Build the appid line, padded into the grid, without a trailing newline.
 *
 * This is also what a standalone `appid` command should print, so that the
 * command and the report's line are the same bytes rather than two spellings
 * that agree until one is edited.
 *
 * Returns the length written, or a negative value if it did not fit.
 */
int whoami_appid_line(char *buf, size_t cap, const struct whoami_info *info);

/*
 * Emit one grid-formatted line. For the caller's own extra fields, so they
 * sit in the same columns as the required ones.
 *
 * A label of 11 characters or more is refused rather than silently widening
 * the grid, because a widened grid is a format change that no reader was
 * told about.
 */
void whoami_field(whoami_emit_fn emit, void *ctx,
		  const char *label, const char *value);

/*
 * Emit the preamble and, if the caller may read it, the required fields.
 *
 * `requested_major` is what the caller asked for: the major from
 * `whoami <major>`, or WHOAMI_CORE_MAJOR for a bare request.
 *
 * Returns 1 when the body was emitted, so the platform knows whether to go on
 * and emit its own extras. Returns 0 when the request was for a major this
 * core cannot speak -- the preamble has still been emitted, which is the
 * conformant refusal, and the caller must emit nothing further.
 *
 * THAT RETURN VALUE IS THE NEGOTIATION. Putting it here rather than in each
 * platform is the point: "answer in the major you were asked for, or answer
 * with the preamble alone" is a rule about the protocol, not about a board,
 * and a board that gets it wrong hands a caller a body it has already said it
 * cannot parse.
 */
int whoami_render(whoami_emit_fn emit, void *ctx,
		  const struct whoami_info *info, int requested_major);

#ifdef __cplusplus
}
#endif

#endif /* WHOAMI_CORE_H */
