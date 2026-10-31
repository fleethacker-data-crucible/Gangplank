// Synthetic GitLab REST v4 server for Gangplank LocalDev and end-to-end tests.
//
// It implements what Gangplank calls, with GitLab's real shapes: projects (by id or URL-encoded
// path), repository/branches (list with page headers, one, create), repository/commits (list and
// multi-file create with per-file `last_commit_id` conflict checks), repository/files (metadata and
// raw), repository/archive.zip (a real zip with GitLab's top-level folder), repository/compare and
// merge_requests. Auth is the PRIVATE-TOKEN header. All data is fictional.
//
//   node dev/fake-gitlab.mjs [port|0] [--token=x] [--branches=N] [--verbose]
//
// prints one JSON line {"url":"http://127.0.0.1:PORT","token":"..."} once listening (127.0.0.1 only).
//
// Control endpoints (fake only, no auth): POST /__fake/reset, GET /__fake/state, POST /__fake/fail,
// POST /__fake/advance (a teammate commits), POST /__fake/hook (advance right after a matching
// request is answered, to model a race), DELETE /__fake/calls. Zero dependencies; Node 22+.
//
// Error bodies for rarely hit cases (the exact wording of validation messages) are approximations.
import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { buildZip } from './fake-github.mjs';

export const DEFAULT_TOKEN = 'fake-gangplank-gitlab-token';
const SEED_EPOCH = Date.UTC(2026, 9, 20, 9, 0, 0) / 1000; // 2026-10-20T09:00:00Z, fixed so seed SHAs are stable
const API_USER = { id: 4001, username: 'fake-gangplank-user', name: 'Fake Gangplank User', email: 'fake-gangplank-user@example.test' };
const TEAMMATE = { id: 4002, username: 'teammate-tess', name: 'Teammate Tess', email: 'tess@example.test' };
const CONTRIBUTOR = { id: 4003, username: 'demo-contributor', name: 'Demo Contributor', email: 'demo-contributor@example.test' };

// ---------------------------------------------------------------- errors / small helpers

class HttpError extends Error {
  constructor(status, message, { raw = false, headers = {} } = {}) {
    super(typeof message === 'string' ? message : JSON.stringify(message));
    this.status = status;
    this.payload = raw ? message : { message };
    this.headers = headers;
  }
}
const notFound = (what = 'Not Found') => new HttpError(404, `404 ${what}`);
const missing = (name) => new HttpError(400, { error: `${name} is missing` }, { raw: true });
const sha1 = (buf) => createHash('sha1').update(buf).digest('hex');
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const gitBlobId = (buf) => sha1(Buffer.concat([Buffer.from(`blob ${buf.length}\0`), buf]));
const iso = (secs) => new Date(secs * 1000).toISOString();
const isHex = (s) => typeof s === 'string' && /^[0-9a-f]{7,40}$/.test(s);

function lineDiffText(a, b) {
  const split = (buf) => { const t = buf.toString('utf8'); if (!t) return []; const l = t.split('\n'); if (t.endsWith('\n')) l.pop(); return l; };
  const x = split(a);
  const y = split(b);
  const lines = [...x.map((l) => `-${l}`), ...y.map((l) => `+${l}`)];
  return `@@ -${x.length ? 1 : 0},${x.length} +${y.length ? 1 : 0},${y.length} @@\n${lines.join('\n')}${lines.length ? '\n' : ''}`;
}
function countLines(buf) {
  if (!buf.length) return 0;
  const t = buf.toString('utf8');
  const n = t.split('\n').length;
  return t.endsWith('\n') ? n - 1 : n;
}

// ---------------------------------------------------------------- project / commit store

class Project {
  constructor(store, { id, path, visibility = 'private', description = '', defaultBranch = 'main' }) {
    this.store = store;
    this.id = id;
    this.path = path; // namespace/.../name
    this.visibility = visibility;
    this.description = description;
    this.defaultBranch = defaultBranch;
    this.commits = new Map(); // id -> commit
    this.branches = new Map(); // name -> commit id
    this.mrs = [];
    this.nextIid = 1;
  }
  get name() { return this.path.split('/').pop(); }
  get namespace() { return this.path.split('/').slice(0, -1).join('/'); }
  get isEmpty() { return this.branches.size === 0; }

  // files: Map(path -> {data, mode, last}); entries with last === null get the new commit id.
  addCommit({ parents = [], files, message, author, secs }) {
    const created = secs ?? this.store.tick();
    const digest = [...files].sort(([a], [b]) => (a < b ? -1 : 1)).map(([p, f]) => [p, sha1(f.data), f.mode, f.last]);
    const id = sha1(JSON.stringify([this.path, parents, message, author.email, created, digest]));
    const tree = new Map();
    for (const [p, f] of files) tree.set(p, { data: f.data, mode: f.mode, last: f.last ?? id });
    const commit = { id, seq: ++this.store.commitSeq, parents: [...parents], message, author, committer: author, created, tree };
    this.commits.set(id, commit);
    return commit;
  }

