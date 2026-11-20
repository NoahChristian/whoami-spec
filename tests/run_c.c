/*
 * Run the shared corpus against ref/c/whoami_parse.c.
 *
 * SPDX-License-Identifier: MIT
 *
 * Same job and same output shape as every other runner here, so results can be
 * compared line for line. The corpus is the authority; a runner that disagrees
 * with it is reporting a defect in its implementation.
 *
 * THIS ONE MATTERS MOST. The C implementation is the one that ends up on a
 * microcontroller, where a parser that obeys a hostile count has somewhere real
 * to go wrong -- and it is the hardest to check, because the usual answer is
 * "it compiled". Compiling is not evidence about behavior. Everything below
 * exists so the embedded reader is held to the same 18 cases as the readers
 * that run on a workstation.
 */
#include "../ref/c/whoami_parse.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_EXPECT 32
#define MAX_REPORT 65536

struct expect_kv {
	char key[64];
	char value[256];
};

static size_t read_file(const char *path, char *buf, size_t cap)
{
	FILE *fh = fopen(path, "rb");
	size_t n;

	if (!fh) {
		fprintf(stderr, "cannot read %s\n", path);
		exit(2);
	}
	n = fread(buf, 1, cap, fh);
	fclose(fh);
	return n;
}

static size_t load_expect(const char *path, struct expect_kv *out, size_t cap)
{
	static char buf[8192];
	size_t len = read_file(path, buf, sizeof(buf) - 1);
	size_t count = 0, start = 0, i;

	buf[len] = '\0';
	for (i = 0; i <= len; i++) {
		if (i != len && buf[i] != '\n') {
			continue;
		}
		{
			size_t end = i;
			const char *eq;

			if (end > start && buf[end - 1] == '\r') {
				end--;
			}
			buf[end] = '\0';
			/* FIRST equals: a label may contain a space but never an
			 * equals sign, which is why this format can be read with
			 * one strchr and no quoting rules. */
			eq = (buf[start] == '#') ? NULL : strchr(buf + start, '=');
			if (eq && count < cap) {
				size_t klen = (size_t)(eq - (buf + start));

				if (klen < sizeof(out[0].key)) {
					memcpy(out[count].key, buf + start, klen);
					out[count].key[klen] = '\0';
					snprintf(out[count].value,
						 sizeof(out[count].value), "%s", eq + 1);
					count++;
				}
			}
			start = i + 1;
		}
	}
	return count;
}

static const char *token_of(enum whoami_status st)
{
	switch (st) {
	case WHOAMI_E_EMPTY:    return "empty";
	case WHOAMI_E_PREAMBLE: return "preamble";
	case WHOAMI_E_SCHEMA:   return "schema";
	case WHOAMI_E_SPECIAL:  return "special";
	case WHOAMI_E_TOO_LONG: return "bounds";
	default:                return "ok";
	}
}

/* Compare a borrowed, non-NUL-terminated slice against a C string. */
static int slice_eq(const struct whoami_str *s, const char *lit)
{
	size_t n = strlen(lit);

	return s->p && s->len == n && memcmp(s->p, lit, n) == 0;
}

