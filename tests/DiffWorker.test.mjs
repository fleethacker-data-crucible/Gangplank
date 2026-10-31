// node --test tests/DiffWorker.test.mjs
// The line diff behind the Changes tab's "View changes" (web/diff-worker.js). The same file
// runs in a Web Worker in the browser; here it is loaded as a plain CommonJS module.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const { computeDiff, handleMessage, LIMITS } = require(path.join(here, '../web/diff-worker.js'));

const WHOLE = { context: 1e9 };   // one hunk with every line, to check the result against both inputs
const rows = (r) => r.hunks.flatMap((h) => h.lines);
const rebuild = (r, keep) => rows(r).filter((l) => keep.includes(l.t)).map((l) => l.text);
const lines = (text) => (text === '' ? [] : text.replace(/\r\n/g, '\n').replace(/\n$/, '').split('\n'));

function lcsLength(a, b) {
  let prev = new Array(b.length + 1).fill(0);
  for (let i = 1; i <= a.length; i++) {
    const cur = new Array(b.length + 1).fill(0);
    for (let j = 1; j <= b.length; j++) cur[j] = a[i - 1] === b[j - 1] ? prev[j - 1] + 1 : Math.max(prev[j], cur[j - 1]);
    prev = cur;
  }
  return prev[b.length];
}

test('identical text has no hunks', () => {
  const r = computeDiff('a\nb\nc\n', 'a\nb\nc\n');
  assert.equal(r.tooLarge, false);
  assert.deepEqual(r.hunks, []);
  assert.equal(r.stats.added, 0);
  assert.equal(r.stats.removed, 0);
  assert.equal(r.stats.endingsOnly, false);
  assert.deepEqual(computeDiff('', '').hunks, []);
});

test('a changed line becomes one removal and one addition, with line numbers on both sides', () => {
  const r = computeDiff('one\ntwo\nthree\n', 'one\nTWO\nthree\n');
  assert.equal(r.hunks.length, 1);
  assert.deepEqual(r.hunks[0].lines.map((l) => [l.t, l.text, l.a, l.b]), [
    [' ', 'one', 1, 1], ['-', 'two', 2, 0], ['+', 'TWO', 0, 2], [' ', 'three', 3, 3],
  ]);
  assert.deepEqual([r.hunks[0].aStart, r.hunks[0].aCount, r.hunks[0].bStart, r.hunks[0].bCount], [1, 3, 1, 3]);
  assert.deepEqual([r.stats.added, r.stats.removed, r.stats.unchanged, r.stats.hunks], [1, 1, 2, 1]);
});

test('new file, deleted file, empty on both sides', () => {
  const added = computeDiff('', 'x\ny\n');
  assert.deepEqual(rows(added).map((l) => l.t + l.text), ['+x', '+y']);
  assert.equal(added.stats.added, 2);
  const removed = computeDiff('x\ny\n', '');
  assert.deepEqual(rows(removed).map((l) => l.t + l.text), ['-x', '-y']);
  assert.equal(removed.stats.beforeLines, 2);
  assert.equal(removed.stats.afterLines, 0);
});

test('insertion at the start, middle and end; a repeated line does not confuse the match', () => {
  assert.deepEqual(rows(computeDiff('b\nc\n', 'a\nb\nc\n', WHOLE)).map((l) => l.t + l.text), ['+a', ' b', ' c']);
  assert.deepEqual(rows(computeDiff('a\nc\n', 'a\nb\nc\n', WHOLE)).map((l) => l.t + l.text), [' a', '+b', ' c']);
  assert.deepEqual(rows(computeDiff('a\nb\n', 'a\nb\nc\n', WHOLE)).map((l) => l.t + l.text), [' a', ' b', '+c']);
  const r = computeDiff('x\nx\nx\n', 'x\nx\nx\nx\n', WHOLE);
  assert.equal(r.stats.added, 1);
  assert.equal(r.stats.removed, 0);
});

test('distant changes make separate hunks, close ones merge (3 lines of context)', () => {
  const base = Array.from({ length: 40 }, (_, i) => 'line ' + (i + 1));
  const far = base.slice(); far[2] = 'changed A'; far[35] = 'changed B';
  const r = computeDiff(base.join('\n') + '\n', far.join('\n') + '\n');
  assert.equal(r.hunks.length, 2);
  assert.deepEqual([r.hunks[0].aStart, r.hunks[0].aCount], [1, 6]);        // lines 1-6: 2 before the change is clipped by the start
  assert.deepEqual([r.hunks[1].aStart, r.hunks[1].aCount], [33, 7]);       // 3 before and 3 after line 36
  const near = base.slice(); near[10] = 'changed A'; near[16] = 'changed B';   // 5 unchanged lines between: merged
  assert.equal(computeDiff(base.join('\n') + '\n', near.join('\n') + '\n').hunks.length, 1);
  const apart = base.slice(); apart[10] = 'changed A'; apart[18] = 'changed B';  // 7 unchanged lines between: split
  assert.equal(computeDiff(base.join('\n') + '\n', apart.join('\n') + '\n').hunks.length, 2);
});