  // Branch name, full SHA or unique >=7 char SHA prefix -> commit, or null.
  resolve(ref) {
    if (typeof ref !== 'string' || !ref) return null;
    if (this.branches.has(ref)) return this.commits.get(this.branches.get(ref));
    if (isHex(ref)) {
      if (this.commits.has(ref)) return this.commits.get(ref);
      const hits = [...this.commits.keys()].filter((k) => k.startsWith(ref));
      if (hits.length === 1) return this.commits.get(hits[0]);
    }
    return null;
  }

  ancestors(id) {
    const seen = new Set();
    const stack = [id];
    while (stack.length) {
      const s = stack.pop();
      if (seen.has(s)) continue;
      seen.add(s);
      stack.push(...this.commits.get(s).parents);
    }
    return seen;
  }

  mergeBase(a, b) {
    const left = this.ancestors(a);
    const common = [...this.ancestors(b)].filter((x) => left.has(x));
    common.sort((x, y) => this.commits.get(y).seq - this.commits.get(x).seq);
    return common[0] ?? null;
  }

  // Seed helper: {path: string | {content, mode} | null} on top of a parent commit.
  commitFiles(parent, changes, message, author) {
    const files = new Map(parent ? [...parent.tree].map(([p, f]) => [p, { ...f }]) : []);
    for (const [p, v] of Object.entries(changes)) {
      if (v === null) { files.delete(p); continue; }
      const data = Buffer.from(typeof v === 'string' ? v : v.content, 'utf8');
      const mode = (typeof v === 'object' && v.mode) || files.get(p)?.mode || '100644';
      const old = files.get(p);
      files.set(p, old && old.data.equals(data) && old.mode === mode ? old : { data, mode, last: null });
    }
    return this.addCommit({ parents: parent ? [parent.id] : [], files, message, author: this.store.signature(author) });
  }

  // GitLab's POST /repository/commits: all actions apply to a working copy or none of them do.
  applyActions(base, actions) {
    const files = new Map([...base.tree].map(([p, f]) => [p, { ...f }]));
    const touched = new Set();
    const validPath = (p) => typeof p === 'string' && p !== '' && !p.startsWith('/') && !p.endsWith('/') && !p.split('/').some((s) => s === '' || s === '.' || s === '..' || s === '.git');
    const check = (a, path, entry, verb) => {
      if (a.last_commit_id !== undefined && a.last_commit_id !== null && a.last_commit_id !== '') {
        if (touched.has(path) || entry.last !== a.last_commit_id) {
          throw new HttpError(400, `You are attempting to ${verb} a file that has changed since you started editing it.`);
        }
      }
    };
    const body = (a, i) => {
      if (typeof a.content !== 'string') throw missing(`actions[${i}][content]`);
      const enc = a.encoding ?? 'text';
      if (enc === 'base64') {
        if (!/^[A-Za-z0-9+/]*={0,2}$/.test(a.content.replace(/\s+/g, ''))) throw new HttpError(400, 'Content is not valid base64');
        return Buffer.from(a.content, 'base64');
      }
      if (enc !== 'text') throw new HttpError(400, { error: `actions[${i}][encoding] does not have a valid value` }, { raw: true });
      return Buffer.from(a.content, 'utf8');
    };
    let additions = 0;
    let deletions = 0;
    actions.forEach((a, i) => {
      if (!a || typeof a !== 'object') throw new HttpError(400, { error: `actions[${i}] is invalid` }, { raw: true });
      if (!['create', 'delete', 'move', 'update', 'chmod'].includes(a.action)) throw new HttpError(400, { error: `actions[${i}][action] does not have a valid value` }, { raw: true });
      if (!validPath(a.file_path)) throw new HttpError(400, { error: `actions[${i}][file_path] is invalid` }, { raw: true });
      const path = a.file_path;
      const exists = files.get(path);
      if (a.action === 'create') {
        const data = body(a, i);
        if (exists) throw new HttpError(400, 'A file with this name already exists');
        files.set(path, { data, mode: a.execute_filemode ? '100755' : '100644', last: null });
        additions += countLines(data);
      } else if (a.action === 'update') {
        const data = body(a, i);
        if (!exists) throw new HttpError(400, "A file with this name doesn't exist");
        check(a, path, exists, 'update');
        const mode = a.execute_filemode === undefined ? exists.mode : (a.execute_filemode ? '100755' : '100644');
        // Same content and mode: git sees no change, so the file's last commit stays.
        files.set(path, exists.data.equals(data) && exists.mode === mode ? exists : { data, mode, last: null });
        if (!exists.data.equals(data)) { additions += countLines(data); deletions += countLines(exists.data); }
      } else if (a.action === 'delete') {
        if (!exists) throw new HttpError(400, "A file with this name doesn't exist");
        check(a, path, exists, 'delete');
        files.delete(path);
        deletions += countLines(exists.data);
      } else if (a.action === 'move') {
        const from = a.previous_path;
        if (!validPath(from)) throw new HttpError(400, { error: `actions[${i}][previous_path] is invalid` }, { raw: true });
        const src = files.get(from);
        if (!src) throw new HttpError(400, "A file with this name doesn't exist");
        if (exists) throw new HttpError(400, 'A file with this name already exists');
        check(a, from, src, 'move');
        files.delete(from);
        files.set(path, { data: typeof a.content === 'string' ? body(a, i) : src.data, mode: src.mode, last: null });
        touched.add(from);
      } else if (a.action === 'chmod') {
        if (!exists) throw new HttpError(400, "A file with this name doesn't exist");
        if (typeof a.execute_filemode !== 'boolean') throw missing(`actions[${i}][execute_filemode]`);
        check(a, path, exists, 'update');
        files.set(path, { ...exists, mode: a.execute_filemode ? '100755' : '100644', last: null });
      }
      touched.add(path);
    });
    return { files, stats: { additions, deletions, total: additions + deletions } };
  }
}

