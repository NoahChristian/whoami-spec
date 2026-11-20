/*
 * Run the shared corpus against ref/ts/whoami.ts.
 *
 * SPDX-License-Identifier: MIT
 *
 * Same job and same output shape as every other runner here, so results can be
 * compared line for line. The corpus is the authority; a runner that disagrees
 * with it is reporting a defect in its implementation.
 *
 * Classification is BY ERROR KIND, never by message text. In TypeScript that
 * kind is a union type, so a runner that forgets a case is a compile error
 * rather than a silently unmatched string -- which is most of what the types
 * are buying here.
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse, Report, WhoamiError } from '../ref/ts/whoami.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = process.argv[2] ?? join(HERE, 'corpus');

function loadExpect(path: string): Map<string, string> {
  const out = new Map<string, string>();
  for (let raw of readFileSync(path, 'utf8').split('\n')) {
    if (raw.endsWith('\r')) raw = raw.slice(0, -1);
    if (raw.length === 0 || raw.startsWith('#')) continue;
    // FIRST equals: a label may contain a space but never an equals sign.
    const eq = raw.indexOf('=');
    if (eq >= 0) out.set(raw.slice(0, eq), raw.slice(eq + 1));
  }
  return out;
}

function check(name: string): string[] {
  const problems: string[] = [];
  const bytes = readFileSync(join(CORPUS, `${name}.report`));
  const expect = loadExpect(join(CORPUS, `${name}.expect`));
  const wantError = expect.get('status') === 'error';

  let report: Report | null = null;
  try {
    report = parse(new Uint8Array(bytes));
    if (wantError) {
      problems.push('read succeeded, but this case exists to be refused');
    }
  } catch (err) {
    if (!(err instanceof WhoamiError)) throw err;
    const got: string = err.kind;
    if (!wantError) {
      problems.push(`threw ${got} but the case expects a successful read`);
    } else if (expect.has('error') && got !== expect.get('error')) {
      problems.push(`error token '${got}', corpus says '${expect.get('error')}'`);
    }
  }

  if (report === null) return problems;

  for (const key of [...expect.keys()].sort()) {
    const want = expect.get(key)!;
    if (key === 'status' || key === 'error') continue;
    if (key.startsWith('field.')) {
      const label = key.slice('field.'.length);
      const got = report.get(label);
      if (got === undefined) {
        problems.push(`field '${label}' absent, corpus says '${want}'`);
      } else if (got !== want) {
        problems.push(`field '${label}' is '${got}', corpus says '${want}'`);
      }
      continue;
    }
    let got: string;
    switch (key) {
      case 'major': got = String(report.major); break;
      case 'revision': got = String(report.revision); break;
      case 'refusal': got = report.refusal ? 'true' : 'false'; break;
      case 'blocks': got = String(report.specialBlocks); break;
      case 'speaks': got = report.speaks.join(' '); break;
      default: continue;
    }
    if (got !== want) problems.push(`${key} is '${got}', corpus says '${want}'`);
  }
  return problems;
}

const names = readFileSync(join(CORPUS, 'INDEX'), 'utf8')
  .split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
let bad = 0;
for (const name of names) {
  const problems = check(name);
  if (problems.length > 0) bad++;
  console.log(`  ${(problems.length ? 'FAIL' : 'ok').padEnd(4)} ${name}`);
  for (const problem of problems) console.log(`        ${problem}`);
}
console.log(`\n  typescript: ${names.length} cases, ${bad} failed`);
process.exit(bad ? 1 : 0);
