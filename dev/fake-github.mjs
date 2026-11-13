// Synthetic GitHub REST server for Gangplank LocalDev and end-to-end tests.
//
// It implements the Git Data API (refs, commits, trees, blobs), branches, commits/compare, pulls,
// the Contents API (empty-repo initialisation) and zipball downloads with a GitHub-style 302 to a
// separate, unauthenticated "codeload" path. Objects are stored as real Git objects, so every SHA
// is the one git itself would compute. All data is fictional.
//
//   node dev/fake-github.mjs [port|0] [--token=x] [--branches=N] [--empty-ref-status=409|404] [--verbose]
//
// prints one JSON line {"url":"http://127.0.0.1:PORT","token":"..."} once listening (127.0.0.1 only).
//
// Control endpoints (fake only, no auth): POST /__fake/reset, GET /__fake/state, POST /__fake/fail,
// POST /__fake/advance, POST /__fake/checks, POST /__fake/pull, DELETE /__fake/calls. Zero dependencies; Node 22+.
//
// Reviews: pulls (single GET with mergeable / mergeable_state), pulls/:n/files, pulls/:n/merge (merge commits
// only, with the sha guard and GitHub's 405 / 409 / 422 refusals), issue comments, and check-runs / status for a ref.
import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';
import { pathToFileURL } from 'node:url';

export const DEFAULT_TOKEN = 'fake-gangplank-token';
export const EMPTY_TREE_SHA = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
const SEED_EPOCH = Date.UTC(2026, 9, 20, 9, 0, 0) / 1000; // 2026-10-20T09:00:00Z, fixed so seed SHAs are stable
const API_USER = { login: 'fake-gangplank-user', name: 'Fake Gangplank User', email: 'fake-gangplank-user@example.test' };
const TEAMMATE = { login: 'teammate-tess', name: 'Teammate Tess', email: 'tess@example.test' };
const VALID_MODES = new Set(['100644', '100755', '040000', '160000', '120000']);

// ---------------------------------------------------------------- errors / small helpers

class HttpError extends Error {
  constructor(status, message, extra = {}) {
    super(message);
    this.status = status;
    this.extra = extra;
  }
}
const notFound = () => new HttpError(404, 'Not Found');
const invalid = (message, errors) => new HttpError(422, message, errors ? { errors } : {});
const emptyRepo = () => new HttpError(409, 'Git Repository is empty.');

const sha1 = (buf) => createHash('sha1').update(buf).digest('hex');
const gitHash = (type, body) => sha1(Buffer.concat([Buffer.from(`${type} ${body.length}\0`), body]));
const isHex40 = (s) => typeof s === 'string' && /^[0-9a-f]{40}$/.test(s);
const iso = (secs) => new Date(secs * 1000).toISOString().replace('.000Z', 'Z');

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
export function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function lineCount(buf) {
  if (!buf.length) return 0;
  const text = buf.toString('utf8');
  const n = text.split('\n').length;
  return text.endsWith('\n') ? n - 1 : n;
}

function lineDiff(a, b) {
  // additions/deletions from an LCS over lines (files here are small).
  const split = (buf) => { const t = buf.toString('utf8'); const l = t.split('\n'); if (t.endsWith('\n')) l.pop(); return t ? l : []; };
  const x = split(a);
  const y = split(b);
  const prev = new Array(y.length + 1).fill(0);
  for (let i = 1; i <= x.length; i++) {
    let diag = 0;
    for (let j = 1; j <= y.length; j++) {
      const up = prev[j];
      prev[j] = x[i - 1] === y[j - 1] ? diag + 1 : Math.max(prev[j], prev[j - 1]);
      diag = up;
    }
  }
  const lcs = prev[y.length];
  return { additions: y.length - lcs, deletions: x.length - lcs };
}

// ---------------------------------------------------------------- git object store

class Repo {
  constructor(store, { owner, name, visibility = 'private', defaultBranch = 'main', description = '' }) {
    this.store = store;
    this.owner = owner;
    this.name = name;
    this.visibility = visibility;
    this.defaultBranch = defaultBranch;
    this.description = description;
    this.objects = new Map();
    this.refs = new Map(); // 'heads/main' -> sha
    this.pulls = [];
    this.nextNumber = 1;
    this.checks = new Map(); // head sha -> { runs: [], statuses: [] }
    this.nextCommentId = 1000;
  }
  get fullName() { return `${this.owner}/${this.name}`; }
  get isEmpty() { return this.refs.size === 0; }

  putBlob(data) {
    const buf = Buffer.from(data);
    const sha = gitHash('blob', buf);
    if (!this.objects.has(sha)) this.objects.set(sha, { type: 'blob', data: buf });
    return sha;
  }

  putTree(entries) {
    const key = (e) => Buffer.from(e.type === 'tree' ? `${e.name}/` : e.name);
    const sorted = [...entries].sort((a, b) => Buffer.compare(key(a), key(b)));
    const body = Buffer.concat(sorted.map((e) => Buffer.concat([
      Buffer.from(`${e.mode === '040000' ? '40000' : e.mode} ${e.name}\0`), Buffer.from(e.sha, 'hex'),
    ])));
    const sha = gitHash('tree', body);
    if (!this.objects.has(sha)) {
      this.objects.set(sha, { type: 'tree', entries: sorted.map(({ name, mode, type, sha: s }) => ({ name, mode, type, sha: s })) });
    }
    return sha;
  }

  putCommit({ tree, parents = [], message, author, committer }) {
    const a = author ?? this.store.signature(API_USER);
    const c = committer ?? a;
    const sig = (p) => `${p.name} <${p.email}> ${Math.floor(Date.parse(p.date) / 1000)} +0000`;
    const header = [`tree ${tree}`, ...parents.map((p) => `parent ${p}`), `author ${sig(a)}`, `committer ${sig(c)}`].join('\n');
    const body = Buffer.from(`${header}\n\n${message}`);
    const sha = gitHash('commit', body);
    if (!this.objects.has(sha)) this.objects.set(sha, { type: 'commit', tree, parents: [...parents], message, author: a, committer: c });
    return sha;
  }

  get(sha, type) {
    const o = typeof sha === 'string' ? this.objects.get(sha) : undefined;
    return o && (!type || o.type === type) ? o : null;
  }

  // Branch name, refs/heads/x, heads/x, full commit SHA or unique >=7 char prefix -> commit SHA.
  resolveCommit(ref) {
    if (!ref) return null;
    let name = ref;
    if (name.startsWith('refs/')) name = name.slice(5);
    if (this.refs.has(`heads/${name}`)) return this.refs.get(`heads/${name}`);
    if (name.startsWith('heads/') && this.refs.has(name)) return this.refs.get(name);
    if (/^[0-9a-f]{7,40}$/.test(ref)) {
      if (this.get(ref, 'commit')) return ref;
      const hits = [...this.objects.keys()].filter((k) => k.startsWith(ref) && this.objects.get(k).type === 'commit');
      if (hits.length === 1) return hits[0];
    }
    return null;
  }

  // Tree SHA, commit SHA (its tree) or ref -> tree SHA.
  resolveTree(ref) {
    if (this.get(ref, 'tree')) return ref;
    const c = this.resolveCommit(ref);
    return c ? this.get(c, 'commit').tree : null;
  }

  ancestors(sha) {
    const seen = new Set();
    const stack = [sha];
    while (stack.length) {
      const s = stack.pop();
      if (seen.has(s)) continue;
      seen.add(s);
      const c = this.get(s, 'commit');
      if (c) stack.push(...c.parents);
    }
    return seen;
  }

  isAncestor(anc, desc) { return this.ancestors(desc).has(anc); }

  // Pre-order listing like `git ls-tree -r -t`.
  flatten(treeSha, recursive = true, prefix = '') {
    const out = [];
    const tree = this.get(treeSha, 'tree');
    if (!tree) return out;
    for (const e of tree.entries) {
      const path = prefix ? `${prefix}/${e.name}` : e.name;
      const row = { path, mode: e.mode, type: e.type, sha: e.sha };
      if (e.type === 'blob') row.size = this.get(e.sha, 'blob')?.data.length ?? 0;
      out.push(row);
      if (recursive && e.type === 'tree') out.push(...this.flatten(e.sha, true, path));
    }
    return out;
  }

