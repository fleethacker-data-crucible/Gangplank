// Captures the README screenshots of the Gangplank workspace (docs/screenshots/), in both Fleet
// themes: Night watch (dark) and Chart room (light), at 1440 x 900 with the sidebar expanded.
// Mock data only: the real host runs in LocalDev against the synthetic GitHub
// (dev/fake-github.mjs, fictional repo gangplank-demo/sample), with a throwaway
// LOCALAPPDATA / USERPROFILE / WorkRoot, so no real token, session or workspace is read.
//
//   GANGPLANK_PLAYWRIGHT=<path to playwright package> node dev/capture-screenshots.mjs [port]
//
// GANGPLANK_SHOTS_CHECK=<folder> also writes layout checks there (1280 x 720, and the sidebar
// collapsed) and prints any horizontal overflow; those are for review only and are not committed.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFakeGitHub } from './fake-github.mjs';

const require = createRequire(import.meta.url);
const playwright = require(process.env.GANGPLANK_PLAYWRIGHT || 'playwright');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'docs', 'screenshots');
const check = process.env.GANGPLANK_SHOTS_CHECK || '';
const shell = process.env.GANGPLANK_PWSH || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');
const port = Number(process.argv[2]) || 20000 + Math.floor(Math.random() * 9000);
const shots = [
  { scheme: 'dark', file: path.join(out, 'workspace-night-watch.png') },
  { scheme: 'light', file: path.join(out, 'workspace-chart-room.png') },
];
if (check) {
  shots.push(
    { scheme: 'dark', file: path.join(check, 'check-1280x720.png'), width: 1280, height: 720 },
    { scheme: 'light', file: path.join(check, 'check-collapsed.png'), collapsed: true },
    { scheme: 'light', file: path.join(check, 'check-1280x720-collapsed.png'), width: 1280, height: 720, collapsed: true },
  );
}

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'gangplank-shots-'));
const fake = await startFakeGitHub({ port: 0 });
const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'Start-Gangplank.ps1'),
  '-LocalDev', '-NoBrowser', '-Stay', '-Port', String(port), '-DevGitHubUrl', fake.url + '/', '-WorkRoot', path.join(temp, 'work')];
const env = { ...process.env, GITHUB_TOKEN: fake.token, LOCALAPPDATA: path.join(temp, 'appdata'), USERPROFILE: temp, HOME: temp, GANGPLANK_LAZARETTE_PATH: '' };
const child = spawn(shell, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
let log = '';
child.stdout.on('data', (d) => { log += d; });
child.stderr.on('data', (d) => { log += d; });

// The launch link works once, so one browser tab connects and every shot reloads that tab
// (a reload keeps the session) with its theme, size and sidebar width.
async function launchLink() {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const m = /Open: (http:\/\/127\.0\.0\.1:\d+\/#k=[A-Za-z0-9_-]+)/.exec(log);
    if (m) return m[1];
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error('Host did not print a launch link:\n' + log);
}

const browser = await playwright.chromium.launch({ headless: true });
try {
  fs.mkdirSync(out, { recursive: true });
  if (check) fs.mkdirSync(check, { recursive: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await page.goto(await launchLink());
  await page.waitForFunction(() => document.getElementById('online').textContent.includes('connected'));
  await page.click('#connectBtn');
  await page.waitForFunction(() => document.getElementById('projectTitle').textContent === 'gangplank-demo/sample', null, { timeout: 30000 });
  for (const shot of shots) {
    await page.setViewportSize({ width: shot.width || 1440, height: shot.height || 900 });
    await page.emulateMedia({ colorScheme: shot.scheme });
    // The sidebar width is a remembered choice (gangplank-sidebar), applied before the first paint.
    await page.evaluate((collapsed) => { try { localStorage.setItem('gangplank-sidebar', collapsed ? 'collapsed' : 'expanded'); } catch { } }, !!shot.collapsed);
    await page.reload();
    await page.waitForFunction(() => document.getElementById('online').textContent.includes('connected'));
    await page.waitForFunction(() => document.getElementById('projectTitle').textContent === 'gangplank-demo/sample', null, { timeout: 30000 });
    await page.waitForTimeout(1500);
    // Clicking Connect scrolls the content; start every shot at the top.
    await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0); document.getElementById('main').scrollTop = 0; });
    await page.waitForTimeout(300);
    if (check) {
      const o = await page.evaluate(() => {
        const m = document.getElementById('main');
        return { page: document.documentElement.scrollWidth - innerWidth, main: m.scrollWidth - m.clientWidth };
      });
      console.log(path.basename(shot.file) + ': horizontal overflow page ' + o.page + ' px, main ' + o.main + ' px');
    }
    await page.screenshot({ path: shot.file });
    console.log('wrote ' + shot.file);
  }
  await context.close();
} finally {
  await browser.close();
  if (child.exitCode === null) {
    const exited = new Promise((r) => child.once('exit', r));
    child.kill();
    await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
  }
  await fake.close();
  fs.rmSync(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
}
