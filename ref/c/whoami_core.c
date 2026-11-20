/*
 * whoami_core.c - see whoami_core.h for why this is one file and not three.
 *
 * SPDX-License-Identifier: MIT
 */
#include "whoami_core.h"

#include <stdio.h>
#include <string.h>

/*
 * A cap on how many lines this core will write out of one special block.
 *
 * The emitting side needs this as much as the reading side does. SPEC.md asks a
 * READER to bound the count it will obey, because an unbounded count from the
 * far end is a request to read forever -- but a caller that passes a wrong
 * count here produces exactly the report that attacks a conformant reader. The
 * cheapest place to stop that is before it is written.
 */
#define WHOAMI_SPECIAL_MAX 100

/*
 * Pad a label into the grid and hand the finished line to the caller.
 *
 * One local buffer, one emit. 256 is comfortably past the longest line any
 * required field produces, and is a fixed cost rather than an allocation,
 * because this runs on boards where a service task's stack headroom has been
 * measured in hundreds of bytes.
 */
static void line(whoami_emit_fn emit, void *ctx,
		 const char *label, const char *value)
{
	char buf[256];

	if (!emit || !label || !value) {
		return;
	}
	/*
	 * A label at or past the grid width would leave no separator and put the
	 * value where a reader expects the label still to be. Refusing beats
	 * widening: a wider grid is a format change, and the reader was not told.
	 */
	if (strlen(label) >= WHOAMI_CORE_GRID) {
		return;
	}
	if (snprintf(buf, sizeof(buf), "%-*s%s",
		     WHOAMI_CORE_GRID, label, value) < 0) {
		return;
	}
	emit(ctx, buf);
}

void whoami_field(whoami_emit_fn emit, void *ctx,
		  const char *label, const char *value)
{
	line(emit, ctx, label, value);
}

int whoami_appid_line(char *buf, size_t cap, const struct whoami_info *info)
{
	int n;

	if (!buf || cap == 0 || !info || !info->token || !info->fw) {
		return -1;
	}
	/*
	 * `fw <version>` LAST, so a parser can take the final whitespace-
	 * separated field without knowing whether `unit` was present. The unit is
	 * omitted entirely when negative rather than written as 0 or 1, because a
	 * field that is always the same value trains readers to skip it -- and
	 * then to skip it on the board where it matters.
	 */
	if (info->unit >= 0) {
		n = snprintf(buf, cap, "%-*s%s unit %d fw %s",
			     WHOAMI_CORE_GRID, "appid", info->token,
			     info->unit, info->fw);
	} else {
		n = snprintf(buf, cap, "%-*s%s fw %s",
			     WHOAMI_CORE_GRID, "appid", info->token, info->fw);
	}
	if (n < 0 || (size_t)n >= cap) {
		return -1;
	}
	return n;
}

/* A dotted name: lowercase alphanumeric segments, at least two of them, so an
 * unprefixed tag cannot be mistaken for one that belongs to this spec. */