  files(treeSha) {
    const m = new Map();
    for (const e of this.flatten(treeSha)) if (e.type === 'blob') m.set(e.path, e);
    return m;
  }

  setRef(name, sha) { this.refs.set(`heads/${name}`, sha); }

  // Apply GitHub-style tree items ({path, mode, type, sha|null, content?}) to an optional base tree.
  buildTree(baseTreeSha, items) {
    const load = (sha) => {
      const node = new Map();
      for (const e of this.get(sha, 'tree')?.entries ?? []) node.set(e.name, { ...e, node: null });
      return node;
    };
    const root = baseTreeSha ? load(baseTreeSha) : new Map();
    items.forEach((item, i) => {
      const where = `tree.${i}`;
      if (!item || typeof item.path !== 'string' || !item.path) throw invalid(`${where}.path is missing`);
      const parts = item.path.split('/');
      if (item.path.startsWith('/') || parts.some((p) => p === '' || p === '.' || p === '..' || p === '.git')) {
        throw invalid(`${where}.path contains a malformed path component`);
      }
      const mode = String(item.mode ?? '');
      if (!VALID_MODES.has(mode)) throw invalid(`${where}.mode must be one of 100644, 100755, 040000, 160000, 120000`);
      const type = item.type ?? (mode === '040000' ? 'tree' : mode === '160000' ? 'commit' : 'blob');
      const expected = mode === '040000' ? 'tree' : mode === '160000' ? 'commit' : 'blob';
      if (type !== expected) throw invalid(`${where}.type '${type}' does not match mode ${mode}`);
      const remove = item.sha === null && item.content === undefined;
      let sha = item.sha;
      if (!remove) {
        if (item.content !== undefined) {
          if (type !== 'blob') throw invalid(`${where}.content is only valid for blobs`);
          sha = this.putBlob(Buffer.from(String(item.content), 'utf8'));
        } else if (!isHex40(sha)) {
          throw invalid(`${where}.sha must be a 40 character SHA or null`);
        } else if (type !== 'commit' && !this.get(sha, type)) {
          throw invalid('GitRPC::BadObjectState', [{ resource: 'Tree', field: `${where}.sha`, code: 'invalid' }]);
        }
      }
      let dir = root;
      for (let k = 0; k < parts.length - 1; k++) {
        let e = dir.get(parts[k]);
        if (!e) {
          if (remove) return; // deleting below a missing directory is a no-op
          e = { name: parts[k], mode: '040000', type: 'tree', sha: null, node: new Map() };
          dir.set(parts[k], e);
        } else if (e.type !== 'tree') {
          throw invalid(`${where}.path '${item.path}' passes through a non-directory`);
        }
        if (!e.node) e.node = load(e.sha);
        e.dirty = true;
        dir = e.node;
      }
      const leaf = parts[parts.length - 1];
      if (remove) dir.delete(leaf);
      else dir.set(leaf, { name: leaf, mode, type, sha, node: null });
    });
    const write = (node) => {
      const entries = [];
      for (const e of node.values()) {
        if (e.type === 'tree' && e.node) {
          const s = write(e.node);
          if (s === null) continue; // git has no empty directories
          entries.push({ name: e.name, mode: '040000', type: 'tree', sha: s });
        } else {
          entries.push({ name: e.name, mode: e.mode, type: e.type, sha: e.sha });
        }
      }
      return entries.length ? this.putTree(entries) : null;
    };
    return write(root) ?? this.putTree([]);
  }

  // Build a tree from {path: {content, mode}} (seeding / advance helpers).
  treeFromFiles(files, baseTree) {
    const items = Object.entries(files).map(([path, f]) => (f === null
      ? { path, mode: '100644', type: 'blob', sha: null }
      : { path, mode: f.mode ?? '100644', type: 'blob', sha: this.putBlob(Buffer.from(f.content ?? f, 'utf8')) }));
    return this.buildTree(baseTree, items);
  }
}

// ---------------------------------------------------------------- seed

function seed(store) {
  store.clock = SEED_EPOCH;
  store.repos = new Map();
  store.codeloads = new Map();

  const sample = store.addRepo({ owner: 'gangplank-demo', name: 'sample', visibility: 'private', description: 'Fictional sample project for Gangplank LocalDev' });
  const contributor = { login: 'demo-contributor', name: 'Demo Contributor', email: 'demo-contributor@example.test' };
  const t1 = sample.treeFromFiles({
    'README.md': '# Sample\n\nFictional demo repository for Gangplank local development.\nNothing here is real.\n',
    'src/app.ps1': "Write-Output 'Hello from the sample app'\n",
  });
  const c1 = sample.putCommit({ tree: t1, message: 'Initial commit', author: store.signature(contributor) });
  const t2 = sample.treeFromFiles({
    'scripts/build.sh': { content: '#!/bin/sh\nset -e\necho "building sample"\n', mode: '100755' },
    'docs/guide.md': '# Guide\n\n1. Download the workspace.\n2. Edit a file.\n3. Save to a work branch.\n',
  }, t1);
  const c2 = sample.putCommit({ tree: t2, parents: [c1], message: 'Add build script and guide', author: store.signature(contributor) });
  const t3 = sample.treeFromFiles({
    'docs/guide.md': '# Guide\n\n1. Download the workspace.\n2. Edit a file.\n3. Save to a work branch.\n4. Open a review.\n',
    'src/demo.ps1': "Write-Output 'Demo feature'\n",
  }, t2);
  const c3 = sample.putCommit({ tree: t3, parents: [c2], message: 'Demo: extend guide and add demo script', author: store.signature(contributor) });
  sample.setRef('main', c2);
  sample.setRef('feature/demo', c3);
  sample.setRef('release/2026.10', c1);
  for (let i = 1; i <= store.options.extraBranches; i++) sample.setRef(`bulk/branch-${String(i).padStart(4, '0')}`, c2);
  const demoPull = store.addPull(sample, { title: 'Demo feature', body: 'Extends the guide and adds a demo script.', head: 'feature/demo', base: 'main', user: contributor.login });
  // Conversation and checks on the seed review, so the Reviews tab has something to show. Fixed times:
  // seed commit SHAs must not depend on how many comments exist.
  store.addComment(sample, demoPull, TEAMMATE.login, 'Looks good to me. One question: should the demo script print the date as well?', iso(SEED_EPOCH + 45));
  sample.checks.set(c3, {
    runs: [{ name: 'build', status: 'completed', conclusion: 'success' }, { name: 'unit-tests', status: 'completed', conclusion: 'success' }],
    statuses: [{ context: 'ci/lint', state: 'success' }],
  });
  const closed = store.addPull(sample, { title: 'Old release notes', body: '', head: 'release/2026.10', base: 'main', user: contributor.login });
  closed.state = 'closed';

  const site = store.addRepo({ owner: 'gangplank-demo', name: 'public-site', visibility: 'public', description: 'Fictional public repository' });
  const ts = site.treeFromFiles({ 'index.html': '<!doctype html><title>Public demo</title>\n' });
  site.setRef('main', site.putCommit({ tree: ts, message: 'Initial public page', author: store.signature(contributor) }));

  store.addRepo({ owner: 'gangplank-demo', name: 'empty', visibility: 'private', description: 'Fictional empty repository' });
}

// ---------------------------------------------------------------- JSON shapes

