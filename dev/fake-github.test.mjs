// node --test dev/fake-github.test.mjs
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startFakeGitHub, crc32, DEFAULT_TOKEN, EMPTY_TREE_SHA } from './fake-github.mjs';

const REPO = 'gangplank-demo/sample';
let fake;

before(async () => { fake = await startFakeGitHub({ port: 0 }); });
after(async () => { await fake?.close(); });
beforeEach(async () => { await fetch(`${fake.url}/__fake/reset`, { method: 'POST' }); });

async function api(method, path, body, { token = DEFAULT_TOKEN, redirect = 'manual', raw = false } = {}) {
  const headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'Gangplank' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const res = await fetch(`${fake.url}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), redirect });
  if (raw) return res;
  const text = await res.text();
  return { status: res.status, headers: res.headers, json: text ? JSON.parse(text) : null };
}
const control = async (method, path, body) => (await fetch(`${fake.url}${path}`, {
  method, headers: { 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body),
})).json();

const refPath = (branch) => branch.split('/').map(encodeURIComponent).join('/');
const headOf = async (branch) => (await api('GET', `/repos/${REPO}/git/ref/heads/${refPath(branch)}`)).json.object.sha;

async function treeMap(treeSha) {
  const r = await api('GET', `/repos/${REPO}/git/trees/${treeSha}?recursive=1`);
  return new Map(r.json.tree.map((e) => [e.path, e]));
}

function unzip(buf) {
  // Parse via the end-of-central-directory record, then each central entry -> local header -> data.
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0; i--) if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  assert.ok(eocd >= 0, 'EOCD present');
  const count = buf.readUInt16LE(eocd + 10);
  const cdSize = buf.readUInt32LE(eocd + 12);
  let p = buf.readUInt32LE(eocd + 16);
  assert.equal(p + cdSize, eocd, 'central directory ends at EOCD');
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
    assert.equal(buf.readUInt32LE(off), 0x04034b50, `local header for ${name}`);
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

test('every /repos call requires the bearer token; unknown repo is 404', async () => {
  const none = await api('GET', `/repos/${REPO}`, undefined, { token: null });
  assert.equal(none.status, 401);
  assert.equal(none.json.message, 'Bad credentials');
  assert.equal((await api('GET', `/repos/${REPO}`, undefined, { token: 'wrong' })).status, 401);
  assert.equal((await api('GET', `/repos/${REPO}/git/ref/heads/main`, undefined, { token: null })).status, 401);
  const ok = await api('GET', `/repos/${REPO}`);
  assert.equal(ok.status, 200);
  assert.equal(ok.json.full_name, REPO);
  assert.equal(ok.json.default_branch, 'main');
  assert.equal(ok.json.private, true);
  assert.equal(ok.json.visibility, 'private');
  assert.match(ok.json.html_url, /gangplank-demo\/sample$/);
  const missing = await api('GET', '/repos/gangplank-demo/nope');
  assert.equal(missing.status, 404);
  assert.equal(missing.json.message, 'Not Found');
  const pub = await api('GET', '/repos/gangplank-demo/public-site');
  assert.equal(pub.json.visibility, 'public');
  assert.equal(pub.json.private, false);
});

test('branches paginate and send Link rel="next" while more remain', async () => {
  const big = await startFakeGitHub({ port: 0, extraBranches: 120 });
  try {
    const get = async (page) => {
      const res = await fetch(`${big.url}/repos/${REPO}/branches?per_page=100&page=${page}`, { headers: { Authorization: `Bearer ${big.token}` } });
      return { body: await res.json(), link: res.headers.get('link') };
    };
    const p1 = await get(1);
    assert.equal(p1.body.length, 100);
    assert.match(p1.link, /<[^>]*[?&]page=2[^>]*>; rel="next"/);
    const p2 = await get(2);
    assert.equal(p2.body.length, 123 - 100); // 120 bulk + main, feature/demo, release/2026.10
    assert.doesNotMatch(p2.link ?? '', /rel="next"/);
    const names = [...p1.body, ...p2.body].map((b) => b.name);
    assert.equal(new Set(names).size, 123);
    assert.ok(names.includes('feature/demo'));
    assert.ok(p1.body.every((b) => /^[0-9a-f]{40}$/.test(b.commit.sha)));
  } finally { await big.close(); }

  const small = await api('GET', `/repos/${REPO}/branches?per_page=2&page=1`);
  assert.equal(small.json.length, 2);
  assert.match(small.headers.get('link'), /rel="next"/);
});

test('ref lookup: 404 for a missing branch, object.sha for a found one, encoded slashes', async () => {
  const miss = await api('GET', `/repos/${REPO}/git/ref/heads/does-not-exist`);
  assert.equal(miss.status, 404);
  assert.equal(miss.json.message, 'Not Found');
  const main = await api('GET', `/repos/${REPO}/git/ref/heads/main`);
  assert.equal(main.status, 200);
  assert.equal(main.json.ref, 'refs/heads/main');
  assert.match(main.json.object.sha, /^[0-9a-f]{40}$/);
  // Branch with a slash: literal and percent-encoded forms both work; %2F inside a segment too.
  const literal = await api('GET', `/repos/${REPO}/git/ref/heads/feature/demo`);
  const encoded = await api('GET', `/repos/${REPO}/git/ref/heads/${refPath('feature/demo')}`);
  const encodedSlash = await api('GET', `/repos/${REPO}/git/ref/heads/feature%2Fdemo`);
  assert.equal(literal.status, 200);
  assert.equal(encoded.json.object.sha, literal.json.object.sha);
  assert.equal(encodedSlash.json.object.sha, literal.json.object.sha);
  assert.notEqual(literal.json.object.sha, main.json.object.sha);
  // Create and read back a branch whose segment needs encoding.
  const created = await api('POST', `/repos/${REPO}/git/refs`, { ref: 'refs/heads/gangplank/work-100%', sha: main.json.object.sha });
  assert.equal(created.status, 201);
  assert.equal((await api('GET', `/repos/${REPO}/git/ref/heads/${refPath('gangplank/work-100%')}`)).json.object.sha, main.json.object.sha);
  const dup = await api('POST', `/repos/${REPO}/git/refs`, { ref: 'refs/heads/gangplank/work-100%', sha: main.json.object.sha });
  assert.equal(dup.status, 422);
  assert.equal(dup.json.message, 'Reference already exists');
});

test('seed stores real git object SHAs and the executable mode', async () => {
  const commit = (await api('GET', `/repos/${REPO}/git/commits/${await headOf('main')}`)).json;
  const files = await treeMap(commit.tree.sha);
  for (const p of ['README.md', 'scripts/build.sh', 'src/app.ps1', 'docs/guide.md']) assert.ok(files.has(p), p);
  assert.equal(files.get('scripts/build.sh').mode, '100755');
  assert.equal(files.get('README.md').mode, '100644');
  assert.equal(files.get('scripts').type, 'tree');
  assert.equal(files.get('scripts').mode, '040000');
  const blob = (await api('GET', `/repos/${REPO}/git/blobs/${files.get('README.md').sha}`)).json;
  const content = Buffer.from(blob.content, 'base64');
  const gitSha = createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${content.length}\0`), content])).digest('hex');
  assert.equal(files.get('README.md').sha, gitSha);
  // Non-recursive listing shows only the top level.
  const top = (await api('GET', `/repos/${REPO}/git/trees/${commit.tree.sha}`)).json.tree.map((e) => e.path).sort();
  assert.deepEqual(top, ['README.md', 'docs', 'scripts', 'src']);
  const empty = await api('POST', `/repos/${REPO}/git/trees`, { tree: [] });
  assert.equal(empty.json.sha, EMPTY_TREE_SHA);
});