static int check(const char *dir, const char *name, int *problems_out)
{
	static char report_buf[MAX_REPORT];
	struct expect_kv expect[MAX_EXPECT];
	struct whoami_report report;
	char path[512];
	size_t len, n, i;
	enum whoami_status st;
	const char *want_status = "ok";
	const char *want_error = NULL;
	int problems = 0;

	snprintf(path, sizeof(path), "%s/%s.report", dir, name);
	len = read_file(path, report_buf, sizeof(report_buf));
	snprintf(path, sizeof(path), "%s/%s.expect", dir, name);
	n = load_expect(path, expect, MAX_EXPECT);

	for (i = 0; i < n; i++) {
		if (strcmp(expect[i].key, "status") == 0) {
			want_status = expect[i].value;
		} else if (strcmp(expect[i].key, "error") == 0) {
			want_error = expect[i].value;
		}
	}

	st = whoami_parse(report_buf, len, &report);

	if (strcmp(want_status, "error") == 0) {
		if (st == WHOAMI_OK) {
			printf("        read succeeded, but this case exists to be refused\n");
			problems++;
		} else if (want_error && strcmp(token_of(st), want_error) != 0) {
			printf("        error token '%s', corpus says '%s'\n",
			       token_of(st), want_error);
			problems++;
		}
		*problems_out = problems;
		return problems == 0;
	}

	if (st != WHOAMI_OK) {
		printf("        returned '%s' but the case expects a successful read\n",
		       token_of(st));
		*problems_out = 1;
		return 0;
	}

	for (i = 0; i < n; i++) {
		const char *key = expect[i].key;
		const char *want = expect[i].value;
		char got[256];

		if (strcmp(key, "status") == 0 || strcmp(key, "error") == 0) {
			continue;
		}
		if (strncmp(key, "field.", 6) == 0) {
			const struct whoami_field *f = whoami_get(&report, key + 6);

			if (!f) {
				printf("        field '%s' absent, corpus says '%s'\n",
				       key + 6, want);
				problems++;
			} else if (!slice_eq(&f->value, want)) {
				printf("        field '%s' is '%.*s', corpus says '%s'\n",
				       key + 6, (int)f->value.len, f->value.p, want);
				problems++;
			}
			continue;
		}
		if (strcmp(key, "major") == 0) {
			snprintf(got, sizeof(got), "%d", report.major);
		} else if (strcmp(key, "revision") == 0) {
			snprintf(got, sizeof(got), "%d", report.revision);
		} else if (strcmp(key, "refusal") == 0) {
			snprintf(got, sizeof(got), "%s", report.refusal ? "true" : "false");
		} else if (strcmp(key, "blocks") == 0) {
			snprintf(got, sizeof(got), "%u", (unsigned)report.special_blocks);
		} else if (strcmp(key, "speaks") == 0) {
			size_t k, used = 0;

			got[0] = '\0';
			for (k = 0; k < report.speaks_count; k++) {
				int w = snprintf(got + used, sizeof(got) - used,
						 (k == 0) ? "%d" : " %d",
						 report.speaks[k]);
				if (w < 0 || (size_t)w >= sizeof(got) - used) {
					break;
				}
				used += (size_t)w;
			}
		} else {
			continue;
		}
		if (strcmp(got, want) != 0) {
			printf("        %s is '%s', corpus says '%s'\n", key, got, want);
			problems++;
		}
	}
	*problems_out = problems;
	return problems == 0;
}

int main(int argc, char **argv)
{
	const char *dir = (argc > 1) ? argv[1] : "tests/corpus";
	static char index_buf[8192];
	char path[512];
	size_t len, start = 0, i;
	int total = 0, bad = 0;

	snprintf(path, sizeof(path), "%s/INDEX", dir);
	len = read_file(path, index_buf, sizeof(index_buf) - 1);
	index_buf[len] = '\0';

	for (i = 0; i <= len; i++) {
		if (i != len && index_buf[i] != '\n') {
			continue;
		}
		{
			size_t end = i;
			int problems = 0;

			if (end > start && index_buf[end - 1] == '\r') {
				end--;
			}
			index_buf[end] = '\0';
			if (end > start) {
				char name[128];

				snprintf(name, sizeof(name), "%s", index_buf + start);
				/* The case name goes to stderr BEFORE the case
				 * runs, so a crash mid-case still says which
				 * case killed it -- while stdout keeps the same
				 * one-line-per-case shape as every other runner,
				 * which is what makes the results comparable. */
				fprintf(stderr, "running %s\n", name);
				if (!check(dir, name, &problems)) {
					bad++;
					printf("  FAIL %s\n", name);
				} else {
					printf("  ok   %s\n", name);
				}
				fflush(stdout);
				total++;
			}
			start = i + 1;
		}
	}
	printf("\n  c: %d cases, %d failed\n", total, bad);
	return bad ? 1 : 0;
}
