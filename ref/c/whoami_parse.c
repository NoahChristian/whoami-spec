/*
 * whoami_parse.c - see whoami_parse.h for the contract and the bounds.
 *
 * SPDX-License-Identifier: MIT
 */
#include "whoami_parse.h"

#include <string.h>

int whoami_str_eq(const struct whoami_str *s, const char *lit)
{
	size_t n;

	if (!s || !s->p || !lit) {
		return 0;
	}
	n = strlen(lit);
	return (s->len == n) && (memcmp(s->p, lit, n) == 0);
}

const char *whoami_status_name(enum whoami_status st)
{
	switch (st) {
	case WHOAMI_OK:         return "ok";
	case WHOAMI_E_EMPTY:    return "empty";
	case WHOAMI_E_PREAMBLE: return "missing or malformed preamble";
	case WHOAMI_E_SCHEMA:   return "schema value not <major>.<4 digits>";
	case WHOAMI_E_TOO_LONG: return "report exceeded its bound";
	case WHOAMI_E_SPECIAL:  return "special block count past the bound";
	default:                return "unknown";
	}
}

/* One line, CRLF or LF. Advances *off past the terminator. */
static int next_line(const char *buf, size_t len, size_t *off,
		     struct whoami_str *out)
{
	size_t start = *off, i;

	if (start >= len) {
		return 0;
	}
	for (i = start; i < len && buf[i] != '\n'; i++) {
		;
	}
	out->p = buf + start;
	out->len = i - start;
	if (out->len > 0 && out->p[out->len - 1] == '\r') {
		out->len--;
	}
	*off = (i < len) ? i + 1 : len;
	return 1;
}

/*
 * Split a grid line into label and value, BY SLICE AND NOT BY SEARCHING FOR
 * WHITESPACE.
 *
 * Columns 1 to WHOAMI_GRID are the label, right-trimmed; the value is the rest,
 * left-trimmed. This is the whole reason the grid is fixed-width: it lets a
 * label contain a space -- `front end` -- with no escaping and no ambiguity
 * about where it ends. Splitting on the first space instead reads that label as
 * `front` and silently moves `end` into the value, which is a corrupted read
 * that looks like a successful one.
 */
static int split(const struct whoami_str *ln, struct whoami_field *f)
{
	size_t lab = (ln->len < WHOAMI_GRID) ? ln->len : WHOAMI_GRID;
	size_t val = lab;

	while (lab > 0 && ln->p[lab - 1] == ' ') {
		lab--;
	}
	if (lab == 0) {
		return 0;
	}
	f->label.p = ln->p;
	f->label.len = lab;
	while (val < ln->len && ln->p[val] == ' ') {
		val++;
	}
	f->value.p = ln->p + val;
	f->value.len = ln->len - val;
	return 1;
}

/* Non-negative decimal. Returns -1 on anything else, including overflow: a
 * count that wrapped is a count the far end chose, and obeying it is the
 * failure this returns -1 to prevent. */
static int to_int(const char *p, size_t len)
{
	int v = 0;

	if (len == 0 || len > 9) {
		return -1;
	}
	for (size_t i = 0; i < len; i++) {
		if (p[i] < '0' || p[i] > '9') {
			return -1;
		}
		v = v * 10 + (p[i] - '0');
	}
	return v;
}

static enum whoami_status parse_schema(const struct whoami_str *v,
				       struct whoami_report *r)
{
	size_t dot = 0;
	int maj, rev;

	while (dot < v->len && v->p[dot] != '.') {
		dot++;
	}
	if (dot == 0 || dot >= v->len) {
		return WHOAMI_E_SCHEMA;
	}
	/* The revision is FOUR DIGITS, zero-padded, always. Fixed width is what
	 * makes "1.0012" and "1.0002" compare correctly as text, and a reader
	 * that accepts "1.12" is accepting a report no conformant emitter
	 * produces. */
	if (v->len - dot - 1 != 4) {
		return WHOAMI_E_SCHEMA;
	}
	maj = to_int(v->p, dot);
	rev = to_int(v->p + dot + 1, 4);
	if (maj < 0 || rev < 0) {
		return WHOAMI_E_SCHEMA;
	}
	r->major = maj;
	r->revision = rev;
	return WHOAMI_OK;
}

static void parse_speaks(const struct whoami_str *v, struct whoami_report *r)
{
	size_t i = 0;

	while (i < v->len) {
		size_t s;
		int m;

		while (i < v->len && v->p[i] == ' ') {
			i++;
		}
		s = i;
		while (i < v->len && v->p[i] != ' ') {
			i++;
		}
		if (i == s) {
			break;
		}
		m = to_int(v->p + s, i - s);
		if (m < 0) {
			continue;   /* unreadable entry; the rest may be fine */
		}
		if (r->speaks_count < WHOAMI_MAX_SPEAKS) {
			r->speaks[r->speaks_count++] = m;
		} else {
			r->speaks_truncated = 1;
		}
	}
}

