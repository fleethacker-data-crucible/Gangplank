// End to end: the real Gangplank host (Start-Gangplank.ps1 -LocalDev) against the
// synthetic GitHub server (dev/fake-github.mjs). Fictional data, temp folders only.
// Run: node --test tests/e2e/host.e2e.mjs   (GANGPLANK_PWSH overrides the shell)
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFakeGitHub } from '../../dev/fake-github.mjs';
import { startFakeAi } from '../../dev/fake-ai.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const shell = process.env.GANGPLANK_PWSH || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'gangplank-e2e-'));
const workRoot = path.join(temp, 'work');
const fake = await startFakeGitHub({ port: 0 });
const fakeAi = await startFakeAi({ port: 0, mode: 'openai' });
let host = null;

function startHost() {
  const port = 20000 + Math.floor(Math.random() * 9000);
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'Start-Gangplank.ps1'),
    '-LocalDev', '-NoBrowser', '-Port', String(port), '-DevGitHubUrl', fake.url + '/', '-WorkRoot', workRoot];
  if (shell.toLowerCase().includes('powershell')) args.unshift('-STA');
  const env = { ...process.env, GITHUB_TOKEN: fake.token, LOCALAPPDATA: path.join(temp, 'appdata'), HOME: temp,
    GANGPLANK_LAZARETTE_PATH: '', GITLAB_TOKEN: '', GANGPLANK_AI_TOKEN: fakeAi.token, GENAI_TOKEN: '', LLM_TOKEN: '', OPENAI_API_KEY: '', LLM_URL: '', GANGPLANK_AI_URL: '', GANGPLANK_WORK_ROOT: '' };
  const child = spawn(shell, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Host did not start:\n' + out)), 60000);
    const onData = (d) => {
      out += d.toString();
      const m = /Open: (http:\/\/127\.0\.0\.1:(\d+)\/#k=([A-Za-z0-9_-]+))/.exec(out);
      if (m) { clearTimeout(timer); resolve({ child, launch: m[1], base: `http://127.0.0.1:${m[2]}`, nonce: m[3], log: () => out }); }
    };
    child.stdout.on('data', onData);
    child.stderr.on('data', onData);
    child.on('exit', (code) => { clearTimeout(timer); reject(new Error(`Host exited ${code}:\n${out}`)); });
  });
}

async function stopHost(h) {
  if (!h || h.child.exitCode !== null) return;
  h.child.removeAllListeners('exit');
  const done = new Promise((r) => h.child.once('exit', r));
  h.child.kill();
  await Promise.race([done, new Promise((r) => setTimeout(r, 5000))]);
}

after(async () => {
  await stopHost(host);
  await fake.close();
  await fakeAi.close();
  fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
});