// ---------------------------------------------------------------- seed

function seed(store) {
  store.clock = SEED_EPOCH;
  store.commitSeq = 0;
  store.projects = new Map();
  store.nextProjectId = 1001;

  const sample = store.addProject({ path: 'gangplank-demo/sample', visibility: 'private', description: 'Fictional sample project for Gangplank LocalDev' });
  const c1 = sample.commitFiles(null, {
    'README.md': '# Sample\n\nFictional demo project for Gangplank local development.\nNothing here is real.\n',
    'src/app.ps1': "Write-Output 'Hello from the sample app'\n",
  }, 'Initial commit', CONTRIBUTOR);
  const c2 = sample.commitFiles(c1, {
    'scripts/build.sh': { content: '#!/bin/sh\nset -e\necho "building sample"\n', mode: '100755' },
    'docs/guide.md': '# Guide\n\n1. Download the workspace.\n2. Edit a file.\n3. Save to a work branch.\n',
  }, 'Add build script and guide', CONTRIBUTOR);
  const c3 = sample.commitFiles(c2, {
    'docs/guide.md': '# Guide\n\n1. Download the workspace.\n2. Edit a file.\n3. Save to a work branch.\n4. Open a review.\n',
    'src/demo.ps1': "Write-Output 'Demo feature'\n",
  }, 'Demo: extend guide and add demo script', CONTRIBUTOR);
  sample.branches.set('main', c2.id);
  sample.branches.set('feature/demo', c3.id);
  sample.branches.set('release/2026.10', c1.id);
  for (let i = 1; i <= store.options.extraBranches; i++) sample.branches.set(`bulk/branch-${String(i).padStart(4, '0')}`, c2.id);
  store.addMr(sample, { title: 'Demo feature', description: 'Extends the guide and adds a demo script.', source: 'feature/demo', target: 'main', author: CONTRIBUTOR });
  store.addMr(sample, { title: 'Old release notes', description: '', source: 'release/2026.10', target: 'main', author: CONTRIBUTOR, state: 'closed' });

  const site = store.addProject({ path: 'gangplank-demo/public-site', visibility: 'public', description: 'Fictional public project' });
  site.branches.set('main', site.commitFiles(null, { 'index.html': '<!doctype html><title>Public demo</title>\n' }, 'Initial public page', CONTRIBUTOR).id);

  // A project in a nested group: the encoded path has two %2F.
  const nested = store.addProject({ path: 'gangplank-demo/team/nested-app', visibility: 'internal', description: 'Fictional project in a subgroup' });
  nested.branches.set('main', nested.commitFiles(null, { 'app/main.py': "print('nested')\n", 'notes.txt': 'Fictional.\n' }, 'Initial nested commit', CONTRIBUTOR).id);

  store.addProject({ path: 'gangplank-demo/empty', visibility: 'private', description: 'Fictional empty project', defaultBranch: null });
}

// ---------------------------------------------------------------- JSON shapes

function shapes(store, project) {
  const web = `${store.url}/${project.path}`;
  const person = (p) => ({ id: p.id ?? null, username: p.username ?? null, name: p.name, state: 'active', avatar_url: null, web_url: p.username ? `${store.url}/${p.username}` : null });
  const commit = (c) => ({
    id: c.id, short_id: c.id.slice(0, 8), created_at: iso(c.created), parent_ids: c.parents,
    title: c.message.split('\n')[0], message: c.message,
    author_name: c.author.name, author_email: c.author.email, authored_date: iso(c.created),
    committer_name: c.committer.name, committer_email: c.committer.email, committed_date: iso(c.created),
    trailers: {}, extended_trailers: {}, web_url: `${web}/-/commit/${c.id}`,
  });
  const branch = (name) => {
    const head = project.commits.get(project.branches.get(name));
    const def = project.branches.get(project.defaultBranch);
    return {
      name, commit: commit(head), merged: name !== project.defaultBranch && def ? project.ancestors(def).has(head.id) : false,
      protected: name === project.defaultBranch, developers_can_push: false, developers_can_merge: false, can_push: true,
      default: name === project.defaultBranch, web_url: `${web}/-/tree/${name}`,
    };
  };
  const projectJson = () => {
    const ns = project.namespace;
    return {
      id: project.id, description: project.description, name: project.name, name_with_namespace: project.path.split('/').join(' / '),
      path: project.name, path_with_namespace: project.path, created_at: iso(SEED_EPOCH), default_branch: project.isEmpty ? null : project.defaultBranch,
      tag_list: [], topics: [], ssh_url_to_repo: `git@gitlab.example.test:${project.path}.git`, http_url_to_repo: `${web}.git`, web_url: web,
      readme_url: null, avatar_url: null, star_count: 0, forks_count: 0, last_activity_at: iso(store.clock),
      namespace: { id: 2001, name: ns.split('/').pop(), path: ns.split('/').pop(), kind: 'group', full_path: ns, parent_id: null, web_url: `${store.url}/groups/${ns}` },
      visibility: project.visibility, archived: false, empty_repo: project.isEmpty, issues_enabled: true, merge_requests_enabled: true,
      permissions: { project_access: { access_level: 30, notification_level: 3 }, group_access: null },
    };
  };
  const mr = (m) => {
    const src = project.branches.get(m.source);
    return {
      id: 600000 + project.id * 10 + m.iid, iid: m.iid, project_id: project.id, title: m.title, description: m.description, state: m.state,
      created_at: m.created_at, updated_at: m.updated_at, merged_at: null, closed_at: m.state === 'closed' ? m.updated_at : null,
      target_branch: m.target, source_branch: m.source, author: person(m.author), assignees: [], reviewers: [], source_project_id: project.id,
      target_project_id: project.id, labels: [], draft: false, work_in_progress: false, sha: src ?? null, merge_status: 'can_be_merged',
      detailed_merge_status: 'mergeable', has_conflicts: false, user_notes_count: 0, web_url: `${web}/-/merge_requests/${m.iid}`,
      references: { short: `!${m.iid}`, relative: `!${m.iid}`, full: `${project.path}!${m.iid}` },
    };
  };
  return { commit, branch, projectJson, mr, web, person };
}

