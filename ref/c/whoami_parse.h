/*
 * whoami_parse.h - reading a whoami report, safely, on a constrained device.
 *
 * SPDX-License-Identifier: MIT
 *
 * A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
 * Every number in it is therefore input, not instruction -- including the
 * counts that say how far to read. SPEC.md "Reading one safely" is the contract
 * this file implements, and the shape of all of it is: the format tells a
 * reader how far to read, and the reader decides how far it is willing to.
 * Both halves are required. A length you trust without a bound is not a safety
 * feature, it is an instruction.
 *
 * NO ALLOCATION, NO I/O, NO COPIES. The caller owns the buffer holding the
 * report and it must stay alive while the result is used: every value points
 * into it. This runs on the same boards the emitter does, where a reader that
 * mallocs per field is not an option.
 *
 * NOT A VALIDATOR. It answers "what does this say", bounded and without
 * trusting it. Whether a report is CONFORMANT is a separate question, and a
 * stricter one -- tools/whoami_check.py answers that. Keeping them apart
 * matters because a reader in the field must cope with a report it would also
 * have reported as non-conformant.
 */
#ifndef WHOAMI_PARSE_H
#define WHOAMI_PARSE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Columns 1 to WHOAMI_GRID hold the label; the value starts after it. A line is
 * split by SLICE, which is what lets a label contain a space (`front end`). */
#define WHOAMI_GRID         11

/* Bounds. Every one of these exists so a hostile or broken far end cannot make
 * a reader work harder than the reader chose to. */
#define WHOAMI_MAX_LINES    500   /* total, so a looping device fails the read */
#define WHOAMI_MAX_SPECIAL  100   /* lines skipped for one block */
#define WHOAMI_MAX_SPEAKS    16   /* majors recorded from the speaks line */
#define WHOAMI_MAX_FIELDS    64   /* fields recorded; the rest are counted only */
#define WHOAMI_PREAMBLE_MAX 512   /* bytes before the preamble must have landed */

enum whoami_status {
	WHOAMI_OK = 0,
	WHOAMI_E_EMPTY,        /* nothing to read */
	WHOAMI_E_PREAMBLE,     /* first two lines are not schema/speaks */
	WHOAMI_E_SCHEMA,       /* schema value is not <major>.<4 digits> */
	WHOAMI_E_TOO_LONG,     /* past WHOAMI_MAX_LINES, or preamble too far in */
	WHOAMI_E_SPECIAL       /* a block count past WHOAMI_MAX_SPECIAL */
};

/* A borrowed slice of the caller's buffer. Not NUL-terminated: a report read
 * off a wire has no spare bytes to write terminators into, and copying to get
 * them is the allocation this file exists to avoid. */
struct whoami_str {
	const char *p;
	size_t      len;
};

struct whoami_field {
	struct whoami_str label;
	struct whoami_str value;
};

struct whoami_report {
	int                 major;
	int                 revision;
	int                 speaks[WHOAMI_MAX_SPEAKS];
	size_t              speaks_count;
	int                 speaks_truncated;  /* more declared than recorded */

	struct whoami_field fields[WHOAMI_MAX_FIELDS];
	size_t              field_count;
	size_t              fields_seen;       /* including any past the cap */

	size_t              special_blocks;    /* skipped, not stored */
	size_t              lines_read;

	/*
	 * A REFUSAL IS A SUCCESSFUL READ, not an error. The device answered
	 * with the preamble alone, which is exactly what SPEC.md requires of a
	 * device that cannot speak the requested major -- and it is the one
	 * answer a reader of ANY major is guaranteed to understand.
	 */
	int                 refusal;
};

/*
 * Parse `len` bytes. Returns WHOAMI_OK or the first problem found.
 *
 * Lines may end LF or CRLF. The buffer is not modified.
 *
 * On anything but WHOAMI_OK the report is still filled in as far as it got, so
 * a caller can say what it did understand -- which for an unidentified device
 * is usually more useful than the error alone.
 */
enum whoami_status whoami_parse(const char *buf, size_t len,
				struct whoami_report *out);

/* Find a field by label. Returns NULL when absent. The first match wins: a
 * duplicate label is a conformance question, not a reading one. */
const struct whoami_field *whoami_get(const struct whoami_report *r,
				      const char *label);

/* Compare a borrowed slice against a C string. */
int whoami_str_eq(const struct whoami_str *s, const char *lit);

/* Does the device declare it can emit this major? */
int whoami_speaks(const struct whoami_report *r, int major);

const char *whoami_status_name(enum whoami_status st);

#ifdef __cplusplus
}
#endif

#endif /* WHOAMI_PARSE_H */
