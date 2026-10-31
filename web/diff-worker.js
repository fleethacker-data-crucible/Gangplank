// Gangplank line diff, run in a dedicated worker so a large file never freezes the page.
// One pure function (computeDiff) serves three callers: this worker, the page itself if
// Worker creation is blocked (it loads this file as a plain script), and the node tests
// (require). No dependencies, no DOM, no build step.
//
// Worker protocol:
//   page   -> worker  { type:'diff', id, before, after }
//   worker -> page    { type:'result', id, tooLarge, hunks, stats }       (see computeDiff)
//                     { type:'error', id, message }
'use strict';
(function () {
 const LIMITS = {
  maxChars: 524288,   // per side; the host already refuses more than 512 KB of text
  maxLines: 20000,    // per side
  maxEdits: 3000,     // Myers edit distance; beyond this the two texts are too different to compare line by line
  context: 3          // unchanged lines kept around each change
 };

 // "a\r\nb\n" -> lines ['a','b'], CRLF endings, final newline. Lines never keep their \r.
 function splitLines(text) {
  if (text === '') return { lines: [], eol: 'none', finalNewline: false };
  let crlf = 0, lf = 0;
  for (let i = text.indexOf('\n'); i !== -1; i = text.indexOf('\n', i + 1)) {
   if (i > 0 && text.charCodeAt(i - 1) === 13) crlf++; else lf++;
  }
  const finalNewline = text.charCodeAt(text.length - 1) === 10;
  const lines = text.split('\n');
  if (finalNewline) lines.pop();
  const last = finalNewline ? lines.length : lines.length - 1;   // lines before this index ended with \n
  for (let i = 0; i < last; i++) {
   const s = lines[i];
   if (s.length && s.charCodeAt(s.length - 1) === 13) lines[i] = s.slice(0, -1);
  }
  const eol = crlf && lf ? 'mixed' : crlf ? 'crlf' : lf ? 'lf' : 'none';
  return { lines, eol, finalNewline };
 }

 // Shortest edit script (Myers 1986) over integer ids. Returns an array of
 // 0 (same), 1 (added) or 2 (removed) in forward order, or null when more than
 // maxEdits edits would be needed. Memory is O(D^2) in the number of edits D.
 function myers(a, b, maxEdits) {
  const n = a.length, m = b.length;
  if (n === 0) return new Array(m).fill(1);
  if (m === 0) return new Array(n).fill(2);
  const limit = Math.min(n + m, maxEdits);
  const off = limit + 2;
  const v = new Int32Array(2 * off + 3);
  v[off + 1] = 0;
  const trace = [];   // trace[d] = v over k in [-d-1, d+1] before step d
  let found = -1;
  for (let d = 0; d <= limit && found < 0; d++) {
   trace.push(v.slice(off - d - 1, off + d + 2));
   for (let k = -d; k <= d; k += 2) {
    let x;
    if (k === -d || (k !== d && v[off + k - 1] < v[off + k + 1])) x = v[off + k + 1];
    else x = v[off + k - 1] + 1;
    let y = x - k;
    while (x < n && y < m && a[x] === b[y]) { x++; y++; }
    v[off + k] = x;
    if (x >= n && y >= m) { found = d; break; }
   }
  }
  if (found < 0) return null;
  const ops = [];
  let x = n, y = m;
  for (let d = found; d > 0; d--) {
   const prev = trace[d], k = x - y, at = (kk) => prev[kk + d + 1];
   const down = k === -d || (k !== d && at(k - 1) < at(k + 1));
   const prevK = down ? k + 1 : k - 1;
   const prevX = at(prevK), prevY = prevX - prevK;
   const midX = down ? prevX : prevX + 1, midY = down ? prevY + 1 : prevY;
   while (x > midX && y > midY) { x--; y--; ops.push(0); }
   ops.push(down ? 1 : 2);
   x = prevX; y = prevY;
  }
  while (x > 0 && y > 0) { x--; y--; ops.push(0); }
  return ops.reverse();
 }

 function tooLarge(reason, message, stats) {
  return { tooLarge: true, reason, message, hunks: [], stats: stats || {} };
 }

 // computeDiff(before, after[, limits]) ->
 //   { tooLarge:false, hunks:[{aStart,aCount,bStart,bCount,lines:[{t:' '|'+'|'-',text,a,b}]}], stats }
 //   { tooLarge:true, reason:'size'|'lines'|'changes', message, hunks:[], stats }
 // a and b are 1-based line numbers (0 when the line does not exist on that side).
 function computeDiff(before, after, limits) {
  const L = Object.assign({}, LIMITS, limits || {});
  before = typeof before === 'string' ? before : '';
  after = typeof after === 'string' ? after : '';
  if (before.length > L.maxChars || after.length > L.maxChars) {
   return tooLarge('size', 'Too large to show: files above ' + Math.round(L.maxChars / 1024) + ' KB are not compared here.');
  }
  const A = splitLines(before), B = splitLines(after);
  const a = A.lines, b = B.lines;
  const base = { beforeLines: a.length, afterLines: b.length, eolBefore: A.eol, eolAfter: B.eol };
  if (a.length > L.maxLines || b.length > L.maxLines) {
   return tooLarge('lines', 'Too large to show: files above ' + L.maxLines + ' lines are not compared here.', base);
  }
  // Common prefix and suffix are equal by definition; only the middle needs the search.
  let p = 0;
  const min = Math.min(a.length, b.length);
  while (p < min && a[p] === b[p]) p++;
  let s = 0;
  while (s < min - p && a[a.length - 1 - s] === b[b.length - 1 - s]) s++;
  const ids = new Map();
  const id = (line) => { let n = ids.get(line); if (n === undefined) { n = ids.size; ids.set(line, n); } return n; };
  const am = a.slice(p, a.length - s).map(id), bm = b.slice(p, b.length - s).map(id);
  const mid = myers(am, bm, L.maxEdits);
  if (mid === null) return tooLarge('changes', 'Too many differences to compare line by line. Open the file in your editor to compare it.', base);

  const total = p + mid.length + s;
  const ops = new Uint8Array(total);
  for (let i = 0; i < mid.length; i++) ops[p + i] = mid[i];
  const aBefore = new Int32Array(total + 1), bBefore = new Int32Array(total + 1);
  let added = 0, removed = 0;
  for (let i = 0; i < total; i++) {
   aBefore[i + 1] = aBefore[i] + (ops[i] === 1 ? 0 : 1);
   bBefore[i + 1] = bBefore[i] + (ops[i] === 2 ? 0 : 1);
   if (ops[i] === 1) added++; else if (ops[i] === 2) removed++;
  }

  const hunks = [];
  const ctx = L.context;
  let i = 0;
  while (i < total) {
   while (i < total && ops[i] === 0) i++;
   if (i >= total) break;
   const start = Math.max(0, i - ctx);
   let last = i, j = i;
   while (j < total) {
    if (ops[j] !== 0) { last = j; j++; continue; }
    let k = j;
    while (k < total && ops[k] === 0) k++;
    if (k >= total || k - j > 2 * ctx) break;   // a long enough unchanged run ends the hunk
    j = k;
   }
   const end = Math.min(total, last + 1 + ctx);
   const lines = [];
   let aCount = 0, bCount = 0;
   for (let r = start; r < end; r++) {
    const op = ops[r];
    const an = op === 1 ? 0 : aBefore[r] + 1, bn = op === 2 ? 0 : bBefore[r] + 1;
    if (op !== 1) aCount++;
    if (op !== 2) bCount++;
    lines.push({ t: op === 1 ? '+' : op === 2 ? '-' : ' ', text: op === 1 ? b[bBefore[r]] : a[aBefore[r]], a: an, b: bn });
   }
   hunks.push({ aStart: aBefore[start] + 1, aCount, bStart: bBefore[start] + 1, bCount, lines });
   i = last + 1;
  }
  return {
   tooLarge: false,
   hunks,
   stats: Object.assign(base, {
    added, removed, unchanged: total - added - removed, hunks: hunks.length,
    // Same lines but different bytes: only line endings or the final newline changed.
    endingsOnly: added === 0 && removed === 0 && before !== after
   })
  };
 }

 function handleMessage(msg) {
  const id = msg && msg.id;
  if (!msg || msg.type !== 'diff') return { type: 'error', id, message: 'Unknown request.' };
  try {
   const r = computeDiff(msg.before, msg.after);
   r.type = 'result';
   r.id = id;
   return r;
  } catch (e) {
   return { type: 'error', id, message: String((e && e.message) || e) };
  }
 }

 const api = { computeDiff, handleMessage, LIMITS };
 const root = typeof globalThis !== 'undefined' ? globalThis : self;
 if (typeof module !== 'undefined' && module.exports) module.exports = api;
 else root.GangplankDiff = api;
 // Only a worker has importScripts; the page and node never hook onmessage.
 if (typeof importScripts === 'function') root.onmessage = (e) => root.postMessage(handleMessage(e.data));
})();