function shapes(store, repo) {
  const base = store.url;
  const api = `${base}/repos/${repo.fullName}`;
  const web = `${base}/${repo.fullName}`;
  const person = (p) => ({ name: p.name, email: p.email, date: p.date });
  const gitCommit = (sha) => {
    const c = repo.get(sha, 'commit');
    return {
      sha, node_id: `C_${sha.slice(0, 12)}`, url: `${api}/git/commits/${sha}`, html_url: `${web}/commit/${sha}`,
      author: person(c.author), committer: person(c.committer), message: c.message,
      tree: { sha: c.tree, url: `${api}/git/trees/${c.tree}` },
      parents: c.parents.map((p) => ({ sha: p, url: `${api}/git/commits/${p}`, html_url: `${web}/commit/${p}` })),
      verification: { verified: false, reason: 'unsigned', signature: null, payload: null },
    };
  };
  const commit = (sha) => {
    const c = repo.get(sha, 'commit');
    return {
      sha, node_id: `C_${sha.slice(0, 12)}`, url: `${api}/commits/${sha}`, html_url: `${web}/commit/${sha}`,
      commit: { author: person(c.author), committer: person(c.committer), message: c.message, tree: { sha: c.tree, url: `${api}/git/trees/${c.tree}` }, comment_count: 0 },
      author: { login: c.author.login ?? null }, committer: { login: c.committer.login ?? null },
      parents: c.parents.map((p) => ({ sha: p, url: `${api}/commits/${p}`, html_url: `${web}/commit/${p}` })),
    };
  };
  const ref = (name) => {
    const sha = repo.refs.get(name);
    return { ref: `refs/${name}`, node_id: `REF_${Buffer.from(name).toString('base64url')}`, url: `${api}/git/refs/${name}`, object: { sha, type: 'commit', url: `${api}/git/commits/${sha}` } };
  };
  // `detail` adds what only the single-pull endpoint returns (like GitHub, the list omits mergeability).
  const pull = (pr, detail = false) => {
    const side = (name) => ({ label: `${repo.owner}:${name}`, ref: name, sha: repo.refs.get(`heads/${name}`) ?? null, repo: { full_name: repo.fullName } });
    const out = {
      id: 500000 + pr.number, number: pr.number, state: pr.state, title: pr.title, body: pr.body, draft: pr.draft,
      url: `${api}/pulls/${pr.number}`, html_url: `${web}/pull/${pr.number}`, user: { login: pr.user },
      head: side(pr.head), base: side(pr.base), created_at: pr.created_at, updated_at: pr.updated_at,
      closed_at: pr.state === 'closed' ? pr.updated_at : null, merged_at: pr.merged_at, merge_commit_sha: pr.merge_commit_sha,
    };
    if (detail) {
      const ms = pullMergeState(repo, pr);
      Object.assign(out, { merged: pr.merged, mergeable: ms.mergeable, mergeable_state: ms.state, comments: pr.comments.length });
    }
    return out;
  };
  const comment = (c) => ({
    id: c.id, node_id: `IC_${c.id}`, url: `${api}/issues/comments/${c.id}`, html_url: `${web}/pull/${c.pull}#issuecomment-${c.id}`,
    body: c.body, user: { login: c.user }, created_at: c.created_at, updated_at: c.created_at, author_association: 'MEMBER',
  });
  const run = (sha, r, i) => ({
    id: 700000 + i, name: r.name, head_sha: sha, status: r.status ?? 'completed', conclusion: r.status && r.status !== 'completed' ? null : (r.conclusion ?? 'success'),
    html_url: `${web}/runs/${700000 + i}`, started_at: r.started_at ?? null, completed_at: r.completed_at ?? null, app: { slug: 'fake-ci' },
  });
  const status = (r, i) => ({ id: 800000 + i, state: r.state, context: r.context, description: r.description ?? null, target_url: r.target_url ?? null, created_at: r.created_at ?? null });
  const repoJson = () => ({
    id: Number.parseInt(sha1(repo.fullName).slice(0, 8), 16), node_id: `R_${repo.name}`, name: repo.name, full_name: repo.fullName,
    owner: { login: repo.owner, type: 'Organization' }, private: repo.visibility !== 'public', visibility: repo.visibility,
    description: repo.description, html_url: web, url: api, default_branch: repo.defaultBranch, size: repo.objects.size,
    permissions: { admin: false, maintain: false, push: true, triage: true, pull: true }, archived: false, disabled: false, fork: false,
  });
  return { gitCommit, commit, ref, pull, comment, run, status, repoJson, api, web };
}

function paginate(urlObj, items, defaultPer = 30) {
  const per = Math.min(100, Math.max(1, Number.parseInt(urlObj.searchParams.get('per_page') ?? '', 10) || defaultPer));
  const page = Math.max(1, Number.parseInt(urlObj.searchParams.get('page') ?? '', 10) || 1);
  const last = Math.max(1, Math.ceil(items.length / per));
  const link = (p) => { const u = new URL(urlObj); u.searchParams.set('per_page', String(per)); u.searchParams.set('page', String(p)); return u.toString(); };
  const rels = [];
  if (page < last) rels.push(`<${link(page + 1)}>; rel="next"`, `<${link(last)}>; rel="last"`);
  if (page > 1) rels.push(`<${link(1)}>; rel="first"`, `<${link(Math.min(page - 1, last))}>; rel="prev"`);
  return { items: items.slice((page - 1) * per, page * per), headers: rels.length ? { Link: rels.join(', ') } : {} };
}

// ---------------------------------------------------------------- zip

function dosDateTime(secs) {
  const d = new Date(secs * 1000);
  const time = (d.getUTCHours() << 11) | (d.getUTCMinutes() << 5) | Math.floor(d.getUTCSeconds() / 2);
  const date = ((d.getUTCFullYear() - 1980) << 9) | ((d.getUTCMonth() + 1) << 5) | d.getUTCDate();
  return { time, date };
}

export function buildZip(entries, { secs = SEED_EPOCH, comment = '' } = {}) {
  // entries: [{name, data?: Buffer, dir?: bool, mode?: '100644'|'100755'|'120000'}]
  const { time, date } = dosDateTime(secs);
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const e of entries) {
    const name = Buffer.from(e.name, 'utf8');
    const raw = e.dir ? Buffer.alloc(0) : e.data;
    const crc = crc32(raw);
    let method = 0;
    let data = raw;
    if (raw.length) {
      const deflated = deflateRawSync(raw);
      if (deflated.length < raw.length) { method = 8; data = deflated; }
    }
    const unixMode = e.dir ? 0o40755 : e.mode === '100755' ? 0o100755 : e.mode === '120000' ? 0o120777 : 0o100644;
    const external = ((unixMode << 16) | (e.dir ? 0x10 : 0)) >>> 0;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6); // UTF-8 names
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(time, 10);
    local.writeUInt16LE(date, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    locals.push(local, name, data);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE((3 << 8) | 20, 4); // made by Unix
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(time, 12);
    central.writeUInt16LE(date, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(raw.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    central.writeUInt32LE(external, 38);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, name);
    offset += local.length + name.length + data.length;
  }
  const cd = Buffer.concat(centrals);
  const commentBuf = Buffer.from(comment, 'utf8');
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(commentBuf.length, 20);
  return Buffer.concat([...locals, cd, end, commentBuf]);
}

function repoZip(repo, commitSha) {
  const c = repo.get(commitSha, 'commit');
  const top = `${repo.owner}-${repo.name}-${commitSha.slice(0, 7)}`;
  const entries = [{ name: `${top}/`, dir: true }];
  for (const e of repo.flatten(c.tree)) {
    if (e.type === 'tree') entries.push({ name: `${top}/${e.path}/`, dir: true });
    else if (e.type === 'blob') entries.push({ name: `${top}/${e.path}`, data: repo.get(e.sha, 'blob').data, mode: e.mode });
    // submodules (commit entries) are omitted, as GitHub does
  }
  return { top, zip: buildZip(entries, { secs: Math.floor(Date.parse(c.committer.date) / 1000), comment: commitSha }) };
}

// ---------------------------------------------------------------- store

