/*
 * whoami_core.c - see whoami_core.h for why this is one file and not three.
 *
 * SPDX-License-Identifier: MIT
 */
#include "whoami_core.h"

#include <stdio.h>
#include <string.h>

/*
 * Pad a label into the grid and hand the finished line to the caller.
 *
 * One local buffer, one emit. 256 is comfortably past the longest line any
 * required field produces and is a fixed cost rather than an allocation,
 * because this runs on boards where the service task's stack headroom has
 * been measured in hundreds of bytes.
 */
static void line(whoami_emit_fn emit, void *ctx,
		 const char *label, const char *value)
{
	char buf[256];

	if (!emit || !label || !value) {
		return;
	}
	/*
	 * A label at or past the grid width would leave no separator and put
	 * the value where a reader expects the label still to be. Refusing is
	 * better than widening: a wider grid is a format change, and the
	 * reader was not told.
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
	 * separated field without knowing whether `unit` was present. The unit
	 * is omitted entirely when negative rather than written as 0 or 1,
	 * because a field that is always the same value trains readers to skip
	 * it -- and then to skip it on the board where it matters.
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

int whoami_render(whoami_emit_fn emit, void *ctx,
		  const struct whoami_info *info, int requested_major)
{
	char buf[160];

	if (!emit || !info) {
		return 0;
	}

	/*
	 * THE PREAMBLE GOES OUT FIRST AND UNCONDITIONALLY, including on the
	 * refusal path. It is the only thing a reader of any major can parse,
	 * so it is also the only useful thing to say to a caller whose major
	 * this core does not speak.
	 */
	line(emit, ctx, "schema", WHOAMI_CORE_SCHEMA);
	snprintf(buf, sizeof(buf), "%d", WHOAMI_CORE_MAJOR);
	line(emit, ctx, "speaks", buf);

	if (requested_major != WHOAMI_CORE_MAJOR) {
		/*
		 * Refusal. Emitting the body anyway would send the caller a
		 * format it has already said it cannot read, which is the
		 * violation SPEC.md names rather than a lenient kindness.
		 */
		return 0;
	}

	if (whoami_appid_line(buf, sizeof(buf), info) > 0) {
		emit(ctx, buf);
	}

	/* Required fields, in the order SPEC.md lists them. Extras are the
	 * caller's and come after this returns. */
	line(emit, ctx, "project", info->project ? info->project : "");
	line(emit, ctx, "board",   info->board   ? info->board   : "");
	line(emit, ctx, "built",   info->built   ? info->built   : "");
	line(emit, ctx, "uptime",  info->uptime  ? info->uptime  : "");
	line(emit, ctx, "attest",  info->attest  ? info->attest  : "none");
	return 1;
}