let cookie = '';
let client = '';
async function call(h, method, p, body, extra = {}) {
  const headers = { 'X-Gangplank-Client': client, ...(cookie ? { Cookie: cookie } : {}), ...extra };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(h.base + p, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let json = null; try { json = JSON.parse(text); } catch { }
  return { status: r.status, json, headers: r.headers, text };
}
async function job(h, p, body) {
  const start = await call(h, 'POST', p, body ?? {});
  if (start.status !== 202) return start;
  for (let i = 0; i < 300; i++) {
    await new Promise((r) => setTimeout(r, 200));
    const j = await call(h, 'GET', `/api/jobs/${start.json.job}`);
    if (j.json.state !== 'running') return { status: j.json.state === 'succeeded' ? 200 : 500, json: j.json.result ?? j.json, error: j.json.error };
  }
  throw new Error('job timed out');
}
async function fakeState() { return (await fetch(fake.url + '/__fake/state')).json(); }

test('session bootstrap and request gate', async () => {
  host = await startHost();
  const h = host;
  let r = await call(h, 'GET', '/api/status');
  assert.equal(r.status, 401, 'API without a session must be refused');
  r = await fetch(h.base + '/');
  await r.text(); // always drain bodies: undici asserts if the server closes while a body is unread
  assert.equal(r.status, 200);
  const csp = r.headers.get('content-security-policy');
  assert.match(csp, /script-src 'self'/); assert.doesNotMatch(csp, /unsafe-inline/);
  assert.equal(r.headers.get('x-frame-options'), 'DENY');
  const getStatus = async (u) => { const x = await fetch(u); await x.text(); return x.status; };
  assert.equal(await getStatus(h.base + '/app.js'), 200);
  assert.equal(await getStatus(h.base + '/Gangplank.psm1'), 404, 'Only manifest files are served');
  r = await call(h, 'POST', '/api/session', { nonce: 'wrong-wrong-wrong-wrong-wrong' });
  assert.equal(r.status, 401, 'A wrong launch nonce must be refused');
  r = await call(h, 'POST', '/api/session', { nonce: h.nonce });
  assert.equal(r.status, 200);
  const set = r.headers.get('set-cookie');
  assert.match(set, /gangplank_session=[^;]+; HttpOnly; SameSite=Strict/);
  cookie = set.split(';')[0];
  client = r.json.client;
  assert.ok(client && client.length >= 40, 'Session must return a per-session client secret');
  assert.ok(!set.includes(client), 'The client secret must not be in the cookie');
  r = await call(h, 'POST', '/api/session', { nonce: h.nonce });
  assert.equal(r.status, 401, 'The launch nonce must work only once');
  // Browsers send localhost cookies to every port: a cookie replayed by another local
  // server (without the tab's secret) must not work.
  r = await call(h, 'GET', '/api/status', undefined, { 'X-Gangplank-Client': 'gangplank-ui/1' });
  assert.equal(r.status, 401, 'Cookie with a guessed client header must be refused');
  r = await call(h, 'GET', '/api/status', undefined, { 'X-Gangplank-Client': '' });
  assert.equal(r.status, 401, 'Missing client secret must be refused');
  const savedCookie = cookie; cookie = '';
  r = await call(h, 'GET', '/api/status');
  assert.equal(r.status, 401, 'Client secret without the cookie must be refused');
  cookie = savedCookie;
  r = await call(h, 'GET', '/api/status', undefined, { Origin: 'http://evil.example' });
  assert.equal(r.status, 400, 'Foreign Origin must be refused');
  // fetch() cannot forge Host; a raw request can (as a DNS-rebinding page would).
  const port = Number(new URL(h.base).port);
  const raw = await new Promise((resolve, reject) => {
    const sock = net.connect(port, '127.0.0.1', () => sock.write(`GET /api/status HTTP/1.1\r\nHost: evil.example:${port}\r\nX-Gangplank-Client: ${client}\r\nCookie: ${cookie}\r\n\r\n`));
    let data = ''; sock.on('data', (d) => (data += d)); sock.on('end', () => resolve(data)); sock.on('error', reject);
  });
  assert.match(raw, /^HTTP\/1\.1 400 /, 'Foreign Host (DNS rebinding) must be refused');
  const smuggle = await new Promise((resolve, reject) => {
    const sock = net.connect(port, '127.0.0.1', () => sock.write(`POST /api/status HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n`));
    let data = ''; sock.on('data', (d) => (data += d)); sock.on('end', () => resolve(data)); sock.on('error', reject);
  });
  assert.match(smuggle, /^HTTP\/1\.1 400 /, 'Transfer-Encoding must be refused');
  r = await call(h, 'GET', '/api/status');
  assert.equal(r.status, 200);
  assert.equal(r.json.localDev, true);
  assert.equal(r.json.connected, false);
  r = await call(h, 'POST', '/api/connect', { url: 'https://untrusted.invalid/a/b' });
  assert.equal(r.status, 400, 'Untrusted repository host must be rejected');
  r = await call(h, 'POST', '/api/credentials', { provider: 'GitHub', token: 'abc' });
  assert.ok(r.status >= 400, 'Short token must be rejected');
});

test('connect, start, edit, Smart Save, review', async () => {
  const h = host;
  let r = await job(h, '/api/connect', { url: fake.url + '/gangplank-demo/sample' });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.json.project, 'gangplank-demo/sample');
  assert.ok(r.json.branches.includes('feature/demo'));
  r = await job(h, '/api/start', { name: 'dummy dev' });
  assert.equal(r.status, 200, JSON.stringify(r));
  const branch = r.json.branch, folder = r.json.folder;
  assert.equal(branch, 'dummy-dev', 'The work branch must use the name the user typed');
  assert.equal(path.basename(folder), 'dummy-dev', 'The folder must be named after the branch');
  assert.equal(path.basename(path.dirname(folder)), 'sample', 'The folder must sit under the repository name');
  // Windows can expose the temp folder through a short name or a junction.
  // Resolve both existing directories before checking containment.
  const realWorkRoot = fs.realpathSync.native(workRoot);
  const realFolder = fs.realpathSync.native(folder);
  const workspaceRelative = path.relative(realWorkRoot, realFolder);
  assert.ok(workspaceRelative && !path.isAbsolute(workspaceRelative) &&
    workspaceRelative !== '..' && !workspaceRelative.startsWith('..' + path.sep),
    `Workspaces must go to the workspace folder: ${realFolder} (root ${realWorkRoot})`);
  const dup = await job(h, '/api/start', { name: 'dummy-dev' });
  assert.equal(dup.status, 500, 'Starting a branch that already exists must fail');
  assert.match(String(dup.error), /already exists/, 'Duplicate branch error must say so: ' + dup.error);
  const badName = await call(h, 'POST', '/api/start', { name: 'bad..name' });
  assert.equal(badName.status, 400, 'An invalid branch name must be refused before any work starts');
  // the workspace from the first start is still current
  r = { json: { branch, folder } };
  assert.ok(fs.existsSync(path.join(folder, 'scripts', 'build.sh')), 'Workspace not downloaded');
  const st = await fakeState();
  assert.equal(st.codeload.authorizationSent, false, 'Token must not be sent to the archive redirect host');

  fs.appendFileSync(path.join(folder, 'scripts', 'build.sh'), 'echo extra\n');
  fs.writeFileSync(path.join(folder, 'notes.md'), '# Notes\n\nFictional.\n');
  fs.writeFileSync(path.join(folder, '.env'), 'SECRET=1\n');
  r = await call(h, 'GET', '/api/preview');
  assert.equal(r.status, 200, r.text);
  const changes = Object.fromEntries(r.json.changes.map((c) => [c.Path, c]));
  assert.equal(changes['scripts/build.sh'].Kind, 'Modified');
  assert.equal(changes['notes.md'].Kind, 'New');
  assert.equal(changes['.env'].Blocked, true, '.env must be blocked');

  r = await job(h, '/api/save', { paths: ['.env'] });
  assert.equal(r.status, 500, '.env must not be publishable');
  r = await job(h, '/api/save', { paths: ['scripts/build.sh', 'notes.md'], message: 'Update build script and add notes' });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.json.saved.FileCount, 2);
  const auth = { headers: { Authorization: 'Bearer ' + fake.token } };
  const commit = await (await fetch(`${fake.url}/repos/gangplank-demo/sample/git/commits/${r.json.saved.Commit}`, auth)).json();
  const tree = await (await fetch(`${fake.url}/repos/gangplank-demo/sample/git/trees/${commit.tree.sha}?recursive=1`, auth)).json();
  const build = tree.tree.find((e) => e.path === 'scripts/build.sh');
  assert.equal(build.mode, '100755', 'Executable bit must survive Smart Save');
  assert.equal(tree.tree.find((e) => e.path === 'notes.md').mode, '100644');
  assert.ok(!tree.tree.some((e) => e.path === '.env'), '.env must never be published');
  r = await call(h, 'GET', '/api/status');
  assert.equal(r.json.canReview, true);
  r = await job(h, '/api/review', {});
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.match(r.json.url, /^http/);

  r = await call(h, 'GET', '/api/audit?last=20');
  const actions = r.json.entries.map((e) => e.action);
  for (const a of ['branch.created', 'commit.created', 'review.created']) assert.ok(actions.includes(a), 'Audit missing ' + a);
  assert.doesNotMatch(JSON.stringify(r.json), new RegExp(fake.token), 'Audit leaked the token');

  // Adopt: a copy of the workspace, matched to the work branch, becomes the workspace; then back to the original.
  const copy = path.join(workRoot, 'adopted-copy');
  fs.cpSync(folder, copy, { recursive: true });
  r = await job(h, '/api/adopt', { folder: copy, branch });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.json.source, 'plain folder');
  assert.ok(r.json.same > 0, 'Files that match the branch are counted');
  r = await call(h, 'GET', '/api/status');
  assert.equal(fs.realpathSync.native(r.json.workspace), fs.realpathSync.native(copy), 'The adopted folder is the workspace');
  r = await job(h, '/api/adopt', { folder: path.join(workRoot, 'nowhere'), branch });
  assert.equal(r.status, 500, 'A folder that does not exist is refused');
  r = await job(h, '/api/adopt', { folder, branch });
  assert.equal(r.status, 200, JSON.stringify(r));

  // A teammate pushes to the work branch: saving must stop.
  await (await fetch(fake.url + '/__fake/advance', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ branch, path: 'teammate.txt', content: 'hi' }) })).text();
  fs.appendFileSync(path.join(folder, 'notes.md'), 'More.\n');
  r = await call(h, 'GET', '/api/preview');
  assert.equal(r.json.remoteChanged, true, 'Remote change must be detected');
  r = await job(h, '/api/save', { paths: ['notes.md'] });
  assert.equal(r.status, 500, 'Save over a moved branch must be refused');
});