test('blob -> tree -> commit -> ref: modify a nested file, delete another, keep 100755', async () => {
  // Same sequence as Invoke-GangplankWorkspaceSave, on a work branch.
  const mainSha = await headOf('main');
  const branch = 'gangplank/work-20261024-abc123';
  assert.equal((await api('POST', `/repos/${REPO}/git/refs`, { ref: `refs/heads/${branch}`, sha: mainSha })).status, 201);
  const head = await headOf(branch);
  const prior = (await api('GET', `/repos/${REPO}/git/commits/${head}`)).json;
  assert.equal(prior.sha, head);

  const newGuide = '# Guide\n\nRewritten by Gangplank.\n';
  const newBuild = '#!/bin/sh\necho "still executable"\n';
  const b1 = await api('POST', `/repos/${REPO}/git/blobs`, { content: Buffer.from(newGuide).toString('base64'), encoding: 'base64' });
  assert.equal(b1.status, 201);
  const b2 = await api('POST', `/repos/${REPO}/git/blobs`, { content: newBuild, encoding: 'utf-8' });
  const b3 = await api('POST', `/repos/${REPO}/git/blobs`, { content: Buffer.from('new nested file\n').toString('base64'), encoding: 'base64' });

  // Mode lookup like GetPathModes: list root, then only the directory containing the path.
  const rootListing = (await api('GET', `/repos/${REPO}/git/trees/${prior.tree.sha}`)).json.tree;
  const scripts = rootListing.find((e) => e.path === 'scripts');
  const scriptsListing = (await api('GET', `/repos/${REPO}/git/trees/${scripts.sha}`)).json.tree;
  assert.equal(scriptsListing.find((e) => e.path === 'build.sh').mode, '100755');

  const tree = await api('POST', `/repos/${REPO}/git/trees`, {
    base_tree: prior.tree.sha,
    tree: [
      { path: 'docs/guide.md', mode: '100644', type: 'blob', sha: b1.json.sha },
      { path: 'scripts/build.sh', mode: '100755', type: 'blob', sha: b2.json.sha },
      { path: 'src/app.ps1', mode: '100644', type: 'blob', sha: null },
      { path: 'src/deep/er/new.txt', mode: '100644', type: 'blob', sha: b3.json.sha },
    ],
  });
  assert.equal(tree.status, 201);
  const commit = await api('POST', `/repos/${REPO}/git/commits`, { message: 'Update guide; remove app', tree: tree.json.sha, parents: [head] });
  assert.equal(commit.status, 201);
  assert.deepEqual(commit.json.parents.map((p) => p.sha), [head]);
  const patch = await api('PATCH', `/repos/${REPO}/git/refs/heads/${refPath(branch)}`, { sha: commit.json.sha, force: false });
  assert.equal(patch.status, 200);
  assert.equal(await headOf(branch), commit.json.sha);
  assert.equal(await headOf('main'), mainSha, 'main untouched');

  const after = await treeMap((await api('GET', `/repos/${REPO}/git/commits/${commit.json.sha}`)).json.tree.sha);
  assert.equal(after.get('docs/guide.md').sha, b1.json.sha);
  assert.equal(after.get('scripts/build.sh').mode, '100755');
  assert.equal(after.get('README.md').sha, (await treeMap(prior.tree.sha)).get('README.md').sha, 'untouched file kept from base_tree');
  assert.ok(!after.has('src/app.ps1'), 'deleted');
  assert.ok(after.has('src'), 'src survives because it still has a child');
  assert.equal(after.get('src/deep/er/new.txt').sha, b3.json.sha);

  // Deleting the last file of a directory removes the directory, as git does.
  const t2 = await api('POST', `/repos/${REPO}/git/trees`, { base_tree: tree.json.sha, tree: [{ path: 'src/deep/er/new.txt', mode: '100644', type: 'blob', sha: null }] });
  assert.ok(!(await treeMap(t2.json.sha)).has('src/deep'));

  const history = await api('GET', `/repos/${REPO}/commits?sha=${encodeURIComponent(branch)}&per_page=30`);
  assert.equal(history.json[0].sha, commit.json.sha);
  assert.equal(history.json[0].commit.message, 'Update guide; remove app');
  assert.ok(history.json[0].commit.author.name);

  const cmp = await api('GET', `/repos/${REPO}/compare/main...${encodeURIComponent(branch)}`);
  assert.equal(cmp.json.ahead_by, 1);
  assert.equal(cmp.json.behind_by, 0);
  const byName = Object.fromEntries(cmp.json.files.map((f) => [f.filename, f.status]));
  assert.equal(byName['src/app.ps1'], 'removed');
  assert.equal(byName['docs/guide.md'], 'modified');
  assert.equal(byName['src/deep/er/new.txt'], 'added');

  const pr = await api('POST', `/repos/${REPO}/pulls`, { title: 'Gangplank save', head: branch, base: 'main', body: '' });
  assert.equal(pr.status, 201);
  assert.equal(pr.json.number, 3);
  assert.match(pr.json.html_url, /\/pull\/3$/);
  const open = (await api('GET', `/repos/${REPO}/pulls?state=open&per_page=30`)).json;
  assert.deepEqual(open.map((p) => p.number), [3, 1]);
  assert.equal(open[1].head.ref, 'feature/demo');
  assert.equal(open[1].base.ref, 'main');
  assert.ok(open[1].user.login);
});

