/*
 * Round-trip the C emitter through the C parser.
 *
 * SPDX-License-Identifier: MIT
 *
 * WHY THIS IS SEPARATE FROM THE CORPUS RUN. The corpus holds reports written
 * by hand from SPEC.md, which is what makes it an independent authority on
 * what a READER must accept. It says nothing about what the EMITTER produces.
 * Checking the emitter against the corpus would be checking it against inputs
 * it never generates; checking it against its own parser would be two halves
 * of one assumption agreeing with itself.
 *
 * So this does the one thing that is actually evidence: emit a report, read it
 * back, and confirm the values that went in are the values that come out --
 * and then confirm the refusal path emits a preamble and NOTHING else, which
 * is the property a caller's security depends on and the easiest to break
 * while everything still looks fine.
 */
#include "../ref/c/whoami_core.h"
#include "../ref/c/whoami_parse.h"

#include <stdio.h>
#include <string.h>

static char g_buf[4096];
static size_t g_used;

static void collect(void *ctx, const char *line)
{
	(void)ctx;
	g_used += (size_t)snprintf(g_buf + g_used, sizeof(g_buf) - g_used,
				   "%s\n", line);
}

static int fails;

static void ok(const char *label, int cond)
{
	if (!cond) {
		fails++;
	}
	printf("  %-4s %s\n", cond ? "ok" : "FAIL", label);
}

static int field_is(const struct whoami_report *r, const char *label,
		    const char *want)
{
	const struct whoami_field *f = whoami_get(r, label);

	return f && f->value.len == strlen(want) &&
	       memcmp(f->value.p, want, f->value.len) == 0;
}

int main(void)
{
	struct whoami_info info;
	struct whoami_report report;
	static const int speaks[] = {1, 2};
	const char *note[] = {"a line the schema never defined",
			      "attest     forged"};

	memset(&info, 0, sizeof(info));
	info.token = "example-display";
	info.unit = 2;
	info.fw = "3.3.0";
	info.project = "Example Display, unit 2";
	info.board = "some-board/soc/core";
	info.built = "Nov 19 2026 18:07:46";
	info.uptime = "0d 00:00:24";
	info.attest = "none";

	/* --- the ordinary path --------------------------------------------- */
	g_used = 0;
	ok("render reports it emitted a body",
	   whoami_render(collect, NULL, &info, WHOAMI_CORE_MAJOR) == 1);
	whoami_field(collect, NULL, "front end", "some-frontend");
	ok("emitter output parses", whoami_parse(g_buf, g_used, &report) == WHOAMI_OK);
	ok("schema round-trips", report.major == 1 && report.revision == 5);
	ok("appid round-trips, unit and fw in order",
	   field_is(&report, "appid", "example-display unit 2 fw 3.3.0"));
	ok("project round-trips", field_is(&report, "project", "Example Display, unit 2"));
	ok("attest round-trips", field_is(&report, "attest", "none"));
	/* THE TWO-WORD LABEL, EMITTED AND READ BACK. This is the pair that a
	 * whitespace split breaks in both directions at once, and it looks
	 * fine from either side alone. */
	ok("two-word label survives the round trip",
	   field_is(&report, "front end", "some-frontend"));
	ok("not a refusal", report.refusal == 0);

	/* --- a device that speaks several majors ---------------------------- */
	info.speaks = speaks;
	info.speaks_count = 2;
	g_used = 0;
	ok("render accepts a declared major it does not write",
	   whoami_render(collect, NULL, &info, 2) == -1);
	ok("that answer is preamble-only",
	   whoami_parse(g_buf, g_used, &report) == WHOAMI_OK && report.refusal);
	ok("speaks lists both majors",
	   report.speaks_count == 2 && report.speaks[0] == 1 && report.speaks[1] == 2);

	/* --- the refusal path ----------------------------------------------- */
	g_used = 0;
	ok("render refuses an unspoken major (the GREASE probe)",
	   whoami_render(collect, NULL, &info, 9999) == 0);
	ok("refusal parses", whoami_parse(g_buf, g_used, &report) == WHOAMI_OK);
	ok("REFUSAL EMITS NO BODY", report.field_count == 0 && report.refusal);

	/* --- special blocks -------------------------------------------------- */
	g_used = 0;
	whoami_render(collect, NULL, &info, WHOAMI_CORE_MAJOR);
	ok("special block emitted", whoami_special(collect, NULL, "note.operator", note, 2) == 1);
	ok("block parses as one skipped block",
	   whoami_parse(g_buf, g_used, &report) == WHOAMI_OK &&
	   report.special_blocks == 1);
	/* The block's second line is a forged `attest`. If the reader parsed
	 * inside the block it would now be reporting "forged". */
	ok("forged field inside the block did NOT override the real one",
	   field_is(&report, "attest", "none"));

	ok("a tag with no dot is refused", whoami_special(collect, NULL, "note", note, 2) == 0);
	ok("a count past the cap is refused",
	   whoami_special(collect, NULL, "note.x", note, 101) == 0);

	printf("\n  c emitter: %d checks failed\n", fails);
	return fails ? 1 : 0;
}