test('session survives a restart', async () => {
  const before = (await call(host, 'GET', '/api/status')).json;
  await stopHost(host);
  host = await startHost();
  cookie = '';
  const r1 = await call(host, 'POST', '/api/session', { nonce: host.nonce });
  cookie = r1.headers.get('set-cookie').split(';')[0];
  client = r1.json.client;
  const after = (await call(host, 'GET', '/api/status')).json;
  assert.equal(after.connected, true, 'Restored session should reconnect with the environment token');
  assert.equal(after.project, before.project);
  assert.equal(after.branch, before.branch);
  assert.equal(after.workspace, before.workspace);
  assert.equal(after.hasBaseline, true, 'Download baseline must survive a restart');
  const p = await call(host, 'GET', '/api/preview');
  assert.equal(p.status, 200, p.text);
  assert.ok(p.json.changes.some((c) => c.Path === 'notes.md'), 'Pending edit should still be visible after restart: ' + JSON.stringify(p.json));
});

test('a session saved by Keystone (before the rename) is picked up', async () => {
  // Simulate an upgrade: the saved state lives in Keystone's folder, Gangplank's does not exist yet.
  const before = (await call(host, 'GET', '/api/status')).json;
  await stopHost(host);
  const current = path.join(workRoot, '.gangplank'), legacy = path.join(workRoot, '.keystone');
  fs.rmSync(legacy, { recursive: true, force: true });
  fs.renameSync(current, legacy);
  host = await startHost();
  assert.match(host.log(), /Copied your Keystone data/, 'The host should say it carried the Keystone data forward');
  assert.ok(fs.existsSync(path.join(legacy, 'session.json')), 'The Keystone folder must be left in place');
  assert.ok(fs.existsSync(path.join(current, 'session.json')), 'The session must be copied to the Gangplank folder');
  cookie = '';
  const r1 = await call(host, 'POST', '/api/session', { nonce: host.nonce });
  cookie = r1.headers.get('set-cookie').split(';')[0];
  client = r1.json.client;
  const after = (await call(host, 'GET', '/api/status')).json;
  assert.equal(after.project, before.project, 'Project restored from the Keystone session');
  assert.equal(after.branch, before.branch);
  assert.equal(after.hasBaseline, true);
});