static int tag_ok(const char *tag)
{
	int seg = 0, len = 0;

	if (!tag || *tag < 'a' || *tag > 'z') {
		return 0;
	}
	for (const char *p = tag; *p; p++) {
		if (*p == '.') {
			if (len == 0) {
				return 0;
			}
			seg++;
			len = 0;
			continue;
		}
		if (!((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') ||
		      *p == '-')) {
			return 0;
		}
		len++;
	}
	return (seg >= 1 && len > 0);
}

int whoami_special(whoami_emit_fn emit, void *ctx, const char *tag,
		   const char *const *lines, size_t count)
{
	char buf[256];

	if (!emit || !tag_ok(tag) || count > WHOAMI_SPECIAL_MAX) {
		return 0;
	}
	if (count > 0 && !lines) {
		return 0;
	}
	/*
	 * VALIDATE EVERY LINE BEFORE WRITING THE HEADER. The header is a promise
	 * about how many lines follow, and a reader will skip exactly that many.
	 * Discovering a NULL line halfway through would leave the reader
	 * consuming whatever came next as block content -- the desync the count
	 * exists to prevent.
	 */
	for (size_t i = 0; i < count; i++) {
		if (!lines[i]) {
			return 0;
		}
	}
	if (snprintf(buf, sizeof(buf), "%-*s%u %s",
		     WHOAMI_CORE_GRID, "special",
		     (unsigned)count, tag) < 0) {
		return 0;
	}
	emit(ctx, buf);
	for (size_t i = 0; i < count; i++) {
		emit(ctx, lines[i]);  /* opaque: no grid, no escaping */
	}
	return 1;
}

/* Write the speaks list, space-separated. Falls back to this core's own major
 * when the caller declares none, which is the common case. */
static void speaks_line(whoami_emit_fn emit, void *ctx,
			const struct whoami_info *info)
{
	char val[96];
	size_t used = 0;
	int n;

	if (!info->speaks || info->speaks_count == 0) {
		n = snprintf(val, sizeof(val), "%d", WHOAMI_CORE_MAJOR);
		if (n > 0) {
			line(emit, ctx, "speaks", val);
		}
		return;
	}
	val[0] = '\0';
	for (size_t i = 0; i < info->speaks_count; i++) {
		n = snprintf(val + used, sizeof(val) - used,
			     (i == 0) ? "%d" : " %d", info->speaks[i]);
		if (n < 0 || (size_t)n >= sizeof(val) - used) {
			break;   /* truncate rather than overrun; still parses */
		}
		used += (size_t)n;
	}
	line(emit, ctx, "speaks", val);
}

static int declares(const struct whoami_info *info, int major)
{
	if (!info->speaks || info->speaks_count == 0) {
		return major == WHOAMI_CORE_MAJOR;
	}
	for (size_t i = 0; i < info->speaks_count; i++) {
		if (info->speaks[i] == major) {
			return 1;
		}
	}
	return 0;
}

int whoami_render(whoami_emit_fn emit, void *ctx,
		  const struct whoami_info *info, int requested_major)
{
	char buf[160];

	if (!emit || !info) {
		return 0;
	}

	/*
	 * THE PREAMBLE GOES OUT FIRST AND UNCONDITIONALLY, including on the
	 * refusal path. It is the only thing a reader of any major can parse, so
	 * it is also the only useful thing to say to a caller whose major this
	 * device does not speak.
	 */
	line(emit, ctx, "schema", WHOAMI_CORE_SCHEMA);
	speaks_line(emit, ctx, info);

	if (!declares(info, requested_major)) {
		/*
		 * Refusal. Emitting the body anyway would send the caller a
		 * format it has already said it cannot read -- the violation
		 * SPEC.md names, not a lenient kindness. The caller now has both
		 * lists and can say "this device speaks X; I know Y", which is a
		 * diagnosable answer rather than a parse failure.
		 */
		return 0;
	}
	if (requested_major != WHOAMI_CORE_MAJOR) {
		/*
		 * Declared, but not ours to write. The device said it speaks
		 * this major, so refusing would contradict its own preamble;
		 * emitting our major would answer in the wrong language. Hand it
		 * back instead, preamble already sent.
		 */
		return -1;
	}

	if (whoami_appid_line(buf, sizeof(buf), info) > 0) {
		emit(ctx, buf);
	}

	/* Required fields, in the order SPEC.md lists them. Extras and special
	 * blocks are the caller's and come after this returns. */
	line(emit, ctx, "project", info->project ? info->project : "");
	line(emit, ctx, "board",   info->board   ? info->board   : "");
	line(emit, ctx, "built",   info->built   ? info->built   : "");
	line(emit, ctx, "uptime",  info->uptime  ? info->uptime  : "");
	line(emit, ctx, "attest",  info->attest  ? info->attest  : "none");
	return 1;
}
