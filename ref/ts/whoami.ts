/*
 * whoami.ts - read a whoami report, with the types a consumer actually wants.
 *
 * SPDX-License-Identifier: MIT
 *
 * A REPORT ARRIVES FROM SOMETHING NOT YET IDENTIFIED. That is what it is for.
 * Every number in it is therefore input, not instruction -- including the
 * counts that say how far to read. SPEC.md "Reading one safely" is the
 * contract this file implements: the format tells a reader how far to read,
 * and the reader decides how far it is willing to. Both halves are required.
 *
 * WHAT TYPES BUY HERE, AND WHAT THEY DO NOT. They make the SHAPE of a report
 * checkable at compile time, which is worth having. They buy nothing at all
 * about its CONTENT: every string in a parsed report is attacker-controlled
 * text that happened to arrive on a port, and a `string` that TypeScript is
 * happy with is still a `string` a board you have never met chose for you.
 * That is why `get()` returns `string | undefined` rather than a convenient
 * `string` -- a reader forced to handle the absent case is a reader that will
 * not interpolate a missing field into a command.
 *
 * NO REGULAR EXPRESSIONS ON UNTRUSTED INPUT, matching every other reference
 * implementation. In a browser this parser runs on the user's main thread, so
 * a backtracking pattern is a hang with a face.
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

/* The canonical failure tokens. A caller classifies on these, never on the
 * message, because a message is for a human and may be reworded. */
export type WhoamiErrorKind =
  | 'empty'
  | 'preamble'
  | 'schema'
  | 'special'
  | 'bounds';

export class WhoamiError extends Error {
  readonly kind: WhoamiErrorKind;

  /* Filled in as far as parsing got, so a caller can say what it DID
   * understand -- usually more useful than the error alone. */
  readonly report: Report | null;

  constructor(kind: WhoamiErrorKind, message: string, report: Report | null = null) {
    super(message);
    this.name = 'WhoamiError';
    this.kind = kind;
    this.report = report;
  }
}

export interface Field {
  readonly label: string;
  readonly value: string;
}

export class Report {
  major = 0;
  revision = 0;
  speaks: number[] = [];
  speaksTruncated = false;
  fields: Field[] = [];
  fieldsSeen = 0;      // including any past MAX_FIELDS
  specialBlocks = 0;
  linesRead = 0;

  /* A REFUSAL IS A SUCCESSFUL READ, not an error: the device answered with the
   * frozen preamble alone, which is what one that cannot speak the requested
   * major is required to do, and is the one answer a reader of ANY major is
   * guaranteed to understand. */
  refusal = false;

  /* Returns undefined rather than '' for an absent field, on purpose: an
   * absent field and a field whose value is empty are different facts, and
   * collapsing them is how a reader reports a board that said nothing as a
   * board that said "". First match wins; a duplicate label is a conformance
   * question, not a reading one. */
  get(label: string): string | undefined {
    return this.fields.find((f) => f.label === label)?.value;
  }

  has(label: string): boolean {
    return this.get(label) !== undefined;
  }

  speaksMajor(major: number): boolean {
    return this.speaks.includes(major);
  }

  get schema(): string {
    return `${this.major}.${String(this.revision).padStart(4, '0')}`;
  }
}

function isDigits(s: string): boolean {
  if (s.length === 0) return false;
  for (const ch of s) if (ch < '0' || ch > '9') return false;
  return true;
}

/* Non-negative decimal, or null. Length-capped BEFORE conversion, because a
 * count that wrapped is a count the far end chose, and obeying it is the
 * failure this refuses. Number() is not used on its own: it accepts '1e9',
 * ' 12 ', '0x10' and '-1', every one of which is a number the far end would
 * like this reader to believe. */
