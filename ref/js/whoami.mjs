/*
 * whoami.mjs - read a whoami report.
 *
 * SPDX-License-Identifier: MIT
 *
 * A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
 * Every number in it is therefore input, not instruction -- including the
 * counts that say how far to read. SPEC.md "Reading one safely" is the
 * contract this file implements, and the shape of all of it is: the format
 * tells a reader how far to read, and the reader decides how far it is willing
 * to. Both halves are required. A length you trust without a bound is not a
 * safety feature, it is an instruction.
 *
 * NO REGULAR EXPRESSIONS ON UNTRUSTED INPUT -- the same choice every other
 * implementation here makes. A parser whose safety rests on a regex is one
 * backtracking pattern away from the denial of service the bounds exist to
 * prevent, and in a browser that parser is running on the user's main thread.
 *
 * THE BROWSER IS A REAL CONSUMER. A board's /api/whoami is the obvious thing
 * for a dashboard page to read, and that page is the least trusted reader of
 * the set: it will happily render whatever it is handed. Field values are
 * returned as text and are never interpreted here. Do not insert one with
 * innerHTML.
 *
 * NOT A VALIDATOR. It answers "what does this say", bounded and without
 * trusting it. Conformance is a separate, stricter question.
 */

export const GRID = 11;          // columns 1-11 are the label; value at 12

// Bounds. Each exists so a hostile or broken far end cannot make a reader work
// harder than the reader chose to.
export const MAX_LINES = 500;    // total, so a looping device is a failed read
export const MAX_SPECIAL = 100;  // lines skipped for one block
export const MAX_SPEAKS = 16;    // majors recorded from the speaks line
export const MAX_FIELDS = 64;    // fields recorded; the rest are counted only
export const PREAMBLE_MAX = 512; // bytes before the preamble must have landed

export class WhoamiError extends Error {
  constructor(message, report = null) {
    super(message);
    this.name = 'WhoamiError';
    // Filled in as far as parsing got, so a caller can say what it DID
    // understand -- usually more useful than the error alone.
    this.report = report;
  }
}

export class Report {
  constructor() {
    this.major = 0;
    this.revision = 0;
    this.speaks = [];
    this.speaksTruncated = false;
    this.fields = [];        // [label, value] pairs, in order
    this.fieldsSeen = 0;     // including any past MAX_FIELDS
    this.specialBlocks = 0;
    this.linesRead = 0;
    // A REFUSAL IS A SUCCESSFUL READ, not an error: the device answered with
    // the preamble alone, which is what a device that cannot speak the
    // requested major is required to do, and is the one answer a reader of ANY
    // major is guaranteed to understand.
    this.refusal = false;
  }

  /* First match wins. A duplicate label is a conformance question. */
  get(label) {
    const hit = this.fields.find(([name]) => name === label);
    return hit ? hit[1] : undefined;
  }

  has(label) { return this.get(label) !== undefined; }

  speaksMajor(major) { return this.speaks.includes(major); }

  get schema() {
    return `${this.major}.${String(this.revision).padStart(4, '0')}`;
  }
}

function isDigits(s) {
  if (!s || s.length === 0) return false;
  for (const ch of s) if (ch < '0' || ch > '9') return false;
  return true;
}

/* Non-negative decimal, or null. Length-capped BEFORE conversion, because a
 * count that wrapped is a count the far end chose, and obeying it is the
 * failure this refuses. */
function toInt(s) {
  if (!isDigits(s) || s.length > 9) return null;
  return Number(s);
}

/*
 * Label and value, BY SLICE AND NOT BY SPLITTING ON WHITESPACE.
 *
 * Columns 1-11 are the label, right-trimmed; column 12 onward is the value,
 * left-trimmed. That fixed width is the whole reason the grid exists: it lets
 * a label contain a space -- `front end` -- with no escaping and no ambiguity
 * about where it ends. Splitting on the first space instead reads that label
 * as `front` and silently moves `end` into the value: a corrupted read that
 * looks like a successful one.
 */
export function splitLine(line) {
  if (!line || line.trim().length === 0) return [null, null];
  const label = line.slice(0, GRID).replace(/\s+$/, '');
  if (label.length === 0) return [null, null];
  const value = line.length > GRID ? line.slice(GRID).replace(/^\s+/, '') : '';
  return [label, value];
}

function parseSchema(value, report) {
  const dot = value.indexOf('.');
  if (dot <= 0 || dot >= value.length - 1) {
    throw new WhoamiError('schema value not <major>.<4 digits>', report);
  }
  const revision = value.slice(dot + 1);
  // FOUR DIGITS, zero-padded, always. Fixed width is what makes "1.0012" and
  // "1.0002" compare correctly as text, and a reader that accepts "1.12" is
  // accepting a report no conformant emitter produces.
  if (revision.length !== 4) {
    throw new WhoamiError('schema value not <major>.<4 digits>', report);
  }
  const m = toInt(value.slice(0, dot));
  const r = toInt(revision);
  if (m === null || r === null) {
    throw new WhoamiError('schema value not <major>.<4 digits>', report);
  }
  report.major = m;
  report.revision = r;
}