test('Sentinel review: a possible personal identifier needs a reason that is audited', async () => {
  const h = host;
  let r = await job(h, '/api/connect', { url: fake.url + '/gangplank-demo/sample' });
  assert.equal(r.status, 200, JSON.stringify(r));
  r = await job(h, '/api/start', { name: 'sentinel review' });
  assert.equal(r.status, 200, JSON.stringify(r));
  const folder = r.json.folder;
  fs.writeFileSync(path.join(folder, 'people.csv'), 'id,note\n1,123-45-6789\n');   // synthetic, fictional
  fs.writeFileSync(path.join(folder, 'logo.png'), Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(32)]));
  r = await job(h, '/api/save', { paths: ['people.csv'] });
  assert.equal(r.status, 500, 'A review finding blocks publishing without a reason');
  assert.match(String(r.error), /SSN_CANDIDATE/);
  r = await job(h, '/api/save', { paths: ['people.csv'], acknowledgements: { 'people.csv': 'ok' } });
  assert.equal(r.status, 500, 'A reason shorter than 5 characters is refused');
  const since = new Date().toISOString();   // the audit log keeps earlier runs, so count only this save
  r = await job(h, '/api/save', {
    paths: ['people.csv', 'logo.png'], message: 'Add sample data and logo',
    acknowledgements: { 'people.csv': 'Synthetic test data, not real people', 'logo.png': 'Team logo, checked by eye' },
  });
  assert.equal(r.status, 200, JSON.stringify(r));
  const entries = (await call(h, 'GET', '/api/audit?last=50')).json.entries;
  const acks = entries.filter((e) => e.action === 'sentinel.acknowledged' && e.time >= since);
  assert.equal(acks.length, 2, 'Each acknowledged file is audited');
  assert.ok(acks.some((e) => e.path === 'people.csv' && /SSN_CANDIDATE/.test(e.codes) && /Synthetic test data/.test(e.reason)), 'The audit entry has the codes and the reason');
});

