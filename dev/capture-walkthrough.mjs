// Captures the walkthrough screenshots (docs/assets/walkthrough/NN-<screen>.png, Night watch) and the
// README pair (docs/screenshots/workspace-night-watch.png and workspace-chart-room.png) at 1440 x 900
// with the sidebar expanded. Mock data only.
//
//   node dev/capture-walkthrough.mjs [outRoot]     (default: the repo root; files go to <outRoot>/docs/...)
//
// It needs no PowerShell: the page is the real web/ folder, served by Playwright on
// http://127.0.0.1:8769/ (the registry port), and the host's /api is a small stand-in that
// returns the shapes Server/Routes.ps1 returns. Every repository fact (branches, commits, review
// requests, the work branch, the published commit and the review request) comes from the synthetic
// GitHub (dev/fake-github.mjs, fictional repo gangplank-demo/sample), which the stand-in drives
// through the same REST calls the host makes. The only simulated step is "edit files with your
// normal tools": the workspace preview lists two changed files, as Smart Save would after an edit.
// dev/capture-screenshots.mjs takes the README pair from the real host instead (needs PowerShell).
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startFakeGitHub } from './fake-github.mjs';

const require = createRequire(import.meta.url);
const playwright = require(process.env.GANGPLANK_PLAYWRIGHT || 'playwright');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const web = path.join(root, 'web');
const outRoot = path.resolve(process.argv[2] || root);
const out = path.join(outRoot, 'docs', 'assets', 'walkthrough');
const readmeOut = path.join(outRoot, 'docs', 'screenshots');
const origin = 'http://127.0.0.1:8769';
const repoName = 'gangplank-demo/sample';
const workName = 'demo-walkthrough';
const workRoot = 'C:\\Users\\demo\\Gangplank';