class Store {
  constructor(options) {
    this.options = options;
    this.token = options.token;
    this.url = '';
    this.calls = [];
    this.faults = [];
    this.seq = 0;
    seed(this);
  }
  reset() {
    this.calls = [];
    this.faults = [];
    this.seq = 0;
    seed(this);
  }
  tick() { this.clock += 60; return iso(this.clock); }
  signature(p) { return { name: p.name, email: p.email, login: p.login, date: this.tick() }; }
  addRepo(opts) {
    const repo = new Repo(this, opts);
    this.repos.set(repo.fullName.toLowerCase(), repo);
    return repo;
  }
  addPull(repo, { title, body, head, base, user }) {
    const at = this.tick();
    const pr = {
      number: repo.nextNumber++, state: 'open', title, body: body ?? '', head, base, user, created_at: at, updated_at: at,
      draft: false, blocked: false, merged: false, merged_at: null, merge_commit_sha: null, comments: [],
    };
    repo.pulls.push(pr);
    return pr;
  }
  addComment(repo, pr, user, body, at) {
    const c = { id: repo.nextCommentId++, pull: pr.number, user, body: String(body), created_at: at ?? this.tick() };
    pr.comments.push(c);
    return c;
  }
  // Control: replace the checks reported for a commit (by sha, or the tip of a branch).
  setChecks({ repo: name = 'gangplank-demo/sample', sha, branch, runs = [], statuses = [] } = {}) {
    const repo = this.repo(name);
    if (!repo) throw notFound();
    const target = sha ? repo.resolveCommit(sha) : repo.resolveCommit(branch ?? repo.defaultBranch);
    if (!target) throw new HttpError(404, 'Commit not found');
    const entry = { runs: runs.map((r) => ({ ...r })), statuses: statuses.map((s) => ({ ...s })) };
    repo.checks.set(target, entry);
    return { repo: repo.fullName, sha: target, ...entry };
  }
  // Control: mark a review as a draft, or as blocked by a branch rule (e.g. a required approval).
  setPull({ repo: name = 'gangplank-demo/sample', number, draft, blocked } = {}) {
    const repo = this.repo(name);
    const pr = repo?.pulls.find((p) => p.number === Number(number));
    if (!pr) throw notFound();
    if (draft !== undefined) pr.draft = Boolean(draft);
    if (blocked !== undefined) pr.blocked = Boolean(blocked);
    return { repo: repo.fullName, number: pr.number, draft: pr.draft, blocked: pr.blocked };
  }
  repo(fullName) { return this.repos.get(String(fullName).toLowerCase()) ?? null; }

  advance({ repo: name = 'gangplank-demo/sample', branch, path = 'TEAMMATE.md', content, message, mode } = {}) {
    const repo = this.repo(name);
    if (!repo) throw notFound();
    const b = branch ?? repo.defaultBranch;
    const parent = repo.refs.get(`heads/${b}`);
    if (!parent) throw new HttpError(404, `Branch ${b} not found`);
    const baseTree = repo.get(parent, 'commit').tree;
    const existing = repo.files(baseTree).get(path);
    const n = repo.ancestors(parent).size + 1;
    const next = content ?? `${existing ? repo.get(existing.sha, 'blob').data.toString('utf8') : '# Teammate notes\n'}Outside change ${n} by ${TEAMMATE.name}\n`;
    const tree = repo.treeFromFiles({ [path]: { content: next, mode: mode ?? existing?.mode ?? '100644' } }, baseTree);
    const sha = repo.putCommit({ tree, parents: [parent], message: message ?? `Teammate update ${n}`, author: this.signature(TEAMMATE) });
    repo.setRef(b, sha);
    return { repo: repo.fullName, branch: b, sha, parent, path };
  }

  addFault(rule) {
    const f = {
      id: ++this.seq, method: rule.method ? String(rule.method).toUpperCase() : null, pathContains: rule.pathContains ?? null,
      status: Number(rule.status ?? 500), times: Number(rule.times ?? 1), retryAfter: rule.retryAfter ?? null,
      body: rule.body ?? null, headers: rule.headers ?? {}, delayMs: Number(rule.delayMs ?? 0), dropConnection: Boolean(rule.dropConnection),
    };
    if (!(f.times > 0)) throw new HttpError(400, 'times must be > 0');
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

  snapshot() {
    const repos = {};
    for (const r of this.repos.values()) {
      repos[r.fullName] = {
        default_branch: r.defaultBranch, visibility: r.visibility,
        branches: Object.fromEntries([...r.refs].filter(([k]) => k.startsWith('heads/')).map(([k, v]) => [k.slice(6), v])),
        pulls: r.pulls.map((p) => ({ number: p.number, state: p.state, title: p.title, head: p.head, base: p.base, draft: p.draft, merged: p.merged, merge_commit_sha: p.merge_commit_sha, comments: p.comments.map((c) => ({ id: c.id, user: c.user, body: c.body })) })),
      };
    }
    const codeload = this.calls.filter((c) => c.kind === 'codeload');
    return {
      url: this.url, token: this.token, calls: this.calls, faults: this.faults, repos,
      codeload: { calls: codeload.length, authorizationSent: codeload.some((c) => c.authorizationSent) },
    };
  }
}

// ---------------------------------------------------------------- HTTP

function readBody(req, limit = 64 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new HttpError(413, 'Request entity too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function parseJson(buf, call) {
  if (!buf.length) return {};
  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    call.invalidUtf8Body = true; // e.g. a Windows PowerShell 5.1 string body sent as ISO-8859-1
    throw new HttpError(400, 'Problems parsing JSON');
  }
  try {
    const v = JSON.parse(text);
    if (v === null || typeof v !== 'object' || Array.isArray(v)) throw new Error('not an object');
    return v;
  } catch {
    throw new HttpError(400, 'Problems parsing JSON');
  }
}

const defaultMessages = {
  400: 'Bad Request', 401: 'Bad credentials', 403: 'Forbidden', 404: 'Not Found', 409: 'Conflict', 422: 'Validation Failed',
  429: 'API rate limit exceeded for fake-gangplank-user.', 500: 'Server Error', 502: 'Server Error', 503: 'Service Unavailable',
};

function sendJson(res, status, payload, headers = {}) {
  const body = payload === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(payload));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length,
    'X-GitHub-Media-Type': 'github.v3; format=json', 'X-GitHub-Request-Id': randomBytes(6).toString('hex').toUpperCase(),
    'X-RateLimit-Limit': '5000', 'X-RateLimit-Remaining': '4999', 'X-RateLimit-Resource': 'core', ...headers,
  });
  res.end(body);
}

function sendError(res, err) {
  const payload = { message: err.message, documentation_url: 'https://docs.github.com/rest', status: String(err.status), ...err.extra };
  sendJson(res, err.status, payload, err.headers ?? {});
}

function decodeTail(raw) {
  try {
    return raw.split('/').map(decodeURIComponent).join('/');
  } catch {
    throw notFound();
  }
}

function isAuthWhitespace(ch) {
  if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f' || ch === '\v') return true;
  const c = ch.charCodeAt(0);
  return c === 0x00a0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a) || c === 0x2028 || c === 0x2029
    || c === 0x202f || c === 0x205f || c === 0x3000 || c === 0xfeff;
}
function isAuthLineTerminator(ch) {
  return ch === '\n' || ch === '\r' || ch === '\u2028' || ch === '\u2029';
}

// Authorization: <scheme> <credential>, in one forward pass. `\s+` and `.+` both match
// spaces, so a regexp is polynomial in a long run of spaces after the scheme.
export function authHeaderCredential(header, schemes) {
  if (typeof header !== 'string') return null;
  const lower = header.toLowerCase();
  let schemeLen = -1;
  for (const scheme of schemes) {
    if (lower.startsWith(scheme)) { schemeLen = scheme.length; break; }
  }
  if (schemeLen < 0) return null;
  const rest = header.slice(schemeLen);
  if (rest.length < 2 || !isAuthWhitespace(rest[0])) return null;
  let i = 0;
  while (i < rest.length && isAuthWhitespace(rest[i])) i++;
  if (i < rest.length) {
    for (let k = i; k < rest.length; k++) if (isAuthLineTerminator(rest[k])) return null;
    return rest.slice(i).trim();
  }
  if (isAuthLineTerminator(rest[rest.length - 1])) return null;
  for (let k = 0; k < rest.length; k++) if (!isAuthLineTerminator(rest[k])) return '';
  return null;
}

function authState(req, token) {
  const h = req.headers.authorization;
  if (!h) return 'none';
  const presented = authHeaderCredential(h, ['bearer', 'token']);
  return presented !== null && presented === token ? 'valid' : 'invalid';
}

