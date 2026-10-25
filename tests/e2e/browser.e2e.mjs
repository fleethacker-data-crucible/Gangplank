// Real-browser check of the UI against the real host and the synthetic GitHub.
// Catches what API tests cannot (CSS, bootstrap, rendering). Uses Playwright when it
// is available (KEYSTONE_PLAYWRIGHT=<path to playwright package>, or `playwright`
// resolvable from here) and an installed Chromium/Edge; otherwise it skips.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFakeGitHub } from '../../dev/fake-github.mjs';

const require = createRequire(import.meta.url);
let playwright = null;
for (const p of [process.env.KEYSTONE_PLAYWRIGHT, 'playwright', '/opt/npm-tools/node_modules/playwright'].filter(Boolean)) {
  try { playwright = require(p); break; } catch { }
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const shell = process.env.KEYSTONE_PWSH || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');

function launchOptions() {
  if (process.env.KEYSTONE_BROWSER_CHANNEL) return { channel: process.env.KEYSTONE_BROWSER_CHANNEL };   // e.g. msedge
  if (process.env.KEYSTONE_BROWSER_PATH) return { executablePath: process.env.KEYSTONE_BROWSER_PATH };
  const local = '/opt/pw-browsers';
  if (fs.existsSync(local)) {
    for (const d of fs.readdirSync(local).filter((x) => /^chromium-\d+$/.test(x))) {
      for (const sub of ['chrome-linux64/chrome', 'chrome-linux/chrome']) {
        const exe = path.join(local, d, sub);
        if (fs.existsSync(exe)) return { executablePath: exe };
      }
    }
  }
  return process.platform === 'win32' ? { channel: 'msedge' } : {};
}

test('UI in a real browser', { skip: playwright ? false : 'Playwright not available' }, async () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'keystone-browser-'));
  const fake = await startFakeGitHub({ port: 0 });
  const port = 20000 + Math.floor(Math.random() * 9000);
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'Start-KeystoneWeb.ps1'),
    '-LocalDev', '-NoBrowser', '-Port', String(port), '-DevGitHubUrl', fake.url + '/', '-WorkRoot', path.join(temp, 'work')];
  const env = { ...process.env, GITHUB_TOKEN: fake.token, LOCALAPPDATA: path.join(temp, 'appdata'), HOME: temp, KEYSTONE_ARC_PATH: '' };
  const child = spawn(shell, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let browser = null;
  after(async () => {
    if (browser) await browser.close();
    if (child.exitCode === null) {
      const exited = new Promise((r) => child.once('exit', r));
      child.kill();
      await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
    }
    await fake.close();
    fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
  });
  const launch = await new Promise((resolve, reject) => {
    let out = '';
    const timer = setTimeout(() => reject(new Error('Host did not start:\n' + out)), 60000);
    const onData = (d) => { out += d; const m = /Open: (http:\/\/127\.0\.0\.1:\d+\/#k=[A-Za-z0-9_-]+)/.exec(out); if (m) { clearTimeout(timer); resolve(m[1]); } };
    child.stdout.on('data', onData); child.stderr.on('data', onData);
  });
  browser = await playwright.chromium.launch(launchOptions());
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });

  await page.goto(launch);
  await page.waitForFunction(() => document.getElementById('online').textContent.includes('connected'));
  assert.equal(await page.isVisible('#ended'), false, 'The "Session ended" overlay must be hidden on a working session');
  assert.equal(await page.isVisible('#testBanner'), true, 'LocalDev must show the test-mode banner');
  assert.equal(new URL(page.url()).hash, '', 'The launch nonce must be removed from the address bar');
  assert.match(await page.inputValue('#repoUrl'), /keystone-demo\/sample$/, 'LocalDev should prefill the synthetic repo');

  await page.click('#connectBtn');
  await page.waitForFunction(() => document.getElementById('projectTitle').textContent === 'keystone-demo/sample', null, { timeout: 30000 });
  await page.waitForFunction(() => !document.getElementById('startBtn').disabled, null, { timeout: 15000 });

  // A second tab opened with the already-used link must say so (and not break the first).
  const second = await context.newPage();
  await second.goto(launch);
  await second.waitForFunction(() => !document.getElementById('ended').hidden, null, { timeout: 10000 });
  await page.reload();
  await page.waitForFunction(() => document.getElementById('online').textContent.includes('connected'));
  assert.equal(await page.isVisible('#ended'), false, 'A reload of the working tab must stay signed in');

  // Lifecycle: the heartbeat worker runs under the CSP, and End session stops the host.
  await second.close();
  await page.waitForResponse((r) => r.url().endsWith('/api/heartbeat') && r.status() === 200, { timeout: 15000 });
  page.once('dialog', (d) => d.accept());
  await page.click('#endSession');
  await page.waitForFunction(() => !document.getElementById('ended').hidden, null, { timeout: 10000 });
  const exited = child.exitCode !== null ? true : await Promise.race([new Promise((r) => child.once('exit', () => r(true))), new Promise((r) => setTimeout(() => r(false), 15000))]);
  assert.equal(exited, true, 'End session must stop the host process');

  assert.deepEqual(errors, [], 'No console errors expected: ' + errors.join(' | '));
});