test('non-fast-forward ref updates are rejected unless forced', async () => {
  const main = await headOf('main');
  const work = 'gangplank/nff';
  await api('POST', `/repos/${REPO}/git/refs`, { ref: `refs/heads/${work}`, sha: main });
  const prior = (await api('GET', `/repos/${REPO}/git/commits/${main}`)).json;
  const blob = await api('POST', `/repos/${REPO}/git/blobs`, { content: 'mine\n' });
  const tree = await api('POST', `/repos/${REPO}/git/trees`, { base_tree: prior.tree.sha, tree: [{ path: 'mine.txt', mode: '100644', type: 'blob', sha: blob.json.sha }] });
  const mine = await api('POST', `/repos/${REPO}/git/commits`, { message: 'mine', tree: tree.json.sha, parents: [main] });

  const teammate = await control('POST', '/__fake/advance', { branch: work });
  assert.equal(teammate.parent, main);
  assert.equal(await headOf(work), teammate.sha);

  const rejected = await api('PATCH', `/repos/${REPO}/git/refs/heads/${refPath(work)}`, { sha: mine.json.sha, force: false });
  assert.equal(rejected.status, 422);
  assert.equal(rejected.json.message, 'Update is not a fast forward');
  assert.equal(await headOf(work), teammate.sha, 'ref unchanged');

  // feature/demo is not a descendant of main either.
  const sideways = await api('PATCH', `/repos/${REPO}/git/refs/heads/main`, { sha: await headOf('feature/demo') });
  assert.equal(sideways.status, 200, 'feature/demo descends from main, so this is a fast-forward');
  const back = await api('PATCH', `/repos/${REPO}/git/refs/heads/main`, { sha: main });
  assert.equal(back.status, 422, 'moving backwards is not a fast-forward');

  const forced = await api('PATCH', `/repos/${REPO}/git/refs/heads/${refPath(work)}`, { sha: mine.json.sha, force: true });
  assert.equal(forced.status, 200);
  assert.equal(await headOf(work), mine.json.sha);
  assert.equal((await api('PATCH', `/repos/${REPO}/git/refs/heads/nope`, { sha: main })).status, 422);
});