int whoami_speaks(const struct whoami_report *r, int major)
{
	if (!r) {
		return 0;
	}
	for (size_t i = 0; i < r->speaks_count; i++) {
		if (r->speaks[i] == major) {
			return 1;
		}
	}
	return 0;
}

const struct whoami_field *whoami_get(const struct whoami_report *r,
				      const char *label)
{
	if (!r || !label) {
		return NULL;
	}
	for (size_t i = 0; i < r->field_count; i++) {
		if (whoami_str_eq(&r->fields[i].label, label)) {
			return &r->fields[i];
		}
	}
	return NULL;
}

enum whoami_status whoami_parse(const char *buf, size_t len,
				struct whoami_report *out)
{
	size_t off = 0;
	struct whoami_str ln;
	struct whoami_field f;

	if (!out) {
		return WHOAMI_E_EMPTY;
	}
	memset(out, 0, sizeof(*out));
	if (!buf || len == 0) {
		return WHOAMI_E_EMPTY;
	}

	/*
	 * BOUND THE PREAMBLE READ. A device that never sends a newline must not
	 * be able to hang a reader, and the preamble's whole value is that the
	 * decision is cheap -- so cap the bytes before it has to have landed.
	 */
	if (len > WHOAMI_PREAMBLE_MAX) {
		size_t probe = 0, nl = 0;

		for (; probe < WHOAMI_PREAMBLE_MAX; probe++) {
			if (buf[probe] == '\n' && ++nl == 2) {
				break;
			}
		}
		if (nl < 2) {
			return WHOAMI_E_TOO_LONG;
		}
	}

	if (!next_line(buf, len, &off, &ln) || !split(&ln, &f) ||
	    !whoami_str_eq(&f.label, "schema")) {
		return WHOAMI_E_PREAMBLE;
	}
	out->lines_read++;
	{
		enum whoami_status st = parse_schema(&f.value, out);

		if (st != WHOAMI_OK) {
			return st;
		}
	}

	if (!next_line(buf, len, &off, &ln) || !split(&ln, &f) ||
	    !whoami_str_eq(&f.label, "speaks")) {
		return WHOAMI_E_PREAMBLE;
	}
	out->lines_read++;
	parse_speaks(&f.value, out);

	/* Preamble and nothing else is a refusal, and a successful read. */
	if (off >= len) {
		out->refusal = 1;
		return WHOAMI_OK;
	}

	while (next_line(buf, len, &off, &ln)) {
		if (++out->lines_read > WHOAMI_MAX_LINES) {
			return WHOAMI_E_TOO_LONG;
		}
		if (ln.len == 0) {
			continue;
		}
		if (!split(&ln, &f)) {
			continue;
		}

		if (whoami_str_eq(&f.label, "special")) {
			size_t i = 0, s;
			int count;

			/* `special <count> <tag>` -- take the count only. The
			 * tag is deliberately not interpreted: not knowing it
			 * is the expected case, not an error. */
			while (i < f.value.len && f.value.p[i] != ' ') {
				i++;
			}
			count = to_int(f.value.p, i);
			/*
			 * BOUND THE COUNT. Anything past the cap is a malformed
			 * report rather than an instruction to obey. An
			 * unbounded count supplied by the far end is a request
			 * to read forever -- the same guard the RS485 link on
			 * this bench keeps as LINK_MAX_LEN, where a length past
			 * a sane bound is not a long frame, it is noise that
			 * happened to contain a sync pattern.
			 */
			if (count < 0 || count > WHOAMI_MAX_SPECIAL) {
				return WHOAMI_E_SPECIAL;
			}
			for (s = 0; s < (size_t)count; s++) {
				if (!next_line(buf, len, &off, &ln)) {
					break;   /* truncated; nothing to skip */
				}
				if (++out->lines_read > WHOAMI_MAX_LINES) {
					return WHOAMI_E_TOO_LONG;
				}
			}
			out->special_blocks++;
			continue;
		}

		out->fields_seen++;
		if (out->field_count < WHOAMI_MAX_FIELDS) {
			out->fields[out->field_count++] = f;
		}
		/* Past the cap the field is counted but not stored, so
		 * fields_seen != field_count tells a caller it did not see
		 * everything -- rather than the report looking complete. */
	}
	return WHOAMI_OK;
}
