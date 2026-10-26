// Captures the README screenshot of the Gangplank workspace (docs/screenshots/).
// Mock data only: the real host runs in LocalDev against the synthetic GitHub
// (dev/fake-github.mjs, fictional repo gangplank-demo/sample), with a throwaway
// LOCALAPPDATA / USERPROFILE / WorkRoot, so no real token, session or workspace is read.
//
//   GANGPLANK_PLAYWRIGHT=<path to playwright package> node dev/capture-screenshots.mjs [port]
//
// Gangplank has one theme (Night watch, dark), so only that shot is taken.
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
const shell = process.env.GANGPLANK_PWSH || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');
const port = Number(process.argv[2]) || 20000 + Math.floor(Math.random() * 9000);
const shots = [{ scheme: 'dark', file: 'workspace-night-watch.png' }];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'gangplank-shots-'));
const fake = await startFakeGitHub({ port: 0 });
const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'Start-Gangplank.ps1'),
  '-LocalDev', '-NoBrowser', '-Stay', '-Port', String(port), '-DevGitHubUrl', fake.url + '/', '-WorkRoot', path.join(temp, 'work')];
const env = { ...process.env, GITHUB_TOKEN: fake.token, LOCALAPPDATA: path.join(temp, 'appdata'), USERPROFILE: temp, HOME: temp, GANGPLANK_LAZARETTE_PATH: '' };
const child = spawn(shell, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
let log = '';
child.stdout.on('data', (d) => { log += d; });
child.stderr.on('data', (d) => { log += d; });

// The launch link works once, so each fresh browser context needs a new one (L in the host window).
async function nextLink(seen) {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const links = [...log.matchAll(/Open: (http:\/\/127\.0\.0\.1:\d+\/#k=[A-Za-z0-9_-]+)/g)].map((m) => m[1]).filter((l) => !seen.has(l));
    if (links.length) { seen.add(links[0]); return links[0]; }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error('Host did not print a launch link:\n' + log);
}

const browser = await playwright.chromium.launch();
try {
  fs.mkdirSync(out, { recursive: true });
  const seen = new Set();
  for (const shot of shots) {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, colorScheme: shot.scheme });
    const page = await context.newPage();
    await page.goto(await nextLink(seen));
    await page.waitForFunction(() => document.getElementById('online').textContent.includes('connected'));
    await page.click('#connectBtn');
    await page.waitForFunction(() => document.getElementById('projectTitle').textContent === 'gangplank-demo/sample', null, { timeout: 30000 });
    await page.waitForTimeout(1500);
    await page.evaluate(() => { document.activeElement?.blur(); window.scrollTo(0, 0); });   // clicking Connect scrolls the page
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(out, shot.file) });
    console.log('wrote docs/screenshots/' + shot.file);
    await context.close();
  }
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
