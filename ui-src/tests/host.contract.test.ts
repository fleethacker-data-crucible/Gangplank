// Contract test: the typed client against the REAL host (Start-Gangplank.ps1 -LocalDev) and the
// synthetic GitHub (dev/fake-github.mjs). Fictional data, temp folders only.
// Run with: node --test ui-src/tests/host.contract.test.ts   (GANGPLANK_PWSH overrides the shell)
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFakeGitHub } from '../../dev/fake-github.mjs';
import { createApi, ApiError } from '../src/api.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const shell = process.env.GANGPLANK_PWSH || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'gangplank-ts-'));
const fake = await startFakeGitHub({ port: 0 });
let child: ChildProcess | null = null;

after(async () => {
  if (child && child.exitCode === null) {
    const exited = new Promise((r) => child!.once('exit', r));
    child.kill();
    await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
  }
  await fake.close();
  fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
});

function startHost(): Promise<{ base: string; nonce: string }> {
  const port = 20000 + Math.floor(Math.random() * 9000);
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'Start-Gangplank.ps1'),
    '-LocalDev', '-NoBrowser', '-Port', String(port), '-DevGitHubUrl', fake.url + '/', '-WorkRoot', path.join(temp, 'work')];
  if (shell.toLowerCase().includes('powershell')) args.unshift('-STA');
  const env = { ...process.env, GITHUB_TOKEN: fake.token, LOCALAPPDATA: path.join(temp, 'appdata'), HOME: temp,
    GANGPLANK_LAZARETTE_PATH: '', GITLAB_TOKEN: '', LLM_TOKEN: '', OPENAI_API_KEY: '', LLM_URL: '', GANGPLANK_WORK_ROOT: '' };
  child = spawn(shell, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Host did not start:\n' + out)), 60000);
    const onData = (d: Buffer) => {
      out += d.toString();
      const m = /Open: (http:\/\/127\.0\.0\.1:(\d+))\/#k=([A-Za-z0-9_-]+)/.exec(out);
      if (m) { clearTimeout(timer); resolve({ base: m[1], nonce: m[3] }); }
    };
    child!.stdout!.on('data', onData);
    child!.stderr!.on('data', onData);
    child!.on('exit', (code) => { clearTimeout(timer); reject(new Error(`Host exited ${code}:\n${out}`)); });
  });
}

test('the typed client drives the real host: session, status, connect, start, and a refused name', async () => {
  const { base, nonce } = await startHost();

  // The launch link's one-time nonce becomes a cookie plus a per-session client secret.
  const opened = await fetch(base + '/api/session', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Gangplank-Client': '' }, body: JSON.stringify({ nonce }) });
  const session = await opened.json() as { client: string };
  assert.equal(opened.status, 200);
  const cookie = (opened.headers.get('set-cookie') || '').split(';')[0];
  assert.ok(cookie.startsWith('gangplank_session='), 'a session cookie is issued');

  // Node has no cookie jar: add the cookie, as a browser would for same-origin calls.
  const withCookie = ((path: string, init: RequestInit) => fetch(base + path, { ...init, headers: { ...(init.headers as Record<string, string>), Cookie: cookie } })) as unknown as typeof fetch;
  const api = createApi({ clientSecret: () => session.client, fetchImpl: withCookie, pollMs: 150 });

  const before = await api.request<{ connected: boolean }>('/api/status');
  assert.equal(before.connected, false);

  const connected = await api.runJob<{ project: string; branches: string[] }>('/api/connect', { url: fake.url + '/gangplank-demo/sample' });
  assert.equal(connected.project, 'gangplank-demo/sample');
  assert.ok(connected.branches.includes('feature/demo'));

  const progress: string[] = [];
  const started = await api.runJob<{ branch: string; folder: string }>('/api/start', { name: 'ts client' }, { onProgress: (p) => progress.push(p) });
  assert.equal(started.branch, 'ts-client');
  assert.ok(fs.existsSync(path.join(started.folder, 'scripts', 'build.sh')), 'the workspace was downloaded');
  assert.ok(progress.length > 0, 'progress text arrived while the job ran');

  await assert.rejects(api.runJob('/api/start', { name: 'bad..name' }), (e: ApiError) => e instanceof ApiError && e.code === 'BAD_REQUEST' && e.status === 400);
  await assert.rejects(createApi({ clientSecret: () => 'wrong', fetchImpl: withCookie }).request('/api/status'), (e: ApiError) => e.status === 401);
});