test('line endings: CRLF vs LF is the same text; only-endings changes are reported as such', () => {
  const same = computeDiff('a\r\nb\r\n', 'a\r\nb\r\n');
  assert.equal(same.stats.endingsOnly, false);
  assert.equal(same.stats.eolBefore, 'crlf');
  const eol = computeDiff('a\r\nb\r\n', 'a\nb\n');
  assert.deepEqual(eol.hunks, []);
  assert.equal(eol.stats.endingsOnly, true);
  assert.equal(eol.stats.eolBefore, 'crlf');
  assert.equal(eol.stats.eolAfter, 'lf');
  const final = computeDiff('a\nb', 'a\nb\n');
  assert.equal(final.stats.endingsOnly, true, 'a missing final newline is a change');
  const mixed = computeDiff('a\r\nb\n', 'a\r\nb\n');
  assert.equal(mixed.stats.eolBefore, 'mixed');
  // Display text never carries a \r.
  assert.ok(!rows(computeDiff('a\r\nb\r\n', 'a\r\nc\r\n')).some((l) => l.text.includes('\r')));
});

test('text is passed through untouched (markers, tabs, unicode, html-looking text)', () => {
  const odd = ['+ looks like an addition', '- looks like a removal', '\tindented\ttab', 'café ✓ 🚀', '<img src=x onerror=alert(1)>', ''];
  const r = computeDiff('', odd.join('\n') + '\n');
  assert.deepEqual(rows(r).map((l) => l.text), odd);
  assert.ok(rows(r).every((l) => l.t === '+'));
});

test('the result rebuilds both inputs and is a shortest edit script (fuzz against an LCS table)', () => {
  let seed = 12345;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  for (let round = 0; round < 400; round++) {
    const alphabet = 1 + rnd(5);
    const make = (n) => Array.from({ length: n }, () => 'k' + rnd(alphabet));
    const a = make(rnd(30));
    const b = rnd(2) ? make(rnd(30)) : a.map((x) => (rnd(4) === 0 ? 'k' + rnd(alphabet + 2) : x)).filter(() => rnd(8) !== 0);
    const before = a.length ? a.join('\n') + '\n' : '', after = b.length ? b.join('\n') + '\n' : '';
    const r = computeDiff(before, after, WHOLE);
    assert.deepEqual(rebuild(r, [' ', '-']), a, 'before rebuilt, round ' + round);
    assert.deepEqual(rebuild(r, [' ', '+']), b, 'after rebuilt, round ' + round);
    assert.equal(r.stats.added + r.stats.removed, a.length + b.length - 2 * lcsLength(a, b), 'shortest script, round ' + round);
    // Line numbers count up on their own side.
    let na = 0, nb = 0;
    for (const l of rows(r)) {
      if (l.t !== '+') assert.equal(l.a, ++na);
      if (l.t !== '-') assert.equal(l.b, ++nb);
    }
  }
});

test('big files with small edits are fast (prefix and suffix are skipped)', () => {
  const base = Array.from({ length: 19000 }, (_, i) => 'row ' + i + ' ' + 'x'.repeat(8));
  const edited = base.slice(); edited[9000] = 'edited'; edited.splice(15000, 0, 'inserted');
  const t0 = Date.now();
  const r = computeDiff(base.join('\n') + '\n', edited.join('\n') + '\n');
  assert.ok(Date.now() - t0 < 2000, 'took ' + (Date.now() - t0) + ' ms');
  assert.equal(r.tooLarge, false);
  assert.equal(r.stats.added, 2);
  assert.equal(r.stats.removed, 1);
  assert.equal(r.hunks.length, 2);
});

test('size guard: too many lines, too many characters, too many differences', () => {
  const many = Array.from({ length: LIMITS.maxLines + 1 }, (_, i) => 'l' + i).join('\n');
  const tl = computeDiff(many, 'x');
  assert.equal(tl.tooLarge, true);
  assert.equal(tl.reason, 'lines');
  assert.match(tl.message, /too large to show/i);
  assert.deepEqual(tl.hunks, []);
  const big = 'a'.repeat(LIMITS.maxChars + 1);
  const tc = computeDiff(big, 'x');
  assert.equal(tc.tooLarge, true);
  assert.equal(tc.reason, 'size');
  assert.equal(computeDiff('x', big).tooLarge, true);
  // Nothing in common and more differences than the budget allows.
  const a = Array.from({ length: 400 }, (_, i) => 'a' + i).join('\n');
  const b = Array.from({ length: 400 }, (_, i) => 'b' + i).join('\n');
  const td = computeDiff(a, b, { maxEdits: 100 });
  assert.equal(td.tooLarge, true);
  assert.equal(td.reason, 'changes');
  assert.equal(td.stats.beforeLines, 400);
  assert.equal(computeDiff(a, b).tooLarge, false, 'within the default budget it still works');
  // Exactly at the limits is allowed.
  assert.equal(computeDiff('x\n'.repeat(LIMITS.maxLines), 'x\n'.repeat(LIMITS.maxLines)).tooLarge, false);
});

test('worker protocol: type/id in, result or error out', () => {
  const ok = handleMessage({ type: 'diff', id: 41, before: 'a\n', after: 'b\n' });
  assert.equal(ok.type, 'result');
  assert.equal(ok.id, 41);
  assert.equal(ok.stats.added, 1);
  assert.ok(Array.isArray(ok.hunks));
  const tooBig = handleMessage({ type: 'diff', id: 42, before: 'a'.repeat(LIMITS.maxChars + 1), after: '' });
  assert.equal(tooBig.type, 'result');
  assert.equal(tooBig.tooLarge, true);
  assert.equal(tooBig.id, 42);
  const bad = handleMessage({ type: 'other', id: 43 });
  assert.equal(bad.type, 'error');
  assert.equal(bad.id, 43);
  assert.equal(handleMessage(null).type, 'error');
  // Missing text is treated as empty rather than crashing the worker.
  assert.equal(handleMessage({ type: 'diff', id: 44 }).stats.added, 0);
});