test('jobs never overlap and bad jobs are clean', async () => {
  const a = await call(host, 'POST', '/api/download', { branch: 'main' });
  const b = await call(host, 'POST', '/api/download', { branch: 'main' });
  assert.equal(a.status, 202);
  assert.equal(b.status, 409, 'A second workspace job must be refused while one runs');
  assert.equal(b.json.error, 'BUSY');
  const r = await call(host, 'GET', '/api/jobs/job-000000000000');
  assert.equal(r.status, 404);
  // Cancel: the job must reach a final state, and the group must free up afterwards.
  await call(host, 'POST', `/api/jobs/${a.json.job}/cancel`, {});
  let final = '';
  for (let i = 0; i < 150; i++) {
    const j = await call(host, 'GET', `/api/jobs/${a.json.job}`);
    if (!['running', 'cancelling'].includes(j.json.state)) { final = j.json.state; break; }
    await new Promise((res) => setTimeout(res, 200));
  }
  assert.ok(['cancelled', 'succeeded', 'failed'].includes(final), 'A cancelled job must finish, got ' + final);
  const c = await call(host, 'POST', '/api/download', { branch: 'main' });
  assert.equal(c.status, 202, 'A new job must be allowed once the cancelled one has ended');
  for (let i = 0; i < 150; i++) {
    const j = await call(host, 'GET', `/api/jobs/${c.json.job}`);
    if (j.json.state !== 'running') break;
    await new Promise((res) => setTimeout(res, 200));
  }
});

