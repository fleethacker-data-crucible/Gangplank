// End to end: the real Keystone host (Start-KeystoneWeb.ps1 -LocalDev) against the
// synthetic GitHub server (dev/fake-github.mjs). Fictional data, temp folders only.
// Run: node --test tests/e2e/host.e2e.mjs   (KEYSTONE_PWSH overrides the shell)
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFakeGitHub } from '../../dev/fake-github.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const shell = process.env.KEYSTONE_PWSH || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'keystone-e2e-'));
const workRoot = path.join(temp, 'work');
const fake = await startFakeGitHub({ port: 0 });
let host = null;

function startHost() {
  const port = 20000 + Math.floor(Math.random() * 9000);
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'Start-KeystoneWeb.ps1'),
    '-LocalDev', '-NoBrowser', '-Port', String(port), '-DevGitHubUrl', fake.url + '/', '-WorkRoot', workRoot];
  if (shell.toLowerCase().includes('powershell')) args.unshift('-STA');
  const env = { ...process.env, GITHUB_TOKEN: fake.token, LOCALAPPDATA: path.join(temp, 'appdata'), HOME: temp,
    KEYSTONE_ARC_PATH: '', GITLAB_TOKEN: '', KEYSTONE_AI_TOKEN: '', GENAI_TOKEN: '' };
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
  fs.rmSync(temp, { recursive: true, force: true });
});

let cookie = '';
async function call(h, method, p, body, extra = {}) {
  const headers = { 'X-Keystone-Client': 'keystone-ui/1', ...(cookie ? { Cookie: cookie } : {}), ...extra };
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
  assert.equal(r.status, 200);
  const csp = r.headers.get('content-security-policy');
  assert.match(csp, /script-src 'self'/); assert.doesNotMatch(csp, /unsafe-inline/);
  assert.equal(r.headers.get('x-frame-options'), 'DENY');
  assert.equal((await fetch(h.base + '/app.js')).status, 200);
  assert.equal((await fetch(h.base + '/Keystone.psm1')).status, 404, 'Only manifest files are served');
  r = await call(h, 'POST', '/api/session', { nonce: 'wrong-wrong-wrong-wrong-wrong' });
  assert.equal(r.status, 401, 'A wrong launch nonce must be refused');
  r = await call(h, 'POST', '/api/session', { nonce: h.nonce });
  assert.equal(r.status, 200);
  const set = r.headers.get('set-cookie');
  assert.match(set, /keystone_session=[^;]+; HttpOnly; SameSite=Strict/);
  cookie = set.split(';')[0];
  r = await call(h, 'POST', '/api/session', { nonce: h.nonce });
  assert.equal(r.status, 401, 'The launch nonce must work only once');
  r = await call(h, 'GET', '/api/status', undefined, { 'X-Keystone-Client': 'other' });
  assert.equal(r.status, 401, 'Missing client header must be refused');
  r = await call(h, 'GET', '/api/status', undefined, { Origin: 'http://evil.example' });
  assert.equal(r.status, 400, 'Foreign Origin must be refused');
  // fetch() cannot forge Host; a raw request can (as a DNS-rebinding page would).
  const port = Number(new URL(h.base).port);
  const raw = await new Promise((resolve, reject) => {
    const sock = net.connect(port, '127.0.0.1', () => sock.write(`GET /api/status HTTP/1.1\r\nHost: evil.example:${port}\r\nX-Keystone-Client: keystone-ui/1\r\nCookie: ${cookie}\r\n\r\n`));
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
  let r = await job(h, '/api/connect', { url: fake.url + '/keystone-demo/sample' });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.json.project, 'keystone-demo/sample');
  assert.ok(r.json.branches.includes('feature/demo'));
  r = await job(h, '/api/start', {});
  assert.equal(r.status, 200, JSON.stringify(r));
  const branch = r.json.branch, folder = r.json.folder;
  assert.match(branch, /^keystone\/work-/);
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
  const commit = await (await fetch(`${fake.url}/repos/keystone-demo/sample/git/commits/${r.json.saved.Commit}`, auth)).json();
  const tree = await (await fetch(`${fake.url}/repos/keystone-demo/sample/git/trees/${commit.tree.sha}?recursive=1`, auth)).json();
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

  // A teammate pushes to the work branch: saving must stop.
  await fetch(fake.url + '/__fake/advance', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ branch, path: 'teammate.txt', content: 'hi' }) });
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

test('jobs never overlap and bad jobs are clean', async () => {
  const a = await call(host, 'POST', '/api/download', { branch: 'main' });
  const b = await call(host, 'POST', '/api/download', { branch: 'main' });
  assert.equal(a.status, 202);
  assert.equal(b.status, 409, 'A second workspace job must be refused while one runs');
  assert.equal(b.json.error, 'BUSY');
  const r = await call(host, 'GET', '/api/jobs/job-000000000000');
  assert.equal(r.status, 404);
  for (let i = 0; i < 100; i++) {
    const j = await call(host, 'GET', `/api/jobs/${a.json.job}`);
    if (j.json.state !== 'running') break;
    await new Promise((res) => setTimeout(res, 200));
  }
});