test('zipball 302s to codeload; codeload needs no auth and serves a valid zip', async () => {
  const head = await headOf('main');
  const redirect = await api('GET', `/repos/${REPO}/zipball/${head}`, undefined, { raw: true });
  assert.equal(redirect.status, 302);
  const location = redirect.headers.get('location');
  assert.ok(location.startsWith(`${fake.url.replace("//127.0.0.1:", "//localhost:")}/_codeload/`), location);
  assert.equal((await api('GET', `/repos/${REPO}/zipball/${head}`, undefined, { token: null })).status, 401, 'API side needs auth');

  const res = await fetch(location); // no Authorization header, as a well-behaved client sends after a redirect
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'application/zip');
  const entries = unzip(Buffer.from(await res.arrayBuffer()));
  const top = `gangplank-demo-sample-${head.slice(0, 7)}/`;
  assert.ok([...entries.keys()].every((n) => n.startsWith(top)), 'single top-level folder');
  assert.ok(entries.has(top));
  const files = await treeMap((await api('GET', `/repos/${REPO}/git/commits/${head}`)).json.tree.sha);
  for (const [path, e] of files) {
    if (e.type !== 'blob') { assert.ok(entries.has(`${top}${path}/`), `dir ${path}`); continue; }
    const blob = (await api('GET', `/repos/${REPO}/git/blobs/${e.sha}`)).json;
    assert.deepEqual(entries.get(`${top}${path}`).data, Buffer.from(blob.content, 'base64'), path);
  }
  assert.equal(entries.get(`${top}scripts/build.sh`).unixMode & 0o777, 0o755);

  let state = await control('GET', '/__fake/state');
  assert.equal(state.codeload.calls, 1);
  assert.equal(state.codeload.authorizationSent, false);

  // A client that forwards the token is detectable.
  await fetch(location, { headers: { Authorization: `Bearer ${DEFAULT_TOKEN}` } });
  state = await control('GET', '/__fake/state');
  assert.equal(state.codeload.authorizationSent, true);

  // fetch's own redirect following (cross-path, same origin) also works end to end.
  const followed = await fetch(`${fake.url}/repos/${REPO}/zipball/feature%2Fdemo`, { headers: { Authorization: `Bearer ${DEFAULT_TOKEN}` } });
  assert.equal(followed.status, 200);
  const fz = unzip(Buffer.from(await followed.arrayBuffer()));
  assert.ok([...fz.keys()].some((n) => n.endsWith('/src/demo.ps1')));
  assert.equal((await api('GET', `/repos/${REPO}/zipball/nope`)).status, 404);
  assert.equal((await fetch(`${fake.url}/_codeload/bogus.zip`)).status, 404);
});

