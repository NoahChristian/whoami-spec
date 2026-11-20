/*
 * Run the shared corpus against ref/js/whoami.mjs.
 *
 * SPDX-License-Identifier: MIT
 *
 * Same job and same output shape as every other runner here, so results can be
 * compared line for line. The corpus is the authority; a runner that disagrees
 * with it is reporting a defect in its implementation.
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as whoami from '../ref/js/whoami.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CORPUS = join(HERE, 'corpus');

/* Map this implementation's wording to the corpus's canonical token. Each
 * language keeps its own phrasing; only the token has to agree. */
const TOKENS = [
  ['empty', 'empty'],
  ['preamble', 'preamble'],
  ['schema', 'schema'],
  ['special', 'special'],
  ['exceeded', 'bounds'],
];

function canonical(message) {
  for (const [needle, token] of TOKENS) {
    if (message.includes(needle)) return token;
  }
  return `unmapped:${message}`;
}

function loadExpect(path) {
  const out = new Map();
  for (const raw of readFileSync(path, 'utf8').split('\n')) {
    if (!raw || raw.startsWith('#')) continue;
    const eq = raw.indexOf('=');   // FIRST equals: a label may contain a space
    if (eq < 0) continue;
    out.set(raw.slice(0, eq), raw.slice(eq + 1));
  }
  return out;
}

function check(name) {
  const bytes = readFileSync(join(CORPUS, `${name}.report`));
  const expect = loadExpect(join(CORPUS, `${name}.expect`));
  const problems = [];
  let report = null;
  let status = 'ok';

  try {
    report = whoami.parse(new Uint8Array(bytes));
  } catch (err) {
    if (!(err instanceof whoami.WhoamiError)) throw err;
    status = 'error';
    const got = canonical(err.message);
    if (expect.get('status') !== 'error') {
      problems.push(`threw ${JSON.stringify(err.message)} but the case expects a successful read`);
    } else if (expect.has('error') && got !== expect.get('error')) {
      problems.push(`error token ${JSON.stringify(got)}, corpus says ${JSON.stringify(expect.get('error'))}`);
    }
  }

  if (expect.get('status') === 'error' && status === 'ok') {
    problems.push('read succeeded, but this case exists to be refused');
  }

  if (report !== null) {
    for (const [key, want] of [...expect.entries()].sort()) {
      if (key === 'status' || key === 'error') continue;
      if (key.startsWith('field.')) {
        const label = key.slice('field.'.length);
        const got = report.get(label);
        if (got !== want) {
          problems.push(`field ${JSON.stringify(label)} is ${JSON.stringify(got)}, corpus says ${JSON.stringify(want)}`);
        }
      } else if (key === 'major' && String(report.major) !== want) {
        problems.push(`major ${report.major}, corpus says ${want}`);
      } else if (key === 'revision' && String(report.revision) !== want) {
        problems.push(`revision ${report.revision}, corpus says ${want}`);
      } else if (key === 'speaks') {
        const got = report.speaks.join(' ');
        if (got !== want) problems.push(`speaks ${JSON.stringify(got)}, corpus says ${JSON.stringify(want)}`);
      } else if (key === 'refusal') {
        const got = report.refusal ? 'true' : 'false';
        if (got !== want) problems.push(`refusal ${got}, corpus says ${want}`);
      } else if (key === 'blocks' && String(report.specialBlocks) !== want) {
        problems.push(`blocks ${report.specialBlocks}, corpus says ${want}`);
      }
    }
  }
  return problems;
}

const names = readFileSync(join(CORPUS, 'INDEX'), 'utf8')
  .split('\n').filter((n) => n.trim().length > 0);
let bad = 0;
for (const name of names) {
  const problems = check(name);
  if (problems.length > 0) bad++;
  console.log(`  ${(problems.length ? 'FAIL' : 'ok').padEnd(4)} ${name}`);
  for (const problem of problems) console.log(`        ${problem}`);
}
console.log(`\n  javascript: ${names.length} cases, ${bad} failed`);
process.exit(bad ? 1 : 0);