test('AI with consent: preview first, send only what was previewed', async () => {
  const h = host;
  let r = await job(h, '/api/connect', { url: fake.url + '/gangplank-demo/sample' });
  assert.equal(r.status, 200, JSON.stringify(r));
  r = await job(h, '/api/start', { name: 'ai consent' });
  assert.equal(r.status, 200, JSON.stringify(r));
  fs.writeFileSync(path.join(r.json.folder, 'idea.md'), '# Fictional idea\n\nA made-up paragraph.\n');
  r = await call(h, 'POST', '/api/settings/intelligence', { endpoint: fakeAi.url + '/v1', model: 'gpt-4.1', profile: 'openai' });
  assert.equal(r.status, 200, r.text);
  const chats = async () => (await (await fetch(fakeAi.url + '/__fake/state')).json()).calls.filter((c) => c.method === 'POST' && c.path === '/v1/chat/completions').length;
  const before = await chats();
  r = await call(h, 'GET', '/api/ai/explain-preview?path=idea.md');
  assert.equal(r.status, 200, r.text);
  assert.match(r.json.user, /made-up paragraph/, 'The preview shows the file text');
  assert.equal(await chats(), before, 'The preview sends nothing');
  const consent = r.json.consent;
  r = await job(h, '/api/ai/explain', { path: 'idea.md', consent: 'WRONG' });
  assert.equal(r.status, 500, 'A wrong consent token is refused');
  assert.equal(await chats(), before, 'A refusal sends nothing');
  r = await job(h, '/api/ai/explain', { path: 'idea.md', consent });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.match(r.json.answer, /^Echo from gpt-4\.1: Explain in plain/, 'The answer comes back as text');
  assert.equal(await chats(), before + 1, 'Exactly one request was sent');
  r = await call(h, 'GET', '/api/ai/explain-preview?path=../outside.txt');
  assert.equal(r.status, 400, 'A path outside the workspace is refused');
  await call(h, 'POST', '/api/settings/intelligence', { endpoint: '' });
});

test('a disconnect during a job is not undone by the job', async () => {
  const s = await call(host, 'POST', '/api/download', { branch: 'main' });
  assert.equal(s.status, 202);
  const d = await call(host, 'POST', '/api/disconnect', {});
  assert.equal(d.status, 200);
  for (let i = 0; i < 150; i++) {
    const j = await call(host, 'GET', `/api/jobs/${s.json.job}`);
    if (j.json.state !== 'running') { if (j.json.state === 'succeeded') assert.equal(j.json.result.stale, true, 'Stale result should be marked'); break; }
    await new Promise((res) => setTimeout(res, 200));
  }
  const st = await call(host, 'GET', '/api/status');
  assert.equal(st.json.connected, false, 'Disconnect must stick');
});