function paginate(urlObj, items, defaultPer = 20) {
  const per = Math.min(100, Math.max(1, Number.parseInt(urlObj.searchParams.get('per_page') ?? '', 10) || defaultPer));
  const page = Math.max(1, Number.parseInt(urlObj.searchParams.get('page') ?? '', 10) || 1);
  const last = Math.max(1, Math.ceil(items.length / per));
  const link = (p) => { const u = new URL(urlObj); u.searchParams.set('per_page', String(per)); u.searchParams.set('page', String(p)); return u.toString(); };
  const rels = [];
  if (page < last) rels.push(`<${link(page + 1)}>; rel="next"`);
  if (page > 1) rels.push(`<${link(Math.min(page - 1, last))}>; rel="prev"`);
  rels.push(`<${link(1)}>; rel="first"`, `<${link(last)}>; rel="last"`);
  return {
    items: items.slice((page - 1) * per, page * per),
    headers: {
      Link: rels.join(', '), 'X-Next-Page': page < last ? String(page + 1) : '', 'X-Page': String(page), 'X-Per-Page': String(per),
      'X-Prev-Page': page > 1 ? String(Math.min(page - 1, last)) : '', 'X-Total': String(items.length), 'X-Total-Pages': String(last),
    },
  };
}

// ---------------------------------------------------------------- store

class Store {
  constructor(options) {
    this.options = options;
    this.token = options.token;
    this.url = '';
    this.calls = [];
    this.faults = [];
    this.hooks = [];
    this.seq = 0;
    seed(this);
  }
  reset() {
    this.calls = [];
    this.faults = [];
    this.hooks = [];
    this.seq = 0;
    seed(this);
  }
  tick() { this.clock += 60; return this.clock; }
  signature(p) { return { id: p.id, username: p.username, name: p.name, email: p.email }; }
  addProject(opts) {
    const p = new Project(this, { ...opts, id: this.nextProjectId++ });
    this.projects.set(p.path.toLowerCase(), p);
    return p;
  }
  addMr(project, { title, description, source, target, author, state = 'opened' }) {
    const at = iso(this.tick());
    const m = { iid: project.nextIid++, title, description: description ?? '', source, target, author, state, created_at: at, updated_at: at };
    project.mrs.push(m);
    return m;
  }
  project(ref) {
    const key = String(ref);
    if (/^\d+$/.test(key)) return [...this.projects.values()].find((p) => p.id === Number(key)) ?? null;
    return this.projects.get(key.toLowerCase()) ?? null;
  }

  // A teammate commits to a branch outside Gangplank. files: {path: content | null}, or one path/content.
  advance({ project: name = 'gangplank-demo/sample', branch, path = 'TEAMMATE.md', content, files, message, mode } = {}) {
    const project = this.project(name);
    if (!project) throw notFound('Project Not Found');
    const b = branch ?? project.defaultBranch;
    const parentId = project.branches.get(b);
    if (!parentId) throw notFound('Branch Not Found');
    const parent = project.commits.get(parentId);
    const n = project.ancestors(parentId).size + 1;
    const changes = files ?? { [path]: { content: content ?? `${parent.tree.has(path) ? parent.tree.get(path).data.toString('utf8') : '# Teammate notes\n'}Outside change ${n} by ${TEAMMATE.name}\n`, mode } };
    const commit = project.commitFiles(parent, changes, message ?? `Teammate update ${n}`, TEAMMATE);
    project.branches.set(b, commit.id);
    return { project: project.path, branch: b, id: commit.id, parent: parentId, paths: Object.keys(changes) };
  }