async function handleControl(store, req, res, path, body) {
  if (req.method === 'POST' && path === '/__fake/reset') { store.reset(); return sendJson(res, 200, { ok: true, state: store.snapshot() }); }
  if (req.method === 'GET' && path === '/__fake/state') return sendJson(res, 200, store.snapshot());
  if (req.method === 'DELETE' && path === '/__fake/calls') { store.calls = []; return sendJson(res, 200, { ok: true }); }
  if (req.method === 'POST' && path === '/__fake/fail') return sendJson(res, 201, store.addFault(body));
  if (req.method === 'POST' && path === '/__fake/advance') return sendJson(res, 201, store.advance(body));
  if (req.method === 'POST' && path === '/__fake/checks') return sendJson(res, 201, store.setChecks(body));
  if (req.method === 'POST' && path === '/__fake/pull') return sendJson(res, 201, store.setPull(body));
  throw notFound();
}

function handleCodeload(store, req, res, path, call) {
  call.kind = 'codeload';
  call.authorizationSent = Boolean(req.headers.authorization);
  const m = /^\/_codeload\/([A-Za-z0-9_-]+)\.zip$/.exec(path);
  const entry = m && store.codeloads.get(m[1]);
  if (req.method !== 'GET' || !entry) throw notFound();
  const repo = store.repo(entry.repo);
  const { top, zip } = repoZip(repo, entry.sha);
  res.writeHead(200, {
    'Content-Type': 'application/zip', 'Content-Length': zip.length,
    'Content-Disposition': `attachment; filename=${top}.zip`, ETag: `"${entry.sha}"`,
  });
  res.end(zip);
}