test('fault injection: 429 with Retry-After, then success; 502 once', async () => {
  await control('POST', '/__fake/fail', { method: 'GET', pathContains: '/git/ref/heads/main', status: 429, times: 2, retryAfter: 1 });
  for (let i = 0; i < 2; i++) {
    const r = await api('GET', `/repos/${REPO}/git/ref/heads/main`);
    assert.equal(r.status, 429);
    assert.equal(r.headers.get('retry-after'), '1');
    assert.equal(r.headers.get('x-ratelimit-remaining'), '0');
  }
  assert.equal((await api('GET', `/repos/${REPO}/git/ref/heads/main`)).status, 200);
  assert.equal((await api('GET', `/repos/${REPO}/branches`)).status, 200, 'non-matching path unaffected');

  await control('POST', '/__fake/fail', { method: 'POST', pathContains: '/git/blobs', status: 502 });
  assert.equal((await api('POST', `/repos/${REPO}/git/blobs`, { content: 'x' })).status, 502);
  assert.equal((await api('POST', `/repos/${REPO}/git/blobs`, { content: 'x' })).status, 201);

  const state = await control('GET', '/__fake/state');
  assert.equal(state.faults.length, 0);
  assert.equal(state.calls.filter((c) => c.fault).length, 3);
  assert.ok(state.calls.every((c) => c.kind !== 'api' || c.auth === 'valid'));
});