  addFault(rule) {
    const f = {
      id: ++this.seq, method: rule.method ? String(rule.method).toUpperCase() : null, pathContains: rule.pathContains ?? null,
      status: Number(rule.status ?? 500), times: Number(rule.times ?? 1), retryAfter: rule.retryAfter ?? null,
      body: rule.body ?? null, headers: rule.headers ?? {}, delayMs: Number(rule.delayMs ?? 0), dropConnection: Boolean(rule.dropConnection),
    };
    if (!(f.times > 0)) throw new HttpError(400, { error: 'times must be > 0' }, { raw: true });
    this.faults.push(f);
    return f;
  }
  takeFault(method, path) {
    const f = this.faults.find((x) => x.times > 0 && (!x.method || x.method === method) && (!x.pathContains || path.includes(x.pathContains)));
    if (!f) return null;
    f.times -= 1;
    this.faults = this.faults.filter((x) => x.times > 0);
    return f;
  }

  // Hooks run a teammate commit right AFTER a matching request has been answered (after `skip`
  // matches), so the next request sees the move. Models a race between two of Gangplank's calls.
  addHook(rule) {
    const h = {
      id: ++this.seq, method: rule.method ? String(rule.method).toUpperCase() : null, pathContains: rule.pathContains ?? null,
      skip: Number(rule.skip ?? 0), times: Number(rule.times ?? 1), advance: rule.advance ?? {},
    };
    this.hooks.push(h);
    return h;
  }
  takeHook(method, path) {
    const h = this.hooks.find((x) => x.times > 0 && (!x.method || x.method === method) && (!x.pathContains || path.includes(x.pathContains)));
    if (!h) return null;
    if (h.skip > 0) { h.skip -= 1; return null; }
    h.times -= 1;
    this.hooks = this.hooks.filter((x) => x.times > 0);
    return h;
  }

  snapshot() {
    const projects = {};
    for (const p of this.projects.values()) {
      projects[p.path] = {
        id: p.id, default_branch: p.isEmpty ? null : p.defaultBranch, visibility: p.visibility,
        branches: Object.fromEntries(p.branches),
        merge_requests: p.mrs.map((m) => ({ iid: m.iid, state: m.state, title: m.title, source_branch: m.source, target_branch: m.target })),
      };
    }
    return { url: this.url, token: this.token, calls: this.calls, faults: this.faults, hooks: this.hooks, projects };
  }
}

// ---------------------------------------------------------------- HTTP helpers

function readBody(req, limit = 64 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new HttpError(413, '413 Request Entity Too Large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function parseBody(buf, req, call) {
  if (!buf.length) return {};
  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    call.invalidUtf8Body = true; // e.g. a Windows PowerShell 5.1 string body sent as ISO-8859-1
    throw new HttpError(400, { error: 'body is invalid' }, { raw: true });
  }
  if ((req.headers['content-type'] ?? '').startsWith('application/x-www-form-urlencoded')) return Object.fromEntries(new URLSearchParams(text));
  try {
    const v = JSON.parse(text);
    if (v === null || typeof v !== 'object' || Array.isArray(v)) throw new Error('not an object');
    return v;
  } catch {
    throw new HttpError(400, { error: 'body is invalid' }, { raw: true });
  }
}

const defaultMessages = {
  400: '400 Bad Request', 401: '401 Unauthorized', 403: '403 Forbidden', 404: '404 Not Found', 409: '409 Conflict', 422: '422 Unprocessable Entity',
  429: 'Retry later', 500: '500 Internal Server Error', 502: '502 Bad Gateway', 503: '503 Service Unavailable',
};

function send(res, status, buf, headers = {}) {
  res.writeHead(status, { 'Content-Length': buf.length, 'X-Request-Id': randomBytes(8).toString('hex'), ...headers });
  res.end(buf);
}
function sendJson(res, status, payload, headers = {}) {
  const body = payload === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(payload));
  send(res, status, body, { 'Content-Type': 'application/json', ...headers });
}
function sendError(res, err) { sendJson(res, err.status, err.payload, err.headers); }

function decode(raw) {
  try { return decodeURIComponent(raw); } catch { throw notFound(); }
}

function authorised(req, token) {
  const h = req.headers['private-token'];
  if (h !== undefined) return h === token;
  const bearer = /^Bearer\s+(.+)$/i.exec(req.headers.authorization ?? '');
  return Boolean(bearer) && bearer[1].trim() === token;
}

async function handleControl(store, req, res, path, body) {
  if (req.method === 'POST' && path === '/__fake/reset') { store.reset(); return sendJson(res, 200, { ok: true, state: store.snapshot() }); }
  if (req.method === 'GET' && path === '/__fake/state') return sendJson(res, 200, store.snapshot());
  if (req.method === 'DELETE' && path === '/__fake/calls') { store.calls = []; return sendJson(res, 200, { ok: true }); }
  if (req.method === 'POST' && path === '/__fake/fail') return sendJson(res, 201, store.addFault(body));
  if (req.method === 'POST' && path === '/__fake/advance') return sendJson(res, 201, store.advance(body));
  if (req.method === 'POST' && path === '/__fake/hook') return sendJson(res, 201, store.addHook(body));
  throw notFound();
}

// ---------------------------------------------------------------- project routes

function pageOf(urlObj, items, defaultPer) { return paginate(urlObj, items, defaultPer); }

