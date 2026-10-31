// node --test dev/fake-gitlab.test.mjs
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startFakeGitLab, DEFAULT_TOKEN } from './fake-gitlab.mjs';
import { crc32 } from './fake-github.mjs';

const PROJECT = 'gangplank-demo/sample';
const P = `/api/v4/projects/${encodeURIComponent(PROJECT)}`; // gangplank-demo%2Fsample
let fake;

before(async () => { fake = await startFakeGitLab({ port: 0 }); });
after(async () => { await fake?.close(); });
beforeEach(async () => { await fetch(`${fake.url}/__fake/reset`, { method: 'POST' }); });

async function api(method, path, body, { token = DEFAULT_TOKEN, raw = false, headers = {} } = {}) {
  const h = { ...headers };
  if (token) h['PRIVATE-TOKEN'] = token;
  if (body !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${fake.url}${path}`, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
  if (raw) return res;
  const text = await res.text();
  let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: res.status, headers: res.headers, json, text };
}
const control = async (method, path, body) => (await fetch(`${fake.url}${path}`, {
  method, headers: { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body),
})).json();

const enc = (s) => encodeURIComponent(s);
const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');
const head = async (branch) => (await api('GET', `${P}/repository/branches/${enc(branch)}`)).json.commit.id;
const fileMeta = async (path, ref = 'main') => (await api('GET', `${P}/repository/files/${enc(path)}?ref=${enc(ref)}`)).json;
const commit = (body) => api('POST', `${P}/repository/commits`, { commit_message: 'test', ...body });

function unzip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  assert.ok(eocd >= 0, 'EOCD present');
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const out = new Map();
  for (let i = 0; i < count; i++) {
    assert.equal(buf.readUInt32LE(p), 0x02014b50, 'central header signature');
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const csize = buf.readUInt32LE(p + 20);
    const usize = buf.readUInt32LE(p + 24);
    const nlen = buf.readUInt16LE(p + 28);
    const xlen = buf.readUInt16LE(p + 30);
    const clen = buf.readUInt16LE(p + 32);
    const external = buf.readUInt32LE(p + 38);
    const off = buf.readUInt32LE(p + 42);
    const name = buf.subarray(p + 46, p + 46 + nlen).toString('utf8');
    const lstart = off + 30 + buf.readUInt16LE(off + 26) + buf.readUInt16LE(off + 28);
    const comp = buf.subarray(lstart, lstart + csize);
    const data = method === 8 ? inflateRawSync(comp) : Buffer.from(comp);
    assert.equal(data.length, usize, `size of ${name}`);
    assert.equal(crc32(data), crc, `crc of ${name}`);
    out.set(name, { data, unixMode: external >>> 16 });
    p += 46 + nlen + xlen + clen;
  }
  return out;
}

test('auth: PRIVATE-TOKEN is required (401), unknown project is 404, paths must be encoded', async () => {
  assert.equal((await api('GET', P, undefined, { token: null })).status, 401);
  const wrong = await api('GET', P, undefined, { token: 'wrong' });
  assert.equal(wrong.status, 401);
  assert.equal(wrong.json.message, '401 Unauthorized');
  assert.equal((await api('GET', `${P}/repository/branches`, undefined, { token: 'wrong' })).status, 401);
  const bearer = await fetch(`${fake.url}${P}`, { headers: { Authorization: `Bearer ${DEFAULT_TOKEN}` } });
  await bearer.text();
  assert.equal(bearer.status, 200, 'a personal access token also works as a bearer token, as on GitLab');

  const ok = await api('GET', P);
  assert.equal(ok.status, 200);
  assert.equal(ok.json.path_with_namespace, PROJECT);
  assert.equal(ok.json.default_branch, 'main');
  assert.equal(ok.json.visibility, 'private');
  assert.match(ok.json.web_url, /gangplank-demo\/sample$/);
  assert.equal((await api('GET', `/api/v4/projects/${ok.json.id}`)).json.path_with_namespace, PROJECT, 'numeric id works');
  const missing = await api('GET', `/api/v4/projects/${enc('gangplank-demo/nope')}`);
  assert.equal(missing.status, 404);
  assert.equal(missing.json.message, '404 Project Not Found');
  assert.equal((await api('GET', '/api/v4/projects/gangplank-demo/sample')).status, 404, 'a literal slash is not a project path');
  assert.equal((await api('GET', `/api/v4/projects/${enc('GangPlank-Demo/Sample')}`)).status, 200, 'paths are case-insensitive');
  assert.equal((await api('GET', `/api/v4/projects/${enc('gangplank-demo/team/nested-app')}`)).json.visibility, 'internal', 'nested group path');
  assert.equal((await api('GET', `/api/v4/projects/${enc('gangplank-demo/public-site')}`)).json.visibility, 'public');
  const empty = await api('GET', `/api/v4/projects/${enc('gangplank-demo/empty')}`);
  assert.equal(empty.json.default_branch, null);
  assert.equal(empty.json.empty_repo, true);
  assert.equal((await api('GET', '/api/v4/user')).json.username, 'fake-gangplank-user');
});

test('branches paginate with Link, X-Next-Page and X-Total-Pages', async () => {
  const big = await startFakeGitLab({ port: 0, extraBranches: 120 });
  try {
    const get = async (page) => {
      const res = await fetch(`${big.url}${P}/repository/branches?per_page=100&page=${page}`, { headers: { 'PRIVATE-TOKEN': big.token } });
      return { body: await res.json(), h: res.headers };
    };
    const p1 = await get(1);
    assert.equal(p1.body.length, 100);
    assert.match(p1.h.get('link'), /<[^>]*[?&]page=2[^>]*>; rel="next"/);
    assert.match(p1.h.get('link'), /rel="last"/);
    assert.equal(p1.h.get('x-next-page'), '2');
    assert.equal(p1.h.get('x-total'), '123');
    assert.equal(p1.h.get('x-total-pages'), '2');
    assert.equal(p1.h.get('x-per-page'), '100');
    const p2 = await get(2);
    assert.equal(p2.body.length, 23);
    assert.doesNotMatch(p2.h.get('link'), /rel="next"/);
    assert.equal(p2.h.get('x-next-page'), '', 'GitLab sends an empty X-Next-Page on the last page');
    assert.equal(p2.h.get('x-prev-page'), '1');
    const names = [...p1.body, ...p2.body].map((b) => b.name);
    assert.equal(new Set(names).size, 123);
    assert.ok(names.includes('feature/demo'));
  } finally { await big.close(); }
  const small = await api('GET', `${P}/repository/branches?per_page=2&page=1`);
  assert.equal(small.json.length, 2);
  assert.equal(small.headers.get('x-next-page'), '2');
  const dflt = await api('GET', `${P}/repository/branches`);
  assert.equal(dflt.headers.get('x-per-page'), '20', 'GitLab pages by 20 unless asked');
  const found = await api('GET', `${P}/repository/branches?search=release`);
  assert.deepEqual(found.json.map((b) => b.name), ['release/2026.10']);
});

test('one branch: encoded slash, default flag, commit id; 404 for a missing branch', async () => {
  const main = await api('GET', `${P}/repository/branches/main`);
  assert.equal(main.status, 200);
  assert.equal(main.json.name, 'main');
  assert.equal(main.json.default, true);
  assert.match(main.json.commit.id, /^[0-9a-f]{40}$/);
  const feature = await api('GET', `${P}/repository/branches/${enc('feature/demo')}`);
  assert.equal(feature.status, 200);
  assert.equal(feature.json.default, false);
  assert.notEqual(feature.json.commit.id, main.json.commit.id);
  assert.equal((await api('GET', `${P}/repository/branches/feature/demo`)).json.name, 'feature/demo', 'literal slash accepted too');
  const miss = await api('GET', `${P}/repository/branches/${enc('does-not-exist')}`);
  assert.equal(miss.status, 404);
  assert.equal(miss.json.message, '404 Branch Not Found');
});

test('create branch from a branch or a sha; duplicates and bad refs are 400', async () => {
  const main = await head('main');
  const created = await api('POST', `${P}/repository/branches`, { branch: 'gangplank/work-1', ref: 'main' });
  assert.equal(created.status, 201);
  assert.equal(created.json.name, 'gangplank/work-1');
  assert.equal(created.json.commit.id, main);
  assert.equal(await head('gangplank/work-1'), main);
  const bySha = await api('POST', `${P}/repository/branches?branch=from-sha&ref=${main}`);
  assert.equal(bySha.status, 201, 'GitLab also takes the parameters in the query string');
  const dup = await api('POST', `${P}/repository/branches`, { branch: 'gangplank/work-1', ref: 'main' });
  assert.equal(dup.status, 400);
  assert.equal(dup.json.message, 'Branch already exists');
  assert.equal((await api('POST', `${P}/repository/branches`, { branch: 'x', ref: 'no-such-ref' })).status, 400);
  assert.equal((await api('POST', `${P}/repository/branches`, { branch: 'bad..name', ref: 'main' })).status, 400);
  const noRef = await api('POST', `${P}/repository/branches`, { branch: 'x' });
  assert.equal(noRef.status, 400);
  assert.equal(noRef.json.error, 'ref is missing');
});

test('archive.zip is a real zip with GitLab\'s top-level folder and the executable mode', async () => {
  const sha = await head('main');
  const res = await api('GET', `${P}/repository/archive.zip?sha=${sha}`, undefined, { raw: true });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'application/zip');
  const entries = unzip(Buffer.from(await res.arrayBuffer()));
  const top = `sample-${sha}-${sha}/`;
  assert.ok([...entries.keys()].every((n) => n.startsWith(top)), 'single top-level folder');
  assert.ok(entries.has(top));
  for (const f of ['README.md', 'src/app.ps1', 'scripts/build.sh', 'docs/guide.md']) assert.ok(entries.has(`${top}${f}`), f);
  assert.ok(entries.has(`${top}scripts/`) && entries.has(`${top}src/`), 'directory entries');
  assert.ok(!entries.has(`${top}src/demo.ps1`), 'main does not have the feature file');
  assert.equal(entries.get(`${top}scripts/build.sh`).unixMode & 0o777, 0o755);
  assert.deepEqual(entries.get(`${top}README.md`).data, Buffer.from((await (await api('GET', `${P}/repository/files/README.md/raw?ref=main`, undefined, { raw: true })).arrayBuffer())));
  // A branch name works too, and the folder carries it ('/' becomes '-').
  const feature = unzip(Buffer.from(await (await api('GET', `${P}/repository/archive.zip?sha=${enc('feature/demo')}`, undefined, { raw: true })).arrayBuffer()));
  assert.ok([...feature.keys()].some((n) => /^sample-feature-demo-[0-9a-f]{40}\/src\/demo\.ps1$/.test(n)));
  assert.equal((await api('GET', `${P}/repository/archive.zip?sha=nope`)).status, 404);
  assert.equal((await api('GET', `${P}/repository/archive.zip?sha=${sha}`, undefined, { token: 'wrong' })).status, 401);
});

test('files: metadata with last_commit_id and base64 content; raw bytes; ref is required', async () => {
  const meta = await fileMeta('docs/guide.md', 'feature/demo');
  assert.equal(meta.file_path, 'docs/guide.md');
  assert.equal(meta.encoding, 'base64');
  assert.match(meta.last_commit_id, /^[0-9a-f]{40}$/);
  const text = Buffer.from(meta.content, 'base64').toString('utf8');
  assert.match(text, /4\. Open a review\./);
  assert.equal(meta.size, Buffer.byteLength(text));
  assert.equal(meta.content_sha256, createHash('sha256').update(text).digest('hex'));
  assert.equal(meta.commit_id, await head('feature/demo'));
  assert.equal(meta.last_commit_id, meta.commit_id, 'feature/demo last touched the guide itself');
  // README was last changed by the first commit, whichever branch tip is asked for.
  const readme = await fileMeta('README.md', 'main');
  assert.notEqual(readme.last_commit_id, readme.commit_id);
  assert.equal(readme.last_commit_id, (await fileMeta('README.md', 'feature/demo')).last_commit_id);
  assert.equal((await fileMeta('scripts/build.sh')).execute_filemode, true);
  const raw = await api('GET', `${P}/repository/files/${enc('src/app.ps1')}/raw?ref=main`);
  assert.equal(raw.status, 200);
  assert.equal(raw.text, "Write-Output 'Hello from the sample app'\n");
  assert.equal(raw.headers.get('x-gitlab-last-commit-id'), (await fileMeta('src/app.ps1')).last_commit_id);
  const noRef = await api('GET', `${P}/repository/files/README.md`);
  assert.equal(noRef.status, 400);
  assert.equal(noRef.json.error, 'ref is missing');
  const missing = await api('GET', `${P}/repository/files/nope.txt?ref=main`);
  assert.equal(missing.status, 404);
  assert.equal(missing.json.message, '404 File Not Found');
  assert.equal((await api('GET', `${P}/repository/files/README.md?ref=nope`)).status, 404);
});

test('commits POST: create, update and delete with base64, one atomic commit', async () => {
  await api('POST', `${P}/repository/branches`, { branch: 'work', ref: 'main' });
  const before = await head('work');
  const readme = await fileMeta('README.md', 'work');
  const res = await commit({
    branch: 'work', commit_message: 'Add notes, edit readme, drop app',
    actions: [
      { action: 'create', file_path: 'notes/n.md', content: b64('# Notes\n'), encoding: 'base64' },
      { action: 'update', file_path: 'README.md', content: b64('# Sample\n\nEdited.\n'), encoding: 'base64', last_commit_id: readme.last_commit_id },
      { action: 'delete', file_path: 'src/app.ps1', last_commit_id: (await fileMeta('src/app.ps1', 'work')).last_commit_id },
    ],
  });
  assert.equal(res.status, 201, res.text);
  assert.match(res.json.id, /^[0-9a-f]{40}$/);
  assert.equal(res.json.short_id, res.json.id.slice(0, 8));
  assert.deepEqual(res.json.parent_ids, [before]);
  assert.equal(res.json.title, 'Add notes, edit readme, drop app');
  assert.equal(await head('work'), res.json.id);
  assert.equal(await head('main'), (await api('GET', `${P}/repository/branches/main`)).json.commit.id, 'main untouched');
  assert.equal(Buffer.from((await fileMeta('notes/n.md', 'work')).content, 'base64').toString(), '# Notes\n');
  assert.equal(Buffer.from((await fileMeta('README.md', 'work')).content, 'base64').toString(), '# Sample\n\nEdited.\n');
  assert.equal((await api('GET', `${P}/repository/files/${enc('src/app.ps1')}?ref=work`)).status, 404);
  assert.equal((await fileMeta('README.md', 'work')).last_commit_id, res.json.id);
  assert.equal((await fileMeta('docs/guide.md', 'work')).last_commit_id, (await fileMeta('docs/guide.md', 'main')).last_commit_id, 'untouched files keep their last commit');
  // Plain text encoding is the default, and non-ASCII survives.
  const text = await commit({ branch: 'work', actions: [{ action: 'create', file_path: 'café.txt', content: 'café ✓\n' }] });
  assert.equal(text.status, 201, text.text);
  assert.equal(Buffer.from((await fileMeta('café.txt', 'work')).content, 'base64').toString('utf8'), 'café ✓\n');
});

test('commits POST: a file that changed since last_commit_id is rejected (400) and nothing is written', async () => {
  await api('POST', `${P}/repository/branches`, { branch: 'work', ref: 'main' });
  const stale = (await fileMeta('README.md', 'work')).last_commit_id;
  const guide = (await fileMeta('docs/guide.md', 'work')).last_commit_id;
  await control('POST', '/__fake/advance', { branch: 'work', path: 'README.md', content: '# Teammate changed this\n' });
  const tip = await head('work');
  const res = await commit({
    branch: 'work',
    actions: [
      { action: 'update', file_path: 'docs/guide.md', content: b64('new guide\n'), encoding: 'base64', last_commit_id: guide },
      { action: 'update', file_path: 'README.md', content: b64('mine\n'), encoding: 'base64', last_commit_id: stale },
      { action: 'create', file_path: 'extra.txt', content: b64('x'), encoding: 'base64' },
    ],
  });
  assert.equal(res.status, 400);
  assert.match(res.json.message, /changed since you started editing it/);
  assert.equal(await head('work'), tip, 'a rejected commit must not move the branch');
  assert.equal((await api('GET', `${P}/repository/files/extra.txt?ref=work`)).status, 404, 'the other actions must not be applied');
  assert.notEqual(Buffer.from((await fileMeta('docs/guide.md', 'work')).content, 'base64').toString(), 'new guide\n');
  // Delete is guarded the same way.
  const del = await commit({ branch: 'work', actions: [{ action: 'delete', file_path: 'README.md', last_commit_id: stale }] });
  assert.equal(del.status, 400);
  // The fresh id is accepted, and a commit elsewhere in the tree does not make other files stale.
  await control('POST', '/__fake/advance', { branch: 'work', path: 'unrelated.txt', content: 'other file\n' });
  const ok = await commit({ branch: 'work', actions: [{ action: 'update', file_path: 'docs/guide.md', content: b64('new guide\n'), encoding: 'base64', last_commit_id: guide }] });
  assert.equal(ok.status, 201, ok.text);
  const fresh = (await fileMeta('README.md', 'work')).last_commit_id;
  assert.notEqual(fresh, stale);
  assert.equal((await commit({ branch: 'work', actions: [{ action: 'update', file_path: 'README.md', content: b64('mine\n'), encoding: 'base64', last_commit_id: fresh }] })).status, 201);
  // Without last_commit_id GitLab does not guard (that is why Gangplank always sends it).
  assert.equal((await commit({ branch: 'work', actions: [{ action: 'update', file_path: 'README.md', content: b64('again\n'), encoding: 'base64' }] })).status, 201);
});

test('commits POST: validation (existing file, missing file, branch, parameters, UTF-8)', async () => {
  await api('POST', `${P}/repository/branches`, { branch: 'work', ref: 'main' });
  const create = (file_path) => commit({ branch: 'work', actions: [{ action: 'create', file_path, content: 'x' }] });
  assert.match((await create('README.md')).json.message, /already exists/);
  assert.match((await commit({ branch: 'work', actions: [{ action: 'update', file_path: 'nope.txt', content: 'x' }] })).json.message, /doesn't exist/);
  assert.match((await commit({ branch: 'work', actions: [{ action: 'delete', file_path: 'nope.txt' }] })).json.message, /doesn't exist/);
  assert.equal((await commit({ branch: 'no-such-branch', actions: [{ action: 'create', file_path: 'a.txt', content: 'x' }] })).status, 400);
  assert.equal((await commit({ branch: 'work', actions: [{ action: 'create', file_path: '../a.txt', content: 'x' }] })).status, 400);
  assert.equal((await commit({ branch: 'work', actions: [{ action: 'explode', file_path: 'a.txt' }] })).status, 400);
  assert.equal((await commit({ branch: 'work', actions: [{ action: 'create', file_path: 'a.txt' }] })).json.error, 'actions[0][content] is missing');
  assert.equal((await commit({ branch: 'work', actions: [] })).json.error, 'actions is missing');
  assert.equal((await commit({ actions: [{ action: 'create', file_path: 'a.txt', content: 'x' }] })).json.error, 'branch is missing');
  assert.equal((await api('POST', `${P}/repository/commits`, { branch: 'work', actions: [{ action: 'create', file_path: 'a.txt', content: 'x' }] })).json.error, 'commit_message is missing');
  // start_branch creates the target branch in the same call.
  const fresh = await commit({ branch: 'from-start', start_branch: 'main', actions: [{ action: 'create', file_path: 'a.txt', content: 'x' }] });
  assert.equal(fresh.status, 201, fresh.text);
  assert.equal(fresh.json.parent_ids[0], await head('main'));
  // A body that is not UTF-8 (a Windows PowerShell 5.1 string sent as ISO-8859-1) is refused and logged.
  const bad = await fetch(`${fake.url}${P}/repository/commits`, {
    method: 'POST', headers: { 'PRIVATE-TOKEN': DEFAULT_TOKEN, 'Content-Type': 'application/json' },
    body: Buffer.concat([Buffer.from('{"branch":"work","commit_message":"caf'), Buffer.from([0xe9]), Buffer.from('","actions":[]}')]),
  });
  await bad.text();
  assert.equal(bad.status, 400);
  assert.equal((await control('GET', '/__fake/state')).calls.at(-1).invalidUtf8Body, true);
  // The first commit into an empty project creates its default branch.
  const emptyP = `/api/v4/projects/${enc('gangplank-demo/empty')}`;
  const first = await api('POST', `${emptyP}/repository/commits`, { branch: 'main', commit_message: 'First', actions: [{ action: 'create', file_path: 'README.md', content: '# Empty\n' }] });
  assert.equal(first.status, 201, first.text);
  assert.equal((await api('GET', emptyP)).json.default_branch, 'main');
});

test('file mode: an update without execute_filemode keeps 100755; move works', async () => {
  await api('POST', `${P}/repository/branches`, { branch: 'work', ref: 'main' });
  const sh = await fileMeta('scripts/build.sh', 'work');
  const r = await commit({ branch: 'work', actions: [{ action: 'update', file_path: 'scripts/build.sh', content: b64('#!/bin/sh\necho changed\n'), encoding: 'base64', last_commit_id: sh.last_commit_id }] });
  assert.equal(r.status, 201, r.text);
  assert.equal((await fileMeta('scripts/build.sh', 'work')).execute_filemode, true);
  const mv = await commit({ branch: 'work', actions: [{ action: 'move', file_path: 'docs/handbook.md', previous_path: 'docs/guide.md' }] });
  assert.equal(mv.status, 201, mv.text);
  assert.equal((await api('GET', `${P}/repository/files/${enc('docs/guide.md')}?ref=work`)).status, 404);
  assert.match(Buffer.from((await fileMeta('docs/handbook.md', 'work')).content, 'base64').toString(), /^# Guide/);
});

test('commits GET: newest first for a ref, paged, 20 per page by default', async () => {
  const list = await api('GET', `${P}/repository/commits?ref_name=feature%2Fdemo`);
  assert.equal(list.status, 200);
  assert.deepEqual(list.json.map((c) => c.title), ['Demo: extend guide and add demo script', 'Add build script and guide', 'Initial commit']);
  assert.equal(list.json[0].author_name, 'Demo Contributor');
  assert.equal(list.json[0].id, await head('feature/demo'));
  assert.match(list.json[0].web_url, /\/-\/commit\/[0-9a-f]{40}$/);
  const main = await api('GET', `${P}/repository/commits?ref_name=main&per_page=1&page=2`);
  assert.deepEqual(main.json.map((c) => c.title), ['Initial commit']);
  assert.equal(main.headers.get('x-total'), '2');
  const one = await api('GET', `${P}/repository/commits/${(await head('main')).slice(0, 10)}`);
  assert.equal(one.json.title, 'Add build script and guide');
  const readmeOnly = await api('GET', `${P}/repository/commits?ref_name=feature%2Fdemo&path=${enc('docs/guide.md')}`);
  assert.deepEqual(readmeOnly.json.map((c) => c.title), ['Demo: extend guide and add demo script', 'Add build script and guide']);
});

test('compare: from/to diffs with new_file and deleted_file, and the commits in between', async () => {
  const r = await api('GET', `${P}/repository/compare?from=main&to=${enc('feature/demo')}`);
  assert.equal(r.status, 200);
  const byPath = Object.fromEntries(r.json.diffs.map((d) => [d.new_path, d]));
  assert.equal(byPath['src/demo.ps1'].new_file, true);
  assert.equal(byPath['docs/guide.md'].new_file, false);
  assert.match(byPath['docs/guide.md'].diff, /^@@ /);
  assert.deepEqual(r.json.commits.map((c) => c.title), ['Demo: extend guide and add demo script']);
  assert.equal(r.json.compare_same_ref, false);
  const reverse = await api('GET', `${P}/repository/compare?from=${enc('feature/demo')}&to=main&straight=true`);
  assert.equal(reverse.json.diffs.find((d) => d.new_path === 'src/demo.ps1').deleted_file, true);
  assert.equal(reverse.json.commits.length, 0);
  assert.equal((await api('GET', `${P}/repository/compare?from=main&to=main`)).json.compare_same_ref, true);
  assert.equal((await api('GET', `${P}/repository/compare?from=main&to=nope`)).status, 404);
  assert.equal((await api('GET', `${P}/repository/compare?from=main`)).json.error, 'to is missing');
  // Diverged branches: a plain compare diffs against the merge base, so main's own change is not shown.
  await control('POST', '/__fake/advance', { branch: 'main', path: 'main-only.txt', content: 'x\n' });
  const diverged = await api('GET', `${P}/repository/compare?from=main&to=${enc('feature/demo')}`);
  assert.ok(!diverged.json.diffs.some((d) => d.new_path === 'main-only.txt'));
  assert.equal(diverged.json.commits.length, 1);
});

test('merge requests: list opened, get one, create, duplicates and bad branches', async () => {
  const opened = await api('GET', `${P}/merge_requests?state=opened&per_page=30`);
  assert.equal(opened.status, 200);
  assert.equal(opened.json.length, 1);
  const mr = opened.json[0];
  assert.equal(mr.iid, 1);
  assert.equal(mr.title, 'Demo feature');
  assert.equal(mr.source_branch, 'feature/demo');
  assert.equal(mr.target_branch, 'main');
  assert.equal(mr.author.username, 'demo-contributor');
  assert.match(mr.web_url, /\/-\/merge_requests\/1$/);
  assert.equal((await api('GET', `${P}/merge_requests?state=all`)).json.length, 2);
  assert.equal((await api('GET', `${P}/merge_requests?state=closed`)).json[0].title, 'Old release notes');
  assert.equal((await api('GET', `${P}/merge_requests/1`)).json.iid, 1);
  assert.equal((await api('GET', `${P}/merge_requests/99`)).status, 404);

  await api('POST', `${P}/repository/branches`, { branch: 'work', ref: 'main' });
  const created = await api('POST', `${P}/merge_requests`, { source_branch: 'work', target_branch: 'main', title: 'Review: my work', description: 'Created in a test.' });
  assert.equal(created.status, 201, created.text);
  assert.equal(created.json.iid, 2 + 1);
  assert.equal(created.json.state, 'opened');
  assert.equal(created.json.author.username, 'fake-gangplank-user');
  assert.equal(created.json.description, 'Created in a test.');
  assert.match(created.json.web_url, /\/-\/merge_requests\/3$/);
  assert.equal((await api('GET', `${P}/merge_requests?state=opened`)).json.length, 2);
  const dup = await api('POST', `${P}/merge_requests`, { source_branch: 'work', target_branch: 'main', title: 'Again' });
  assert.equal(dup.status, 409);
  assert.equal((await api('POST', `${P}/merge_requests`, { source_branch: 'ghost', target_branch: 'main', title: 'x' })).status, 400);
  assert.equal((await api('POST', `${P}/merge_requests`, { source_branch: 'main', target_branch: 'main', title: 'x' })).status, 422);
  assert.equal((await api('POST', `${P}/merge_requests`, { source_branch: 'work', target_branch: 'main' })).json.error, 'title is missing');
  const snap = await control('GET', '/__fake/state');
  assert.equal(snap.projects[PROJECT].merge_requests.length, 3);
});

test('fault injection: 429 with Retry-After then success; 502 once; auth still applies after', async () => {
  await control('POST', '/__fake/fail', { method: 'GET', pathContains: '/repository/branches/main', status: 429, times: 2, retryAfter: 1 });
  for (let i = 0; i < 2; i++) {
    const r = await api('GET', `${P}/repository/branches/main`);
    assert.equal(r.status, 429);
    assert.equal(r.headers.get('retry-after'), '1');
  }
  assert.equal((await api('GET', `${P}/repository/branches/main`)).status, 200);
  await control('POST', '/__fake/fail', { pathContains: 'archive.zip', status: 502, times: 1 });
  assert.equal((await api('GET', `${P}/repository/archive.zip?sha=main`)).status, 502);
  assert.equal((await api('GET', `${P}/repository/archive.zip?sha=main`, undefined, { raw: true })).status, 200);
  const state = await control('GET', '/__fake/state');
  assert.equal(state.faults.length, 0);
  assert.ok(state.calls.some((c) => c.fault && c.status === 429));
});

test('advance moves a branch like a teammate; reset restores the seed; calls keep the raw encoded path', async () => {
  const before = await head('main');
  const adv = await control('POST', '/__fake/advance', { branch: 'main', path: 'README.md', content: '# changed\n' });
  assert.equal(adv.parent, before);
  assert.equal(await head('main'), adv.id);
  assert.equal((await fileMeta('README.md')).last_commit_id, adv.id);
  const state = await control('GET', '/__fake/state');
  assert.ok(state.calls.some((c) => c.path.includes('gangplank-demo%2Fsample')), 'the call log keeps %2F');
  assert.equal(state.calls.every((c) => c.auth === 'valid'), true);
  assert.equal(state.projects[PROJECT].branches.main, adv.id);
  await fetch(`${fake.url}/__fake/reset`, { method: 'POST' });
  assert.equal(await head('main'), before, 'the seed SHAs are deterministic');
  assert.equal((await control('GET', '/__fake/state')).calls.length >= 0, true);
  await fetch(`${fake.url}/__fake/calls`, { method: 'DELETE' });
  assert.equal((await control('GET', '/__fake/state')).calls.length, 0);
});

test('hook: a teammate commit lands right after the Nth matching answer', async () => {
  await api('POST', `${P}/repository/branches`, { branch: 'work', ref: 'main' });
  const before = await head('work');
  await control('POST', '/__fake/hook', { method: 'GET', pathContains: '/repository/branches/work', skip: 1, advance: { branch: 'work', path: 'race.txt', content: 'raced\n' } });
  assert.equal(await head('work'), before, 'first matching call is skipped');
  const second = (await api('GET', `${P}/repository/branches/work`)).json.commit.id;
  assert.equal(second, before, 'the matching call itself still sees the old head');
  assert.notEqual(await head('work'), before, 'and the branch has moved by the next call');
});

test('CLI prints one JSON line with url and token', async () => {
  const script = fileURLToPath(new URL('./fake-gitlab.mjs', import.meta.url));
  const child = spawn(process.execPath, [script, '0', '--token=cli-token'], { stdio: ['ignore', 'pipe', 'inherit'] });
  try {
    const line = await new Promise((resolve, reject) => {
      let buf = '';
      child.stdout.on('data', (d) => { buf += d; if (buf.includes('\n')) resolve(buf.split('\n')[0]); });
      child.once('exit', (code) => reject(new Error(`exited ${code}`)));
    });
    const info = JSON.parse(line);
    assert.match(info.url, /^http:\/\/127\.0\.0\.1:\d+$/);
    assert.equal(info.token, 'cli-token');
    const ok = await fetch(`${info.url}${P}`, { headers: { 'PRIVATE-TOKEN': 'cli-token' } });
    await ok.text();
    assert.equal(ok.status, 200);
    const no = await fetch(`${info.url}${P}`, { headers: { 'PRIVATE-TOKEN': DEFAULT_TOKEN } });
    await no.text();
    assert.equal(no.status, 401);
  } finally { child.kill(); }
});