function parseSpeaks(value, report) {
  for (const word of value.split(/\s+/)) {
    if (word.length === 0) continue;
    const major = toInt(word);
    if (major === null) continue;   // unreadable entry; the rest may be fine
    if (report.speaks.length < MAX_SPEAKS) report.speaks.push(major);
    else report.speaksTruncated = true;
  }
}

/* Parse a report. Returns a Report, or throws WhoamiError.
 * Accepts a string or a Uint8Array; lines may end LF or CRLF. */
export function parse(text) {
  const report = new Report();
  if (text instanceof Uint8Array) {
    // latin1 never fails and never reinterprets a byte, so a report carrying
    // something unexpected is READ rather than refused.
    text = new TextDecoder('latin1').decode(text);
  }
  if (typeof text !== 'string' || text.length === 0) {
    throw new WhoamiError('empty', report);
  }

  // BOUND THE PREAMBLE READ. A device that never sends a newline must not be
  // able to hang a reader, and the preamble's whole value is that the decision
  // is cheap -- so cap the bytes before it has to have landed.
  if (text.length > PREAMBLE_MAX) {
    const head = text.slice(0, PREAMBLE_MAX);
    let newlines = 0;
    for (const ch of head) if (ch === '\n') newlines++;
    if (newlines < 2) throw new WhoamiError('report exceeded its bound', report);
  }

  const lines = text.split('\n').map((l) => (l.endsWith('\r') ? l.slice(0, -1) : l));
  let index = 0;
  const take = () => (index < lines.length ? lines[index++] : null);

  let [label, value] = splitLine(take());
  if (label !== 'schema') {
    throw new WhoamiError('missing or malformed preamble', report);
  }
  report.linesRead++;
  parseSchema(value, report);

  [label, value] = splitLine(take());
  if (label !== 'speaks') {
    throw new WhoamiError('missing or malformed preamble', report);
  }
  report.linesRead++;
  parseSpeaks(value, report);

  // Preamble and nothing else is a refusal, and a successful read.
  if (lines.slice(index).every((l) => l.trim().length === 0)) {
    report.refusal = true;
    return report;
  }

  for (;;) {
    const line = take();
    if (line === null) break;
    report.linesRead++;
    if (report.linesRead > MAX_LINES) {
      throw new WhoamiError('report exceeded its bound', report);
    }
    if (line.trim().length === 0) continue;
    const [lab, val] = splitLine(line);
    if (lab === null) continue;

    if (lab === 'special') {
      // `special <count> <tag>` -- the count only. The tag is deliberately not
      // interpreted: not knowing it is the expected case, not an error.
      const first = val.split(/\s+/)[0] ?? '';
      const count = toInt(first);
      // BOUND THE COUNT. Past the cap it is a malformed report, not an
      // instruction to obey. An unbounded count from the far end is a request
      // to read forever -- the same guard the RS485 link on this bench keeps
      // as LINK_MAX_LEN, where a length past a sane bound is not a long frame,
      // it is noise that happened to contain a sync pattern.
      if (count === null || count > MAX_SPECIAL) {
        throw new WhoamiError('special block count past the bound', report);
      }
      for (let i = 0; i < count; i++) {
        if (take() === null) break;    // truncated; nothing left to skip
        report.linesRead++;
        if (report.linesRead > MAX_LINES) {
          throw new WhoamiError('report exceeded its bound', report);
        }
      }
      report.specialBlocks++;
      continue;
    }

    report.fieldsSeen++;
    // Past the cap a field is counted but not stored, so fieldsSeen !==
    // fields.length tells a caller it did not see everything.
    if (report.fields.length < MAX_FIELDS) report.fields.push([lab, val]);
  }
  return report;
}

const pad = (s) => String(s).padEnd(GRID, ' ');

/* Produce a report. The mirror of parse(), and the same grammar. An empty body
 * (preamble only) is the conformant REFUSAL for a major this device does not
 * speak -- answering in the wrong major is the violation, not a kindness. */
export function emit(info, requestedMajor = 1, schema = '1.0005', speaks = null) {
  const majors = speaks ?? [Number(schema.split('.')[0])];
  const out = [pad('schema') + schema, pad('speaks') + majors.join(' ')];
  if (!majors.includes(requestedMajor)) return out;

  // `fw <version>` LAST, so a parser can take the final whitespace-separated
  // field without knowing whether `unit` was present.
  const appid = info.unit === undefined || info.unit === null
    ? `${info.token} fw ${info.fw}`
    : `${info.token} unit ${Number(info.unit)} fw ${info.fw}`;
  out.push(pad('appid') + appid);
  for (const key of ['project', 'board', 'built', 'uptime', 'attest']) {
    out.push(pad(key) + (info[key] ?? ''));
  }
  return out;
}

/* A counted block of opaque lines. Returns [] rather than a half-written block
 * if it would be malformed -- the header is a promise about how many lines
 * follow, and a reader will skip exactly that many. */
export function special(tag, lines) {
  const body = Array.from(lines ?? []);
  if (!tag || !tag.includes('.') || body.length > MAX_SPECIAL) return [];
  if (!body.every((l) => typeof l === 'string')) return [];
  return [pad('special') + `${body.length} ${tag}`, ...body];
}