function diffTrees(from, to) {
  const out = [];
  for (const path of [...new Set([...from.keys(), ...to.keys()])].sort()) {
    const x = from.get(path);
    const y = to.get(path);
    if (x && y && x.data.equals(y.data) && x.mode === y.mode) continue;
    out.push({
      old_path: path, new_path: path, a_mode: x ? x.mode : '0', b_mode: y ? y.mode : '0',
      new_file: !x, renamed_file: false, deleted_file: !y, generated_file: false,
      diff: lineDiffText(x?.data ?? Buffer.alloc(0), y?.data ?? Buffer.alloc(0)),
    });
  }
  return out;
}

function handleProject(store, req, res, urlObj, project, rest, rawBody, body) {
  const method = req.method;
  const S = shapes(store, project);
  const q = urlObj.searchParams;
  // GitLab takes parameters from the query string or the body.
  const params = { ...Object.fromEntries(q), ...body };
  let m;

  if (rest === '' || rest === '/') {
    if (method === 'GET') return sendJson(res, 200, S.projectJson());
    throw notFound();
  }

  // ---- branches
  if (rest === '/repository/branches' && method === 'GET') {
    let names = [...project.branches.keys()];
    if (params.search) {
      const s = String(params.search);
      names = names.filter((n) => (s.startsWith('^') ? n.startsWith(s.slice(1)) : s.endsWith('$') ? n.endsWith(s.slice(0, -1)) : n.includes(s)));
    }
    names.sort();
    if (params.sort === 'name_desc') names.reverse();
    const { items, headers } = pageOf(urlObj, names, 20);
    return sendJson(res, 200, items.map((n) => S.branch(n)), headers);
  }
  if (rest === '/repository/branches' && method === 'POST') {
    if (!params.branch) throw missing('branch');
    if (!params.ref) throw missing('ref');
    const name = String(params.branch);
    if (/(\.\.|\/\/|@\{|\/\.|\.lock(\/|$)|\/$|^\/|[\s~^:?*[\\])/.test(name) || name.length > 255) throw new HttpError(400, 'Branch name is invalid');
    if (project.branches.has(name)) throw new HttpError(400, 'Branch already exists');
    const from = project.resolve(String(params.ref));
    if (!from) throw new HttpError(400, `Invalid reference name: ${params.ref}`);
    project.branches.set(name, from.id);
    return sendJson(res, 201, S.branch(name));
  }
  if ((m = /^\/repository\/branches\/(.+)$/.exec(rest)) && method === 'GET') {
    const name = decode(m[1]);
    if (!project.branches.has(name)) throw notFound('Branch Not Found');
    return sendJson(res, 200, S.branch(name));
  }

  // ---- archive
  if (rest === '/repository/archive.zip' && method === 'GET') {
    const ref = params.sha ?? project.defaultBranch;
    const c = project.resolve(ref);
    if (!c) throw notFound('File Not Found');
    const top = `${project.name}-${String(ref).replace(/\//g, '-')}-${c.id}`;
    const dirs = new Set();
    const entries = [{ name: `${top}/`, dir: true }];
    for (const p of [...c.tree.keys()].sort()) {
      const parts = p.split('/');
      for (let i = 1; i < parts.length; i++) {
        const d = parts.slice(0, i).join('/');
        if (!dirs.has(d)) { dirs.add(d); entries.push({ name: `${top}/${d}/`, dir: true }); }
      }
      const f = c.tree.get(p);
      entries.push({ name: `${top}/${p}`, data: f.data, mode: f.mode });
    }
    const zip = buildZip(entries, { secs: c.created, comment: c.id });
    return send(res, 200, zip, {
      'Content-Type': 'application/zip', 'Content-Disposition': `attachment; filename="${top}.zip"`, 'Content-Transfer-Encoding': 'binary',
    });
  }

  // ---- commits
  if (rest === '/repository/commits' && method === 'GET') {
    const head = project.resolve(String(params.ref_name ?? project.defaultBranch ?? ''));
    let list = [];
    if (head) {
      list = [...project.ancestors(head.id)].map((id) => project.commits.get(id)).sort((a, b) => b.seq - a.seq);
      if (params.path) {
        const p = String(params.path);
        list = list.filter((c) => {
          const here = c.tree.get(p);
          const before = c.parents.length ? project.commits.get(c.parents[0]).tree.get(p) : null;
          return here ? here.last === c.id : Boolean(before);
        });
      }
    }
    const { items, headers } = pageOf(urlObj, list, 20);
    return sendJson(res, 200, items.map((c) => S.commit(c)), headers);
  }
  if (rest === '/repository/commits' && method === 'POST') {
    if (!params.branch) throw missing('branch');
    if (typeof params.commit_message !== 'string' || !params.commit_message) throw missing('commit_message');
    if (!Array.isArray(params.actions) || params.actions.length === 0) throw missing('actions');
    const name = String(params.branch);
    let base = null;
    if (project.branches.has(name)) base = project.commits.get(project.branches.get(name));
    else if (params.start_branch || params.start_sha) {
      base = project.resolve(String(params.start_branch ?? params.start_sha));
      if (!base) throw new HttpError(400, `Invalid reference name: ${params.start_branch ?? params.start_sha}`);
    } else if (project.isEmpty) {
      base = { id: null, tree: new Map() }; // the first commit of an empty project creates the branch
    } else {
      throw new HttpError(400, 'You can only create or edit files when you are on a branch');
    }
    const { files, stats } = project.applyActions(base, params.actions);
    const author = params.author_name ? { id: null, username: null, name: String(params.author_name), email: String(params.author_email ?? API_USER.email) } : store.signature(API_USER);
    const commit = project.addCommit({ parents: base.id ? [base.id] : [], files, message: params.commit_message, author: { ...author, id: author.id ?? null } });
    project.branches.set(name, commit.id);
    if (!project.defaultBranch) project.defaultBranch = name;
    return sendJson(res, 201, { ...S.commit(commit), stats, status: null, project_id: project.id, last_pipeline: null });
  }
  if ((m = /^\/repository\/commits\/([^/]+)$/.exec(rest)) && method === 'GET') {
    const c = project.resolve(decode(m[1]));
    if (!c) throw notFound('Commit Not Found');
    return sendJson(res, 200, { ...S.commit(c), stats: { additions: 0, deletions: 0, total: 0 }, status: null, project_id: project.id, last_pipeline: null });
  }

  // ---- files
  if ((m = /^\/repository\/files\/(.+?)(\/raw)?$/.exec(rest)) && (method === 'GET' || method === 'HEAD')) {
    const filePath = decode(m[1]);
    const isRaw = Boolean(m[2]);
    if (!params.ref) throw missing('ref');
    const c = project.resolve(String(params.ref));
    if (!c) throw notFound('File Not Found');
    const f = c.tree.get(filePath);
    if (!f) throw notFound('File Not Found');
    const meta = {
      'X-Gitlab-Blob-Id': gitBlobId(f.data), 'X-Gitlab-Commit-Id': c.id, 'X-Gitlab-Content-Sha256': sha256(f.data),
      'X-Gitlab-Encoding': 'base64', 'X-Gitlab-File-Name': filePath.split('/').pop(), 'X-Gitlab-File-Path': filePath,
      'X-Gitlab-Last-Commit-Id': f.last, 'X-Gitlab-Ref': String(params.ref), 'X-Gitlab-Size': String(f.data.length),
      'X-Gitlab-Execute-Filemode': String(f.mode === '100755'),
    };
    if (method === 'HEAD') { res.writeHead(200, meta); return res.end(); }
    if (isRaw) {
      let text = true;
      try { new TextDecoder('utf-8', { fatal: true }).decode(f.data); } catch { text = false; }
      return send(res, 200, f.data, { ...meta, 'Content-Type': text ? 'text/plain; charset=utf-8' : 'application/octet-stream' });
    }
    return sendJson(res, 200, {
      file_name: filePath.split('/').pop(), file_path: filePath, size: f.data.length, encoding: 'base64', content_sha256: sha256(f.data),
      ref: String(params.ref), blob_id: gitBlobId(f.data), commit_id: c.id, last_commit_id: f.last,
      execute_filemode: f.mode === '100755', content: f.data.toString('base64'),
    });
  }

  // ---- compare
  if (rest === '/repository/compare' && method === 'GET') {
    if (!params.from) throw missing('from');
    if (!params.to) throw missing('to');
    const from = project.resolve(String(params.from));
    const to = project.resolve(String(params.to));
    if (!from || !to) throw notFound('Ref Not Found');
    const straight = String(params.straight) === 'true';
    const baseId = straight ? from.id : (project.mergeBase(from.id, to.id) ?? from.id);
    const seen = project.ancestors(from.id);
    const commits = [...project.ancestors(to.id)].filter((id) => !seen.has(id)).map((id) => project.commits.get(id)).sort((a, b) => a.seq - b.seq);
    return sendJson(res, 200, {
      commit: S.commit(to), commits: commits.map((c) => S.commit(c)), diffs: diffTrees(project.commits.get(baseId).tree, to.tree),
      compare_timeout: false, compare_same_ref: from.id === to.id, web_url: `${S.web}/-/compare/${params.from}...${params.to}`,
    });
  }

  // ---- merge requests
  if (rest === '/merge_requests' && method === 'GET') {
    const state = params.state ?? 'all';
    let list = project.mrs.filter((x) => state === 'all' || x.state === state);
    if (params.source_branch) list = list.filter((x) => x.source === params.source_branch);
    if (params.target_branch) list = list.filter((x) => x.target === params.target_branch);
    list = [...list].sort((a, b) => b.iid - a.iid);
    const { items, headers } = pageOf(urlObj, list, 20);
    return sendJson(res, 200, items.map((x) => S.mr(x)), headers);
  }
  if (rest === '/merge_requests' && method === 'POST') {
    if (!params.source_branch) throw missing('source_branch');
    if (!params.target_branch) throw missing('target_branch');
    if (!params.title) throw missing('title');
    if (!project.branches.has(params.source_branch)) throw new HttpError(400, ['Source branch does not exist']);
    if (!project.branches.has(params.target_branch)) throw new HttpError(400, ['Target branch does not exist']);
    if (params.source_branch === params.target_branch) throw new HttpError(422, ["You can't use same project/branch for source and target"]);
    const dup = project.mrs.find((x) => x.state === 'opened' && x.source === params.source_branch && x.target === params.target_branch);
    if (dup) throw new HttpError(409, [`Another open merge request already exists for this source branch: !${dup.iid}`]);
    const created = store.addMr(project, { title: String(params.title), description: params.description, source: params.source_branch, target: params.target_branch, author: API_USER });
    return sendJson(res, 201, S.mr(created));
  }
  if ((m = /^\/merge_requests\/(\d+)$/.exec(rest)) && method === 'GET') {
    const found = project.mrs.find((x) => x.iid === Number(m[1]));
    if (!found) throw notFound('Merge Request Not Found');
    return sendJson(res, 200, S.mr(found));
  }

  throw notFound();
}

// ---------------------------------------------------------------- server

export async function startFakeGitLab({ port = 0, token = DEFAULT_TOKEN, extraBranches = 0, verbose = false } = {}) {
  const store = new Store({ token, extraBranches: Number(extraBranches) || 0 });

  const server = createServer(async (req, res) => {
    const urlObj = new URL(req.url, store.url || 'http://127.0.0.1');
    const path = urlObj.pathname; // WHATWG URL keeps %2F encoded, which is what routing needs
    const call = {
      seq: store.calls.length + 1, method: req.method, path, query: urlObj.search,
      auth: authorised(req, store.token) ? 'valid' : (req.headers['private-token'] !== undefined || req.headers.authorization) ? 'invalid' : 'none',
      authorizationSent: Boolean(req.headers['private-token'] || req.headers.authorization), status: null, fault: false,
    };
    const control = path.startsWith('/__fake/');
    if (!control) store.calls.push(call);
    res.on('finish', () => { call.status = res.statusCode; if (verbose) process.stderr.write(`${req.method} ${req.url} -> ${res.statusCode}\n`); });
    try {
      const raw = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method) ? await readBody(req) : Buffer.alloc(0);
      if (control) return await handleControl(store, req, res, path, parseBody(raw, req, call));

      const fault = store.takeFault(req.method, `${path}${urlObj.search}`);
      if (fault) {
        call.fault = true;
        if (fault.delayMs) await new Promise((r) => setTimeout(r, fault.delayMs));
        if (fault.dropConnection) { req.socket.destroy(); return undefined; }
        const headers = { ...fault.headers };
        if (fault.retryAfter !== null) headers['Retry-After'] = String(fault.retryAfter);
        return sendJson(res, fault.status, fault.body ?? { message: defaultMessages[fault.status] ?? 'Injected failure' }, headers);
      }

      if (!authorised(req, store.token)) throw new HttpError(401, '401 Unauthorized');
      const body = parseBody(raw, req, call);
      if (path === '/api/v4/user' && req.method === 'GET') return sendJson(res, 200, { id: API_USER.id, username: API_USER.username, name: API_USER.name, state: 'active' });
      if (path === '/api/v4/version' && req.method === 'GET') return sendJson(res, 200, { version: '17.0.0-fake', revision: 'fake' });
      const m = /^\/api\/v4\/projects\/([^/]+)(\/.*)?$/.exec(path);
      if (!m) throw notFound();
      const project = store.project(decode(m[1]));
      if (!project) throw notFound('Project Not Found');
      call.project = project.path;

      // A hook advances the branch right after this answer is written, before any other request runs.
      const hook = store.takeHook(req.method, `${path}${urlObj.search}`);
      if (hook) {
        const end = res.end.bind(res);
        res.end = (...a) => { const r = end(...a); try { store.advance({ project: project.path, ...hook.advance }); } catch (e) { process.stderr.write(`fake-gitlab hook failed: ${e.message}\n`); } return r; };
      }
      return handleProject(store, req, res, urlObj, project, m[2] ?? '', raw, body);
    } catch (err) {
      if (res.headersSent) { res.destroy(); return undefined; }
      if (err instanceof HttpError) return sendError(res, err);
      process.stderr.write(`fake-gitlab internal error: ${err?.stack ?? err}\n`);
      return sendJson(res, 500, { message: '500 Internal Server Error' });
    }
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(Number(port) || 0, '127.0.0.1', () => { server.off('error', reject); resolve(); });
  });
  const actual = server.address().port;
  store.url = `http://127.0.0.1:${actual}`;

  return {
    url: store.url,
    port: actual,
    token: store.token,
    server,
    store,
    state: () => store.snapshot(),
    reset: () => store.reset(),
    fail: (rule) => store.addFault(rule),
    advance: (opts) => store.advance(opts),
    hook: (rule) => store.addHook(rule),
    close: () => new Promise((resolve) => { server.closeAllConnections?.(); server.close(() => resolve()); }),
  };
}

// ---------------------------------------------------------------- CLI

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const args = process.argv.slice(2);
  const flag = (name) => args.find((a) => a.startsWith(`--${name}=`))?.split('=').slice(1).join('=');
  const positional = args.find((a) => !a.startsWith('--'));
  const fake = await startFakeGitLab({
    port: positional ?? process.env.FAKE_GITLAB_PORT ?? 0,
    token: flag('token') ?? process.env.FAKE_GITLAB_TOKEN ?? DEFAULT_TOKEN,
    extraBranches: flag('branches') ?? 0,
    verbose: args.includes('--verbose'),
  });
  process.stdout.write(`${JSON.stringify({ url: fake.url, token: fake.token })}\n`);
  const stop = () => fake.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