test('advance pushes an outside commit and reset restores the seed', async () => {
  const before = await headOf('main');
  const adv = await control('POST', '/__fake/advance', { branch: 'main' });
  assert.equal(adv.parent, before);
  const now = await headOf('main');
  assert.equal(now, adv.sha);
  const c = (await api('GET', `/repos/${REPO}/git/commits/${now}`)).json;
  assert.deepEqual(c.parents.map((p) => p.sha), [before]);
  assert.ok((await treeMap(c.tree.sha)).has('TEAMMATE.md'));
  const cmp = (await api('GET', `/repos/${REPO}/compare/feature%2Fdemo...main`)).json;
  assert.equal(cmp.ahead_by, 1);
  assert.equal(cmp.behind_by, 1);
  assert.equal(cmp.status, 'diverged');
  await control('POST', '/__fake/reset');
  assert.equal(await headOf('main'), before, 'seed SHAs are deterministic');
});

test('empty repository: git/ref answers 409 like GitHub, Contents API initialises it', async () => {
  const E = '/repos/gangplank-demo/empty';
  const ref = await api('GET', `${E}/git/ref/heads/main`);
  assert.equal(ref.status, 409);
  assert.equal((await api('POST', `${E}/git/blobs`, { content: 'x' })).status, 409);
  assert.deepEqual((await api('GET', `${E}/branches?per_page=100&page=1`)).json, []);
  const put = await api('PUT', `${E}/contents/README.md`, { message: 'Initialize repository (Gangplank)', content: Buffer.from('hi\n').toString('base64'), branch: 'main' });
  assert.equal(put.status, 201);
  assert.match(put.json.commit.sha, /^[0-9a-f]{40}$/);
  const after = await api('GET', `${E}/git/ref/heads/main`);
  assert.equal(after.json.object.sha, put.json.commit.sha);
});

test('validation: malformed trees and bad JSON are rejected', async () => {
  const head = await headOf('main');
  const tree = (await api('GET', `/repos/${REPO}/git/commits/${head}`)).json.tree.sha;
  const bad = async (item) => (await api('POST', `/repos/${REPO}/git/trees`, { base_tree: tree, tree: [item] })).status;
  assert.equal(await bad({ path: 'a.txt', mode: '644', type: 'blob', sha: null }), 422);
  assert.equal(await bad({ path: '../x', mode: '100644', type: 'blob', sha: null }), 422);
  assert.equal(await bad({ path: 'x', mode: '100644', type: 'blob', sha: 'f'.repeat(40) }), 422);
  assert.equal(await bad({ path: 'README.md/x', mode: '100644', type: 'blob', sha: null }), 422);
  assert.equal((await api('POST', `/repos/${REPO}/git/commits`, { message: 'x', tree, parents: ['0'.repeat(40)] })).status, 422);
  const res = await fetch(`${fake.url}/repos/${REPO}/git/blobs`, {
    method: 'POST', headers: { Authorization: `Bearer ${DEFAULT_TOKEN}`, 'Content-Type': 'application/json' },
    body: Buffer.from('{"content":"caf\xe9","encoding":"utf-8"}', 'latin1'), // a PS 5.1 style Latin-1 body
  });
  assert.equal(res.status, 400);
  const state = await control('GET', '/__fake/state');
  assert.equal(state.calls.at(-1).invalidUtf8Body, true);
});

test('CLI prints one JSON line with url and token', async () => {
  const script = fileURLToPath(new URL('./fake-github.mjs', import.meta.url));
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
    const ok = await fetch(`${info.url}/repos/${REPO}`, { headers: { Authorization: 'Bearer cli-token' } });
    assert.equal(ok.status, 200);
    const no = await fetch(`${info.url}/repos/${REPO}`, { headers: { Authorization: `Bearer ${DEFAULT_TOKEN}` } });
    assert.equal(no.status, 401);
  } finally { child.kill(); }
});