test('publish a folder: a work branch from a plain folder, then Smart Save', async () => {
  const h = host;
  let r = await job(h, '/api/connect', { url: fake.url + '/gangplank-demo/sample' });
  assert.equal(r.status, 200, JSON.stringify(r));
  const src = path.join(workRoot, 'course-source');
  fs.mkdirSync(path.join(src, 'lessons'), { recursive: true });
  fs.writeFileSync(path.join(src, 'lessons', 'one.md'), '# Lesson one\n\nFictional course.\n');
  fs.writeFileSync(path.join(src, 'course.json'), '{"title":"Fictional course"}\n');
  fs.writeFileSync(path.join(src, 'export.mp4'), Buffer.alloc(6 * 1024 * 1024, 1));
  r = await job(h, '/api/publish-folder', { folder: path.join(workRoot, 'nowhere'), name: 'never created' });
  assert.equal(r.status, 500, 'A missing folder is refused before any branch is created');
  r = await call(h, 'POST', '/api/publish-folder', { folder: src, name: 'bad..name' });
  assert.equal(r.status, 400, 'A bad branch name is refused before any work starts');
  r = await job(h, '/api/publish-folder', { folder: src, name: 'course source' });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.json.branch, 'course-source');
  assert.equal(r.json.source, 'published folder');
  r = await call(h, 'GET', '/api/preview');
  const byPath = Object.fromEntries(r.json.changes.map((c) => [c.Path, c]));
  assert.equal(byPath['course.json'].Kind, 'New');
  assert.equal(byPath['lessons/one.md'].Kind, 'New');
  assert.equal(byPath['export.mp4'].Blocked, true, 'A 6 MB export is too large for Smart Save and says so');
  r = await job(h, '/api/save', { paths: ['course.json', 'lessons/one.md'], message: 'Add course source' });
  assert.equal(r.status, 200, JSON.stringify(r));
  const auth = { headers: { Authorization: 'Bearer ' + fake.token } };
  const commit = await (await fetch(`${fake.url}/repos/gangplank-demo/sample/git/commits/${r.json.saved.Commit}`, auth)).json();
  const tree = await (await fetch(`${fake.url}/repos/gangplank-demo/sample/git/trees/${commit.tree.sha}?recursive=1`, auth)).json();
  const names = tree.tree.map((e) => e.path);
  assert.ok(names.includes('course.json') && names.includes('lessons/one.md'), 'The folder files are on the new branch');
  assert.ok(!names.includes('export.mp4'), 'The blocked export is not published');
  assert.ok(names.includes('scripts/build.sh'), 'The project files that were already there stay (nothing is deleted)');
});

test('AI: detect models, save, test and chat through a synthetic gateway', async () => {
  const h = host;
  let r = await job(h, '/api/ai/detect', { endpoint: fakeAi.url + '/v1' });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.json.profile, 'openai');
  assert.ok(!r.json.models.includes('text-embedding-3-small') && !r.json.models.includes('whisper-1'), 'Non-chat models must be filtered out');
  assert.equal(r.json.recommended, 'gpt-4.1', 'The best chat model should be preselected');
  const s = await call(h, 'POST', '/api/settings/intelligence', { endpoint: fakeAi.url + '/v1', model: r.json.recommended, profile: r.json.profile, base: r.json.base, auth: r.json.auth });
  assert.equal(s.status, 200, s.text);
  assert.equal(s.json.intelligence.model, 'gpt-4.1');
  const t = await job(h, '/api/ai/test', {});
  assert.equal(t.status, 200, JSON.stringify(t));
  assert.equal(t.json.reply, 'OK');
  const start = await call(h, 'POST', '/api/chat', { message: 'What is a branch?' });
  assert.equal(start.status, 202, start.text);
  let text = '', after = 0, state = 'running';
  for (let i = 0; i < 100 && state === 'running'; i++) {
    await new Promise((res) => setTimeout(res, 200));
    const j = await call(h, 'GET', `/api/jobs/${start.json.job}?after=${after}`);
    text += j.json.chunks.join(''); after = j.json.next; state = j.json.state;
  }
  assert.equal(state, 'succeeded');
  assert.match(text, /^Echo from gpt-4\.1: What is a branch\?/, 'Streamed answer should arrive in order: ' + text);
  const bad = await call(h, 'POST', '/api/ai/detect', { endpoint: 'http://gateway.example.com/v1' });
  assert.equal(bad.status, 400, 'Plain http to another host must be refused before any request');
  const reset = await call(h, 'POST', '/api/settings/intelligence', { endpoint: '' });
  assert.equal(reset.json.intelligence.endpoint, 'http://127.0.0.1:8776/v1', 'Reset returns to the Fleet router default');
  assert.equal(reset.json.intelligence.source, 'default');
  assert.equal(reset.json.intelligence.model, 'auto', 'The router default model is auto');
  assert.equal(reset.json.intelligence.tokenRequired, false, 'No token is required on this PC');
});