const fake = await startFakeGitHub({ port: 0 });
async function gh(method, p, body) {
  const r = await fetch(fake.url + '/repos/' + repoName + p, {
    method, headers: { Authorization: 'Bearer ' + fake.token, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const x = await r.json();
  if (!r.ok) throw new Error(method + ' ' + p + ' -> ' + r.status + ' ' + JSON.stringify(x));
  return x;
}
// Windows PowerShell shows provider dates as local DateTime strings (MM/dd/yyyy HH:mm:ss).
const psDate = (iso) => { const d = new Date(iso), z = (n) => String(n).padStart(2, '0'); return `${z(d.getUTCMonth() + 1)}/${z(d.getUTCDate())}/${d.getUTCFullYear()} ${z(d.getUTCHours())}:${z(d.getUTCMinutes())}:${z(d.getUTCSeconds())}`; };

// ---- host state, as the host keeps it in its session
const S = { connected: false, defaultBranch: '', branch: '', workspace: '', baseline: '', changes: [], lastSave: '', reviewUrl: '', audit: [] };
const jobs = new Map();
let jobSeq = 0;
const audit = (action, extra = {}) => S.audit.unshift({ action, project: repoName, provider: 'GitHub', time: new Date().toISOString(), ...extra });

async function branches() {
  const rows = await gh('GET', '/branches?per_page=100');
  const current = S.branch || S.defaultBranch;
  return rows.map((b) => ({ Name: b.name, IsDefault: b.name === S.defaultBranch, IsCurrent: b.name === current }));
}
async function reviews() {
  const rows = await gh('GET', '/pulls?state=open&per_page=30');
  return rows.map((p) => ({ Number: p.number, Title: p.title, Source: p.head.ref, Target: p.base.ref, Author: p.user.login, Url: p.html_url }));
}

const work = {
  async '/api/connect'() {
    const repo = await gh('GET', '');
    Object.assign(S, { connected: true, defaultBranch: repo.default_branch, branch: '', workspace: '', baseline: '', changes: [], lastSave: '', reviewUrl: '' });
    audit('connect');
    return { project: repo.full_name, provider: 'GitHub', branch: repo.default_branch };
  },
  async '/api/start'(body) {
    const name = String(body.name || '').trim() || 'gangplank/work-demo';
    const head = await gh('GET', '/git/ref/heads/' + S.defaultBranch);
    await gh('POST', '/git/refs', { ref: 'refs/heads/' + name, sha: head.object.sha });
    Object.assign(S, { branch: name, baseline: head.object.sha, workspace: workRoot + '\\sample\\' + name });
    // You edit files with your normal tools; Smart Save then finds these two.
    S.changes = [
      { Path: 'notes/demo-notes.txt', Kind: 'New', Selected: true, Blocked: false, Content: 'Fictional walkthrough notes.\n' },
      { Path: 'README.md', Kind: 'Modified', Selected: true, Blocked: false, Content: '# Sample\n\nFictional demo repository for Gangplank local development.\nNothing here is real.\n\nEdited during the Gangplank walkthrough.\n' },
    ];
    audit('start', { branch: name, commit: head.object.sha });
    return { folder: S.workspace, branch: name };
  },
  async '/api/save'(body) {
    const chosen = S.changes.filter((c) => body.paths.includes(c.Path));
    const base = await gh('GET', '/git/commits/' + S.baseline);
    const tree = [];
    for (const c of chosen) {
      const blob = await gh('POST', '/git/blobs', { content: c.Content, encoding: 'utf-8' });
      tree.push({ path: c.Path, mode: '100644', type: 'blob', sha: blob.sha });
    }
    const t = await gh('POST', '/git/trees', { base_tree: base.tree.sha, tree });
    const commit = await gh('POST', '/git/commits', { message: body.message, tree: t.sha, parents: [S.baseline] });
    await gh('PATCH', '/git/refs/heads/' + S.branch, { sha: commit.sha, force: false });
    S.baseline = commit.sha; S.lastSave = body.message; S.changes = [];
    audit('save', { branch: S.branch, commit: commit.sha });
    return { saved: { FileCount: chosen.length, Commit: commit.sha, Message: body.message } };
  },
  async '/api/review'() {
    const title = 'Review: ' + S.lastSave;
    const pr = await gh('POST', '/pulls', { title, head: S.branch, base: S.defaultBranch, body: 'Created with Gangplank.' });
    S.reviewUrl = pr.html_url;
    audit('review', { branch: S.branch });
    return { url: pr.html_url, title };
  },
};

async function api(method, p, query, body) {
  if (p === '/api/health') return { session: true };
  if (p === '/api/session') return { client: 'walkthrough-client' };
  if (p === '/api/heartbeat') return { ok: true };
  if (p === '/api/status') return {
    connected: S.connected, restoredWaiting: false, provider: S.connected ? 'GitHub' : null, project: S.connected ? repoName : null,
    branch: S.connected ? (S.branch || S.defaultBranch) : null, defaultBranch: S.defaultBranch || null, workspace: S.workspace || null,
    hasBaseline: !!S.baseline, ai: false, canReview: !!(S.lastSave && !S.reviewUrl), autoStop: true, localDev: true, devProvider: fake.url,
  };
  if (p === '/api/integrations') return {
    storeAvailable: true, storeProtection: 'Windows DPAPI (current user)',
    credentials: [
      // TEST MODE: the saved GitHub token is simulated (LocalDev gives the host a fake token).
      { provider: 'GitHub', configured: true, source: 'stored', environmentVariable: 'GITHUB_TOKEN', storedAt: '2026-10-25T14:00:00Z', storedUnreadable: false, lazaretteItem: '', lazaretteItemFound: false },
      { provider: 'GitLab', configured: false, source: 'none', environmentVariable: 'GITLAB_TOKEN', storedAt: '', storedUnreadable: false, lazaretteItem: '', lazaretteItemFound: false },
      { provider: 'GenAi', configured: false, source: 'none', environmentVariable: 'GANGPLANK_AI_TOKEN', storedAt: '', storedUnreadable: false, lazaretteItem: '', lazaretteItemFound: false },
    ],
    lazarette: { enabled: false, configuredPath: '', fromEnvironment: false, status: null },
  };
  if (p === '/api/settings') return {
    workspaces: { root: workRoot, default: workRoot, fixed: false },
    intelligence: { endpoint: 'https://api.genai.mil/v1', model: '', profile: 'openai', source: 'default', tokenReady: false, allowedHosts: [], problem: '' },
  };
  if (p === '/api/audit') return { entries: S.audit.slice(0, 30) };
  if (p === '/api/insights') {
    const [b, r] = [await branches(), await reviews()];
    const notes = r.length ? [r.length + ' open review request(s) need attention.'] : ['No outstanding branch divergence or reviews were identified in this limited check.'];
    return { Project: repoName, Branch: S.branch || S.defaultBranch, BranchCount: b.length, OpenReviewCount: r.length, Suggestions: notes };
  }
  if (p === '/api/branches') return { branches: await branches(), defaultBranch: S.defaultBranch };
  if (p === '/api/reviews') return { reviews: await reviews() };
  if (p === '/api/history') {
    const branch = query.get('branch') || S.branch || S.defaultBranch;
    const rows = await gh('GET', '/commits?sha=' + encodeURIComponent(branch) + '&per_page=30');
    return { branch, commits: rows.map((c) => ({ Sha: c.sha, Title: c.commit.message.split(/\r?\n/)[0], Author: c.commit.author.name, Date: psDate(c.commit.author.date), Url: c.html_url })) };
  }
  if (p === '/api/preview') return S.baseline
    ? { ready: true, changes: S.changes.map(({ Content, ...c }) => c), remoteChanged: false, branch: S.branch, workspace: S.workspace }
    : { ready: false, changes: [], remoteChanged: false };
  if (p === '/api/sentinel') return { destination: { Host: '127.0.0.1', Visibility: 'private', Public: false, Verified: true }, findings: [], publicPublishingEnabled: false };
  let m = /^\/api\/jobs\/(job-[a-f0-9]{12})$/.exec(p);
  if (m) { const j = jobs.get(m[1]); return { state: j.error ? 'failed' : 'succeeded', result: j.result, error: j.error, next: 0, progress: '' }; }
  if (method === 'POST' && work[p]) {
    const id = 'job-' + (++jobSeq).toString(16).padStart(12, '0');
    try { jobs.set(id, { result: await work[p](body || {}) }); } catch (e) { console.error(e); jobs.set(id, { error: 'SERVER_ERROR|' + e.message }); }
    return { job: id };
  }
  return null;
}

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.woff2': 'font/woff2' };
const browser = await playwright.chromium.launch();
try {
  fs.mkdirSync(out, { recursive: true });
  fs.mkdirSync(readmeOut, { recursive: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, colorScheme: 'dark' });
  await context.route(origin + '/**', async (route) => {
    const req = route.request(), u = new URL(req.url());
    if (u.pathname.startsWith('/api/')) {
      let body = null; try { body = req.postDataJSON(); } catch { }
      const x = await api(req.method(), u.pathname, u.searchParams, body);
      return route.fulfill(x ? { status: 200, contentType: 'application/json', body: JSON.stringify(x) } : { status: 404, contentType: 'application/json', body: '{"error":"NOT_FOUND","message":"Route not found."}' });
    }
    const file = path.join(web, u.pathname === '/' ? 'index.html' : decodeURIComponent(u.pathname));
    if (!file.startsWith(web) || !fs.existsSync(file)) return route.fulfill({ status: 404, body: '' });
    return route.fulfill({ status: 200, contentType: TYPES[path.extname(file)] || 'application/octet-stream', body: fs.readFileSync(file) });
  });
  const page = await context.newPage();
  page.on('dialog', (d) => d.accept());   // the publish and review confirmations
  page.on('pageerror', (e) => console.error('page error: ' + e.message));
  await page.addInitScript(() => { try { localStorage.setItem('gangplank-sidebar', 'expanded'); } catch { } });
  const el = (id) => page.locator('#' + id);
  const shot = async (name, p = page, dir = out) => { await p.evaluate(() => document.activeElement?.blur()); await p.waitForTimeout(400); await p.screenshot({ path: path.join(dir, name) }); console.log('wrote ' + path.join(dir, name)); };
  const scrollTo = (id, offset = 24) => page.evaluate(([i, o]) => { const m = document.getElementById('main'); m.scrollTop = 0; m.scrollTop = document.getElementById(i).closest('.panel').getBoundingClientRect().top - m.getBoundingClientRect().top - o; }, [id, offset]);
  const tab = async (name) => { await page.click(`.nav button[data-tab="${name}"]`); };

  await page.goto(origin + '/');
  await page.waitForFunction(() => document.getElementById('online').textContent.includes('connected'));
  await page.waitForFunction(() => document.getElementById('repoUrl').value.includes('gangplank-demo/sample'));
  await shot('01-first-launch.png');

  await el('connectBtn').click();
  await page.waitForFunction(() => /branches/.test(document.getElementById('insightsSummary').textContent));
  await page.evaluate(() => { document.getElementById('main').scrollTop = 0; });
  await shot('02-connect-project.png');

  // README pair: the connected Overview in both themes, opened in a second tab as a reload would show it.
  for (const [scheme, name] of [['dark', 'workspace-night-watch.png'], ['light', 'workspace-chart-room.png']]) {
    const p = await context.newPage();
    await p.emulateMedia({ colorScheme: scheme });
    await p.goto(origin + '/');
    await p.waitForFunction(() => document.getElementById('projectTitle').textContent === 'gangplank-demo/sample');
    await p.waitForFunction(() => /branches/.test(document.getElementById('insightsSummary').textContent));
    await shot(name, p, readmeOut);
    await p.close();
  }

  await el('workName').fill(workName);
  await scrollTo('workName');
  await shot('03-start-workspace.png');

  await el('startBtn').click();
  await page.waitForFunction(() => /created and downloaded/.test(document.getElementById('notice').textContent));
  await tab('changes');
  await el('refreshBtn').click();
  await page.waitForFunction(() => document.getElementById('selectedCount').textContent === '2 selected');
  await shot('04-smart-save-review.png');

  await el('saveBtn').click();
  await page.waitForFunction(() => /^Published/.test(document.getElementById('saveNotice').textContent));
  await page.waitForFunction(() => !document.getElementById('reviewBtn').disabled);
  await el('reviewBtn').click();
  await page.waitForFunction(() => /^Review created/.test(document.getElementById('saveNotice').textContent));
  await tab('reviews');
  await page.waitForFunction(() => document.querySelectorAll('#reviewsList .repoRow').length >= 2);
  await shot('05-review-request.png');

  await tab('activity');
  await page.waitForFunction(() => document.querySelectorAll('#commitList .repoRow').length >= 1);
  await shot('06-activity.png');

  await tab('integrations');
  await page.waitForFunction(() => document.querySelectorAll('#credList .credRow').length === 3);
  await page.waitForFunction(() => document.getElementById('aiCurrent').textContent.length > 0);
  await shot('07-settings-credentials.png');
  await context.close();
} finally {
  await browser.close();
  await fake.close();
}