function handleRepo(store, req, res, urlObj, repo, rest, body) {
  const method = req.method;
  const S = shapes(store, repo);
  const q = urlObj.searchParams;
  let m;

  if (rest === '' || rest === '/') {
    if (method === 'GET') return sendJson(res, 200, S.repoJson());
    throw notFound();
  }

  // ---- branches
  if (rest === '/branches' && method === 'GET') {
    const names = [...repo.refs.keys()].filter((k) => k.startsWith('heads/')).map((k) => k.slice(6)).sort();
    const rows = names.map((name) => ({ name, commit: { sha: repo.refs.get(`heads/${name}`), url: `${S.api}/commits/${repo.refs.get(`heads/${name}`)}` }, protected: false }));
    const { items, headers } = paginate(urlObj, rows);
    return sendJson(res, 200, items, headers);
  }
  if ((m = /^\/branches\/(.+)$/.exec(rest)) && method === 'GET') {
    const name = decodeTail(m[1]);
    const sha = repo.refs.get(`heads/${name}`);
    if (!sha) throw new HttpError(404, 'Branch not found');
    return sendJson(res, 200, { name, commit: S.commit(sha), protected: false, _links: { self: `${S.api}/branches/${encodeURIComponent(name)}`, html: `${S.web}/tree/${name}` } });
  }

  // ---- refs
  if ((m = /^\/git\/ref\/(.+)$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw new HttpError(store.options.emptyRefStatus, store.options.emptyRefStatus === 404 ? 'Not Found' : 'Git Repository is empty.');
    const name = decodeTail(m[1]);
    if (!repo.refs.has(name)) throw notFound();
    return sendJson(res, 200, S.ref(name));
  }
  if ((m = /^\/git\/(?:refs|matching-refs)(?:\/(.*))?$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw emptyRepo();
    const name = decodeTail(m[1] ?? '').replace(/\/$/, '');
    const matching = rest.startsWith('/git/matching-refs');
    if (!matching && name && repo.refs.has(name)) return sendJson(res, 200, S.ref(name));
    const hits = [...repo.refs.keys()].filter((k) => !name || k.startsWith(matching ? name : `${name}/`) || k === name).sort().map((k) => S.ref(k));
    if (!hits.length && !matching) throw notFound();
    return sendJson(res, 200, hits);
  }
  if (rest === '/git/refs' && method === 'POST') {
    if (typeof body.ref !== 'string' || !body.ref.startsWith('refs/') || body.ref.split('/').length < 3) throw invalid('Reference name must start with \'refs/\' and have at least two slashes.');
    if (!isHex40(body.sha) || !repo.get(body.sha, 'commit')) throw invalid('Object does not exist');
    const name = body.ref.slice(5);
    if (/(\.\.|\/\/|@\{|\/\.|\.lock(\/|$)|\/$|[\s~^:?*[\\])/.test(name)) throw invalid(`${body.ref} is not a valid ref name.`);
    if (repo.refs.has(name)) throw invalid('Reference already exists');
    repo.refs.set(name, body.sha);
    return sendJson(res, 201, S.ref(name), { Location: `${S.api}/git/refs/${name}` });
  }
  if ((m = /^\/git\/refs\/(.+)$/.exec(rest)) && (method === 'PATCH' || method === 'POST')) {
    const name = decodeTail(m[1]);
    const current = repo.refs.get(name);
    if (!current) throw invalid('Reference does not exist');
    if (!isHex40(body.sha) || !repo.get(body.sha, 'commit')) throw invalid('Object does not exist');
    const force = body.force === true;
    if (!force && body.sha !== current && !repo.isAncestor(current, body.sha)) throw invalid('Update is not a fast forward');
    repo.refs.set(name, body.sha);
    return sendJson(res, 200, S.ref(name));
  }
  if ((m = /^\/git\/refs\/(.+)$/.exec(rest)) && method === 'DELETE') {
    const name = decodeTail(m[1]);
    if (!repo.refs.delete(name)) throw invalid('Reference does not exist');
    res.writeHead(204);
    return res.end();
  }

  // ---- git objects
  if ((m = /^\/git\/commits\/([0-9a-fA-F]+)$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw emptyRepo();
    const sha = m[1].toLowerCase();
    if (!repo.get(sha, 'commit')) throw notFound();
    return sendJson(res, 200, S.gitCommit(sha));
  }
  if (rest === '/git/commits' && method === 'POST') {
    if (typeof body.message !== 'string') throw invalid('Invalid request.\n\n"message" wasn\'t supplied.');
    if (!isHex40(body.tree) || !repo.get(body.tree, 'tree')) throw invalid('Tree SHA does not exist');
    const parents = body.parents ?? [];
    if (!Array.isArray(parents)) throw invalid('Invalid request.\n\nFor \'properties/parents\', is not an array.');
    for (const p of parents) if (!isHex40(p) || !repo.get(p, 'commit')) throw invalid('Parent SHA does not exist or is not a commit object');
    const who = (p, fallback) => (p && p.name && p.email ? { name: p.name, email: p.email, date: p.date ?? store.tick() } : fallback);
    const author = who(body.author, store.signature(API_USER));
    const sha = repo.putCommit({ tree: body.tree, parents, message: body.message, author, committer: who(body.committer, author) });
    return sendJson(res, 201, S.gitCommit(sha), { Location: `${S.api}/git/commits/${sha}` });
  }
  if ((m = /^\/git\/trees\/(.+)$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw emptyRepo();
    const treeSha = repo.resolveTree(decodeTail(m[1]));
    if (!treeSha) throw notFound();
    // GitHub: any value for `recursive` (even 0 or false) enables recursion.
    const recursive = q.has('recursive');
    const tree = repo.flatten(treeSha, recursive).map((e) => ({ ...e, url: `${S.api}/git/${e.type === 'tree' ? 'trees' : 'blobs'}/${e.sha}` }));
    return sendJson(res, 200, { sha: treeSha, url: `${S.api}/git/trees/${treeSha}`, tree, truncated: false });
  }
  if (rest === '/git/trees' && method === 'POST') {
    if (repo.isEmpty) throw emptyRepo();
    if (!Array.isArray(body.tree)) throw invalid('Invalid tree info', [{ resource: 'Tree', field: 'tree', code: 'missing_field' }]);
    if (body.base_tree !== undefined && body.base_tree !== null && !repo.get(body.base_tree, 'tree')) throw invalid('base_tree is not a valid tree oid');
    const sha = repo.buildTree(body.base_tree ?? null, body.tree);
    const tree = repo.flatten(sha, false).map((e) => ({ ...e, url: `${S.api}/git/${e.type === 'tree' ? 'trees' : 'blobs'}/${e.sha}` }));
    return sendJson(res, 201, { sha, url: `${S.api}/git/trees/${sha}`, tree, truncated: false }, { Location: `${S.api}/git/trees/${sha}` });
  }
  if ((m = /^\/git\/blobs\/([0-9a-fA-F]{40})$/.exec(rest)) && method === 'GET') {
    const sha = m[1].toLowerCase();
    const blob = repo.get(sha, 'blob');
    if (!blob) throw notFound();
    return sendJson(res, 200, { sha, node_id: `B_${sha.slice(0, 12)}`, size: blob.data.length, url: `${S.api}/git/blobs/${sha}`, content: `${blob.data.toString('base64').replace(/(.{60})/g, '$1\n')}\n`, encoding: 'base64' });
  }
  if (rest === '/git/blobs' && method === 'POST') {
    if (repo.isEmpty) throw emptyRepo();
    if (typeof body.content !== 'string') throw invalid('Invalid request.\n\n"content" wasn\'t supplied.');
    const encoding = body.encoding ?? 'utf-8';
    if (encoding !== 'base64' && encoding !== 'utf-8' && encoding !== 'utf8') throw invalid(`encoding must be utf-8 or base64, got ${encoding}`);
    if (encoding === 'base64' && !/^[A-Za-z0-9+/=\s]*$/.test(body.content)) throw invalid('Invalid base64 content');
    const sha = repo.putBlob(encoding === 'base64' ? Buffer.from(body.content, 'base64') : Buffer.from(body.content, 'utf8'));
    return sendJson(res, 201, { sha, url: `${S.api}/git/blobs/${sha}` }, { Location: `${S.api}/git/blobs/${sha}` });
  }

  // ---- history
  if (rest === '/commits' && method === 'GET') {
    if (repo.isEmpty) throw emptyRepo();
    const start = repo.resolveCommit(q.get('sha') || repo.defaultBranch);
    if (!start) throw notFound();
    const path = q.get('path');
    let list = [...repo.ancestors(start)].sort((a, b) => Date.parse(repo.get(b, 'commit').committer.date) - Date.parse(repo.get(a, 'commit').committer.date));
    if (path) {
      const blobAt = (sha) => repo.files(repo.get(sha, 'commit').tree).get(path)?.sha ?? null;
      list = list.filter((sha) => { const c = repo.get(sha, 'commit'); const mine = blobAt(sha); return c.parents.length ? c.parents.every((p) => blobAt(p) !== mine) : mine !== null; });
    }
    const { items, headers } = paginate(urlObj, list);
    return sendJson(res, 200, items.map(S.commit), headers);
  }
  if ((m = /^\/commits\/(.+)\/(check-runs|status)$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw emptyRepo();
    const ref = decodeTail(m[1]);
    const sha = repo.resolveCommit(ref);
    if (!sha) throw invalid(`No commit found for SHA: ${ref}`);
    const entry = repo.checks.get(sha) ?? { runs: [], statuses: [] };
    if (m[2] === 'check-runs') {
      const rows = entry.runs.map((r, i) => S.run(sha, r, i));
      const { items, headers } = paginate(urlObj, rows);
      return sendJson(res, 200, { total_count: rows.length, check_runs: items }, headers);
    }
    const statuses = entry.statuses.map((s, i) => S.status(s, i));
    // GitHub's combined state: failure beats pending beats success; no statuses at all reads as pending.
    const state = statuses.some((s) => s.state === 'failure' || s.state === 'error') ? 'failure' : (!statuses.length || statuses.some((s) => s.state === 'pending')) ? 'pending' : 'success';
    return sendJson(res, 200, { state, sha, total_count: statuses.length, statuses, repository: { full_name: repo.fullName } });
  }
  if ((m = /^\/commits\/(.+)$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw emptyRepo();
    const sha = repo.resolveCommit(decodeTail(m[1]));
    if (!sha) throw invalid(`No commit found for SHA: ${decodeTail(m[1])}`);
    const c = repo.get(sha, 'commit');
    const files = diffFiles(repo, c.parents[0] ? repo.get(c.parents[0], 'commit').tree : null, c.tree);
    return sendJson(res, 200, { ...S.commit(sha), files, stats: files.reduce((s, f) => ({ additions: s.additions + f.additions, deletions: s.deletions + f.deletions, total: s.total + f.changes }), { additions: 0, deletions: 0, total: 0 }) });
  }
  if ((m = /^\/compare\/(.+)$/.exec(rest)) && method === 'GET') {
    const spec = decodeTail(m[1]);
    const idx = spec.indexOf('...');
    if (idx < 0) throw notFound();
    const baseSha = repo.resolveCommit(spec.slice(0, idx));
    const headSha = repo.resolveCommit(spec.slice(idx + 3));
    if (!baseSha || !headSha) throw notFound();
    const baseAnc = repo.ancestors(baseSha);
    const headAnc = repo.ancestors(headSha);
    const date = (s) => Date.parse(repo.get(s, 'commit').committer.date);
    const common = [...headAnc].filter((s) => baseAnc.has(s)).sort((a, b) => date(b) - date(a));
    const mergeBase = common[0] ?? null;
    const ahead = [...headAnc].filter((s) => !baseAnc.has(s)).sort((a, b) => date(a) - date(b));
    const behind = [...baseAnc].filter((s) => !headAnc.has(s));
    const status = ahead.length && behind.length ? 'diverged' : ahead.length ? 'ahead' : behind.length ? 'behind' : 'identical';
    const files = diffFiles(repo, mergeBase ? repo.get(mergeBase, 'commit').tree : null, repo.get(headSha, 'commit').tree);
    return sendJson(res, 200, {
      url: `${S.api}/compare/${spec}`, html_url: `${S.web}/compare/${spec}`, status, ahead_by: ahead.length, behind_by: behind.length,
      total_commits: ahead.length, base_commit: S.commit(baseSha), merge_base_commit: mergeBase ? S.commit(mergeBase) : null,
      commits: ahead.slice(0, 250).map(S.commit), files: files.slice(0, 300),
    });
  }

  // ---- pulls
  if (rest === '/pulls' && method === 'GET') {
    const state = q.get('state') ?? 'open';
    const rows = repo.pulls.filter((p) => state === 'all' || p.state === state)
      .filter((p) => !q.get('head') || `${repo.owner}:${p.head}` === q.get('head'))
      .filter((p) => !q.get('base') || p.base === q.get('base'))
      .sort((a, b) => b.number - a.number);
    const { items, headers } = paginate(urlObj, rows);
    return sendJson(res, 200, items.map((p) => S.pull(p)), headers);
  }
  if ((m = /^\/pulls\/(\d+)$/.exec(rest)) && method === 'GET') {
    const pr = repo.pulls.find((p) => p.number === Number(m[1]));
    if (!pr) throw notFound();
    return sendJson(res, 200, S.pull(pr, true));
  }
  if ((m = /^\/pulls\/(\d+)\/files$/.exec(rest)) && method === 'GET') {
    const pr = repo.pulls.find((p) => p.number === Number(m[1]));
    if (!pr) throw notFound();
    const headSha = repo.refs.get(`heads/${pr.head}`);
    const baseSha = repo.refs.get(`heads/${pr.base}`);
    if (!headSha || !baseSha) throw notFound();
    const mb = mergeBaseOf(repo, baseSha, headSha);
    const files = diffFiles(repo, mb ? repo.get(mb, 'commit').tree : null, repo.get(headSha, 'commit').tree)
      .map((f) => ({ ...f, blob_url: `${S.web}/blob/${headSha}/${f.filename}`, raw_url: `${S.web}/raw/${headSha}/${f.filename}` }));
    const { items, headers } = paginate(urlObj, files);
    return sendJson(res, 200, items, headers);
  }
  if ((m = /^\/pulls\/(\d+)\/merge$/.exec(rest)) && method === 'PUT') {
    const pr = repo.pulls.find((p) => p.number === Number(m[1]));
    if (!pr) throw notFound();
    const mergeMethod = body.merge_method ?? 'merge';
    if (!['merge', 'squash', 'rebase'].includes(mergeMethod)) throw invalid('Validation Failed', [{ resource: 'PullRequest', field: 'merge_method', code: 'invalid' }]);
    if (body.sha !== undefined && typeof body.sha !== 'string') throw invalid('Invalid request.\n\nFor \'properties/sha\', nil is not a string.');
    const headSha = repo.refs.get(`heads/${pr.head}`);
    // The guard: the caller merges the version it looked at, or nothing.
    if (body.sha !== undefined && body.sha !== headSha) throw new HttpError(409, 'Head branch was modified. Review and try the merge again.');
    if (pr.state !== 'open') throw new HttpError(405, 'Pull Request is not mergeable');
    if (mergeMethod !== 'merge') throw new HttpError(405, `${mergeMethod === 'squash' ? 'Squash merges' : 'Rebase merges'} are not allowed on this repository.`);
    const ms = pullMergeState(repo, pr);
    if (ms.state === 'draft') throw new HttpError(405, 'Draft pull requests are not mergeable');
    if (ms.state === 'dirty') throw new HttpError(405, 'Pull Request is not mergeable');
    if (ms.state === 'blocked') throw new HttpError(405, 'At least 1 approving review is required by reviewers with write access.');
    const sha = mergePull(store, repo, pr, body);
    return sendJson(res, 200, { sha, merged: true, message: 'Pull Request successfully merged' });
  }
  if ((m = /^\/issues\/(\d+)\/comments$/.exec(rest)) && (method === 'GET' || method === 'POST')) {
    const pr = repo.pulls.find((p) => p.number === Number(m[1]));
    if (!pr) throw notFound();
    if (method === 'GET') {
      const { items, headers } = paginate(urlObj, pr.comments);
      return sendJson(res, 200, items.map((c) => S.comment(c)), headers);
    }
    if (typeof body.body !== 'string' || !body.body.trim()) throw invalid('Validation Failed', [{ resource: 'IssueComment', code: 'missing_field', field: 'body' }]);
    const made = store.addComment(repo, pr, API_USER.login, body.body);
    pr.updated_at = made.created_at;
    return sendJson(res, 201, S.comment(made), { Location: `${S.api}/issues/comments/${made.id}` });
  }
  if (rest === '/pulls' && method === 'POST') {
    const head = String(body.head ?? '').replace(new RegExp(`^${repo.owner}:`, 'i'), '');
    const base = String(body.base ?? '');
    const field = (f, code = 'invalid') => invalid('Validation Failed', [{ resource: 'PullRequest', field: f, code }]);
    if (!body.title && !body.issue) throw field('title', 'missing_field');
    if (!head) throw field('head', 'missing_field');
    if (!base) throw field('base', 'missing_field');
    const headSha = repo.refs.get(`heads/${head}`);
    const baseSha = repo.refs.get(`heads/${base}`);
    if (!headSha) throw field('head');
    if (!baseSha) throw field('base');
    if (head === base || repo.isAncestor(headSha, baseSha)) throw invalid('Validation Failed', [{ resource: 'PullRequest', code: 'custom', message: `No commits between ${base} and ${head}` }]);
    if (repo.pulls.some((p) => p.state === 'open' && p.head === head && p.base === base)) {
      throw invalid('Validation Failed', [{ resource: 'PullRequest', code: 'custom', message: `A pull request already exists for ${repo.owner}:${head}.` }]);
    }
    const pr = store.addPull(repo, { title: String(body.title), body: body.body ?? '', head, base, user: API_USER.login });
    return sendJson(res, 201, S.pull(pr), { Location: `${S.api}/pulls/${pr.number}` });
  }

  // ---- contents
  if ((m = /^\/contents\/(.+)$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw new HttpError(404, 'This repository is empty.');
    const path = decodeTail(m[1]).replace(/\/$/, '');
    const sha = repo.resolveCommit(q.get('ref') || repo.defaultBranch);
    if (!sha) throw new HttpError(404, `No commit found for the ref ${q.get('ref')}`);
    const all = repo.flatten(repo.get(sha, 'commit').tree);
    const entry = all.find((e) => e.path === path);
    if (!entry) throw notFound();
    const item = (e) => ({ type: e.type === 'tree' ? 'dir' : 'file', name: e.path.split('/').pop(), path: e.path, sha: e.sha, size: e.size ?? 0, url: `${S.api}/contents/${e.path}` });
    if (entry.type === 'tree') return sendJson(res, 200, all.filter((e) => e.path.startsWith(`${path}/`) && !e.path.slice(path.length + 1).includes('/')).map(item));
    return sendJson(res, 200, { ...item(entry), encoding: 'base64', content: repo.get(entry.sha, 'blob').data.toString('base64') });
  }
  if ((m = /^\/contents\/(.+)$/.exec(rest)) && method === 'PUT') {
    const path = decodeTail(m[1]);
    if (typeof body.message !== 'string') throw invalid('Invalid request.\n\n"message" wasn\'t supplied.');
    if (typeof body.content !== 'string') throw invalid('Invalid request.\n\n"content" wasn\'t supplied.');
    const branch = body.branch || repo.defaultBranch;
    const parent = repo.refs.get(`heads/${branch}`) ?? null;
    if (!parent && !repo.isEmpty) throw new HttpError(404, `Branch ${branch} not found`);
    const baseTree = parent ? repo.get(parent, 'commit').tree : null;
    const existing = baseTree ? repo.files(baseTree).get(path) : null;
    if (existing && !body.sha) throw invalid('Invalid request.\n\n"sha" wasn\'t supplied.');
    if (existing && body.sha !== existing.sha) throw new HttpError(409, `${path} does not match ${body.sha}`);
    const blob = repo.putBlob(Buffer.from(body.content, 'base64'));
    const tree = repo.buildTree(baseTree, [{ path, mode: existing?.mode ?? '100644', type: 'blob', sha: blob }]);
    const sha = repo.putCommit({ tree, parents: parent ? [parent] : [], message: body.message });
    if (repo.isEmpty) repo.defaultBranch = branch;
    repo.setRef(branch, sha);
    const size = repo.get(blob, 'blob').data.length;
    return sendJson(res, existing ? 200 : 201, {
      content: { name: path.split('/').pop(), path, sha: blob, size, type: 'file', url: `${S.api}/contents/${path}?ref=${branch}` },
      commit: S.gitCommit(sha),
    });
  }

  // ---- archive
  if ((m = /^\/zipball(?:\/(.*))?$/.exec(rest)) && method === 'GET') {
    if (repo.isEmpty) throw notFound();
    const ref = m[1] ? decodeTail(m[1]) : repo.defaultBranch;
    const sha = repo.resolveCommit(ref);
    if (!sha) throw notFound();
    const id = randomBytes(12).toString('hex');
    store.codeloads.set(id, { repo: repo.fullName, sha, ref });
    // Like GitHub (api.github.com -> codeload.github.com): a different host, so a
    // client must not forward its token. localhost and 127.0.0.1 differ as hosts.
    const location = `${store.url.replace("//127.0.0.1:", "//localhost:")}/_codeload/${id}.zip`;
    res.writeHead(302, { Location: location, 'Content-Length': 0 });
    return res.end();
  }

  throw notFound();
}

// ---------------------------------------------------------------- merging

function mergeBaseOf(repo, a, b) {
  const aAnc = repo.ancestors(a);
  const date = (s) => Date.parse(repo.get(s, 'commit').committer.date);
  return [...repo.ancestors(b)].filter((s) => aAnc.has(s)).sort((x, y) => date(y) - date(x))[0] ?? null;
}

// A conflict is a path changed on both sides to different contents (a file-level three-way check).
function hasConflicts(repo, baseSha, headSha) {
  const mb = mergeBaseOf(repo, baseSha, headSha);
  const mbTree = mb ? repo.get(mb, 'commit').tree : null;
  const baseTree = repo.get(baseSha, 'commit').tree;
  const headTree = repo.get(headSha, 'commit').tree;
  const ours = new Set(diffFiles(repo, mbTree, baseTree).map((f) => f.filename));
  const baseFiles = repo.files(baseTree);
  const headFiles = repo.files(headTree);
  return diffFiles(repo, mbTree, headTree).some((f) => ours.has(f.filename) && baseFiles.get(f.filename)?.sha !== headFiles.get(f.filename)?.sha);
}

// mergeable / mergeable_state as GitHub reports them for an open pull request.
function pullMergeState(repo, pr) {
  if (pr.state !== 'open') return { mergeable: null, state: 'unknown' };
  const headSha = repo.refs.get(`heads/${pr.head}`);
  const baseSha = repo.refs.get(`heads/${pr.base}`);
  if (!headSha || !baseSha) return { mergeable: null, state: 'unknown' };
  if (pr.draft) return { mergeable: true, state: 'draft' };
  if (hasConflicts(repo, baseSha, headSha)) return { mergeable: false, state: 'dirty' };
  if (pr.blocked) return { mergeable: true, state: 'blocked' };
  const entry = repo.checks.get(headSha);
  const failing = (entry?.runs ?? []).some((r) => (r.status ?? 'completed') === 'completed' && !['success', 'neutral', 'skipped'].includes(r.conclusion ?? 'success'))
    || (entry?.statuses ?? []).some((s) => s.state === 'failure' || s.state === 'error');
  return { mergeable: true, state: failing ? 'unstable' : 'clean' };
}

// A real merge commit (parents: base, head) whose tree applies the head's changes since the merge base.
function mergePull(store, repo, pr, body) {
  const headSha = repo.refs.get(`heads/${pr.head}`);
  const baseSha = repo.refs.get(`heads/${pr.base}`);
  const mb = mergeBaseOf(repo, baseSha, headSha);
  const mbTree = mb ? repo.get(mb, 'commit').tree : null;
  const headTree = repo.get(headSha, 'commit').tree;
  const headFiles = repo.files(headTree);
  const items = diffFiles(repo, mbTree, headTree).map((f) => (f.status === 'removed'
    ? { path: f.filename, mode: '100644', type: 'blob', sha: null }
    : { path: f.filename, mode: headFiles.get(f.filename).mode, type: 'blob', sha: f.sha }));
  const tree = repo.buildTree(repo.get(baseSha, 'commit').tree, items);
  const title = typeof body.commit_title === 'string' && body.commit_title ? body.commit_title : `Merge pull request #${pr.number} from ${repo.owner}/${pr.head}`;
  const extra = typeof body.commit_message === 'string' ? body.commit_message : pr.title;
  const sha = repo.putCommit({ tree, parents: [baseSha, headSha], message: extra ? `${title}\n\n${extra}` : title, author: store.signature(API_USER) });
  repo.setRef(pr.base, sha);
  pr.state = 'closed';
  pr.merged = true;
  pr.merged_at = store.tick();
  pr.merge_commit_sha = sha;
  pr.updated_at = pr.merged_at;
  return sha;
}

function diffFiles(repo, fromTree, toTree) {
  const a = fromTree ? repo.files(fromTree) : new Map();
  const b = repo.files(toTree);
  const out = [];
  const blob = (sha) => repo.get(sha, 'blob')?.data ?? Buffer.alloc(0);
  for (const path of [...new Set([...a.keys(), ...b.keys()])].sort()) {
    const x = a.get(path);
    const y = b.get(path);
    if (x && y && x.sha === y.sha && x.mode === y.mode) continue;
    let row;
    if (!x) row = { status: 'added', additions: lineCount(blob(y.sha)), deletions: 0, sha: y.sha };
    else if (!y) row = { status: 'removed', additions: 0, deletions: lineCount(blob(x.sha)), sha: x.sha };
    else if (x.sha === y.sha) row = { status: 'changed', additions: 0, deletions: 0, sha: y.sha };
    else row = { status: 'modified', ...lineDiff(blob(x.sha), blob(y.sha)), sha: y.sha };
    out.push({ filename: path, ...row, changes: row.additions + row.deletions });
  }
  return out;
}

// ---------------------------------------------------------------- server

export async function startFakeGitHub({ port = 0, token = DEFAULT_TOKEN, extraBranches = 0, emptyRefStatus = 409, verbose = false } = {}) {
  const store = new Store({ token, extraBranches: Number(extraBranches) || 0, emptyRefStatus: Number(emptyRefStatus) === 404 ? 404 : 409 });

  const server = createServer(async (req, res) => {
    const urlObj = new URL(req.url, store.url || 'http://127.0.0.1');
    const path = urlObj.pathname;
    const auth = authState(req, store.token);
    const call = {
      seq: store.calls.length + 1, method: req.method, path, query: urlObj.search, kind: 'api',
      auth, authorizationSent: Boolean(req.headers.authorization), status: null, fault: false,
    };
    const control = path.startsWith('/__fake/');
    if (!control) store.calls.push(call);
    res.on('finish', () => { call.status = res.statusCode; if (verbose) process.stderr.write(`${req.method} ${req.url} -> ${res.statusCode}\n`); });
    try {
      const raw = ['POST', 'PATCH', 'PUT', 'DELETE'].includes(req.method) ? await readBody(req) : Buffer.alloc(0);
      if (control) return await handleControl(store, req, res, path, parseJson(raw, call));
      if (path.startsWith('/_codeload/')) call.kind = 'codeload';

      const fault = store.takeFault(req.method, `${path}${urlObj.search}`);
      if (fault) {
        call.fault = true;
        if (fault.delayMs) await new Promise((r) => setTimeout(r, fault.delayMs));
        if (fault.dropConnection) { req.socket.destroy(); return undefined; }
        const headers = { ...fault.headers };
        if (fault.retryAfter !== null) headers['Retry-After'] = String(fault.retryAfter);
        if (fault.status === 429 || fault.status === 403) {
          headers['X-RateLimit-Remaining'] = '0';
          headers['X-RateLimit-Reset'] = String(Math.floor(Date.now() / 1000) + Number(fault.retryAfter ?? 60));
        }
        return sendJson(res, fault.status, fault.body ?? { message: defaultMessages[fault.status] ?? 'Injected failure', documentation_url: 'https://docs.github.com/rest' }, headers);
      }

      if (path.startsWith('/_codeload/')) return handleCodeload(store, req, res, path, call);
      if (auth !== 'valid') throw new HttpError(401, 'Bad credentials');
      const body = parseJson(raw, call);
      if (path === '/user' && req.method === 'GET') return sendJson(res, 200, { login: API_USER.login, name: API_USER.name, type: 'User' });
      if (path === '/rate_limit' && req.method === 'GET') return sendJson(res, 200, { resources: { core: { limit: 5000, remaining: 4999, reset: 0 } } });
      const m = /^\/repos\/([^/]+)\/([^/]+)(\/.*)?$/.exec(path);
      if (!m) throw notFound();
      const repo = store.repo(`${decodeTail(m[1])}/${decodeTail(m[2])}`);
      if (!repo) throw notFound();
      call.repo = repo.fullName;
      return handleRepo(store, req, res, urlObj, repo, m[3] ?? '', body);
    } catch (err) {
      if (res.headersSent) { res.destroy(); return undefined; }
      if (err instanceof HttpError) return sendError(res, err);
      process.stderr.write(`fake-github internal error: ${err?.stack ?? err}\n`);
      return sendJson(res, 500, { message: 'Server Error' });
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
    close: () => new Promise((resolve) => { server.closeAllConnections?.(); server.close(() => resolve()); }),
  };
}

// ---------------------------------------------------------------- CLI

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const args = process.argv.slice(2);
  const flag = (name) => args.find((a) => a.startsWith(`--${name}=`))?.split('=').slice(1).join('=');
  const positional = args.find((a) => !a.startsWith('--'));
  const fake = await startFakeGitHub({
    port: positional ?? process.env.FAKE_GITHUB_PORT ?? 0,
    token: flag('token') ?? process.env.FAKE_GITHUB_TOKEN ?? DEFAULT_TOKEN,
    extraBranches: flag('branches') ?? 0,
    emptyRefStatus: flag('empty-ref-status') ?? 409,
    verbose: args.includes('--verbose'),
  });
  process.stdout.write(`${JSON.stringify({ url: fake.url, token: fake.token })}\n`);
  const stop = () => fake.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