function toInt(s: string): number | null {
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
export function splitLine(line: string): [string | null, string] {
  if (line.trim().length === 0) return [null, ''];
  const label = line.slice(0, GRID).replace(/\s+$/, '');
  if (label.length === 0) return [null, ''];
  const value = line.length > GRID ? line.slice(GRID).replace(/^\s+/, '') : '';
  return [label, value];
}

function parseSchema(value: string, report: Report): void {
  const dot = value.indexOf('.');
  const fail = () => {
    throw new WhoamiError('schema', 'schema value not <major>.<4 digits>', report);
  };
  if (dot <= 0 || dot >= value.length - 1) fail();
  const revision = value.slice(dot + 1);
  // FOUR DIGITS, zero-padded, always. Fixed width is what makes "1.0012" and
  // "1.0002" compare correctly as text, and a reader that accepts "1.12" is
  // accepting a report no conformant emitter produces.
  if (revision.length !== 4) fail();
  const m = toInt(value.slice(0, dot));
  const r = toInt(revision);
  if (m === null || r === null) fail();
  report.major = m as number;
  report.revision = r as number;
}

function parseSpeaks(value: string, report: Report): void {
  for (const word of value.split(/\s+/)) {
    if (word.length === 0) continue;
    const major = toInt(word);
    if (major === null) continue;  // unreadable entry; the rest may be fine
    if (report.speaks.length < MAX_SPEAKS) report.speaks.push(major);
    else report.speaksTruncated = true;
  }
}

/* Parse a report. Accepts a string or raw bytes; lines may end LF or CRLF. */
export function parse(input: string | Uint8Array): Report {
  const report = new Report();
  let text: string;
  if (input instanceof Uint8Array) {
    // latin1 never fails and never reinterprets a byte, so a report carrying
    // something unexpected is READ rather than refused.
    text = new TextDecoder('latin1').decode(input);
  } else {
    text = input;
  }
  if (typeof text !== 'string' || text.length === 0) {
    throw new WhoamiError('empty', 'empty report', report);
  }

  // BOUND THE PREAMBLE READ. A device that never sends a newline must not be
  // able to hang a reader, and the preamble's whole value is that the decision
  // is cheap -- so cap the bytes before it has to have landed.
  if (text.length > PREAMBLE_MAX) {
    let newlines = 0;
    for (let i = 0; i < PREAMBLE_MAX; i++) if (text[i] === '\n') newlines++;
    if (newlines < 2) {
      throw new WhoamiError(
        'bounds',
        `report exceeded its bound (no newline within the first ${PREAMBLE_MAX} bytes)`,
        report,
      );
    }
  }

  const lines = text.split('\n').map((l) => (l.endsWith('\r') ? l.slice(0, -1) : l));
  let index = 0;
  const take = (): string | null => (index < lines.length ? lines[index++]! : null);

  const first = take();
  const [schemaLabel, schemaValue] = splitLine(first ?? '');
  if (schemaLabel !== 'schema') {
    throw new WhoamiError('preamble', 'missing or malformed preamble', report);
  }
  report.linesRead++;
  parseSchema(schemaValue, report);

  const second = take();
  const [speaksLabel, speaksValue] = splitLine(second ?? '');
  if (speaksLabel !== 'speaks') {
    throw new WhoamiError('preamble', 'missing or malformed preamble', report);
  }
  report.linesRead++;
  parseSpeaks(speaksValue, report);

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
      throw new WhoamiError('bounds', 'report exceeded its line bound', report);
    }
    if (line.trim().length === 0) continue;
    const [label, value] = splitLine(line);
    if (label === null) continue;

    if (label === 'special') {
      // `special <count> <tag>` -- the count only. The tag is deliberately not
      // interpreted: not knowing it is the expected case, not an error.
      const count = toInt(value.split(/\s+/)[0] ?? '');
      // BOUND THE COUNT. An unbounded count supplied by the far end is a
      // request to read forever. Past the cap it is a malformed report, not an
      // instruction to obey.
      if (count === null || count > MAX_SPECIAL) {
        throw new WhoamiError('special', 'special block count past the bound', report);
      }
      for (let i = 0; i < count; i++) {
        if (take() === null) break;   // truncated; nothing left to skip
        report.linesRead++;
        if (report.linesRead > MAX_LINES) {
          throw new WhoamiError('bounds', 'report exceeded its line bound', report);
        }
      }
      report.specialBlocks++;
      continue;
    }

    report.fieldsSeen++;
    // Past the cap a field is counted but not stored, so fieldsSeen !==
    // fields.length tells a caller it did not see everything.
    if (report.fields.length < MAX_FIELDS) report.fields.push({ label, value });
  }
  return report;
}

export interface EmitInfo {
  token: string;
  fw: string;
  unit?: number | null;
  project?: string;
  board?: string;
  built?: string;
  uptime?: string;
  attest?: string;
}

const pad = (s: string): string => s.padEnd(GRID, ' ');

/* Produce a report. The mirror of parse(), and the same grammar. An empty body
 * (preamble only) is the conformant REFUSAL for a major this device does not
 * speak -- answering in the wrong major is the violation, not a kindness. */
export function emit(
  info: EmitInfo,
  requestedMajor = 1,
  schema = '1.0005',
  speaks: number[] | null = null,
): string[] {
  const majors = speaks ?? [Number(schema.split('.')[0])];
  const out = [pad('schema') + schema, pad('speaks') + majors.join(' ')];
  if (!majors.includes(requestedMajor)) return out;

  // `fw <version>` LAST, so a parser can take the final whitespace-separated
  // field without knowing whether `unit` was present.
  const appid = info.unit === undefined || info.unit === null
    ? `${info.token} fw ${info.fw}`
    : `${info.token} unit ${Number(info.unit)} fw ${info.fw}`;
  out.push(pad('appid') + appid);
  for (const key of ['project', 'board', 'built', 'uptime', 'attest'] as const) {
    out.push(pad(key) + (info[key] ?? ''));
  }
  return out;
}

/* A counted block of opaque lines. Returns [] rather than a half-written block
 * if it would be malformed -- the header is a promise about how many lines
 * follow, and a reader will skip exactly that many. */
export function special(tag: string, lines: readonly string[]): string[] {
  const body = Array.from(lines ?? []);
  if (!tag || !tag.includes('.') || body.length > MAX_SPECIAL) return [];
  if (!body.every((l) => typeof l === 'string')) return [];
  return [pad('special') + `${body.length} ${tag}`, ...body];
}
