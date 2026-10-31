// Run with: node --test ui-src/tests/api.test.ts   (Node 22.18+ strips the types; nothing to install)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApi, ApiError, plainMessage } from '../src/api.ts';

interface Seen { path: string; init: RequestInit }
type Reply = { status?: number; body: unknown } | { status?: number; text: string };

// A scripted fetch: replies are used in order, and every request is recorded.
function scripted(replies: Reply[]) {
  const seen: Seen[] = [];
  const queue = [...replies];
  const fetchImpl = (async (path: string, init: RequestInit) => {
    seen.push({ path, init });
    const next = queue.shift();
    if (!next) throw new Error('unexpected request: ' + path);
    const status = next.status ?? 200;
    const text = 'text' in next ? next.text : JSON.stringify(next.body);
    return { status, ok: status >= 200 && status < 300, text: async () => text } as Response;
  }) as unknown as typeof fetch;
  return { seen, fetchImpl };
}
const noSleep = async () => {};
const api = (fetchImpl: typeof fetch, extra: Record<string, unknown> = {}) =>
  createApi({ clientSecret: () => 'secret-1', fetchImpl, sleep: noSleep, ...extra });

test('a request carries the client header, JSON body, no cache and same-origin cookies', async () => {
  const { seen, fetchImpl } = scripted([{ body: { ok: true } }, { body: { ok: true } }]);
  const client = api(fetchImpl);
  await client.request('/api/status');
  await client.request('/api/connect', 'POST', { url: 'https://example.test/a/b' });
  const [get, post] = seen;
  assert.deepEqual(get.init.headers, { 'X-Gangplank-Client': 'secret-1' }, 'a GET has no content type');
  assert.equal(get.init.body, undefined);
  assert.equal(post.init.method, 'POST');
  assert.deepEqual(post.init.headers, { 'X-Gangplank-Client': 'secret-1', 'Content-Type': 'application/json' });
  assert.equal(post.init.body, '{"url":"https://example.test/a/b"}');
  assert.equal(post.init.cache, 'no-store');
  assert.equal(post.init.credentials, 'same-origin');
});

test('errors keep the code and show the message without a CODE| prefix', async () => {
  const { fetchImpl } = scripted([
    { status: 400, body: { error: 'BAD_REQUEST', message: 'Enter a valid project address.' } },
    { status: 409, body: { error: 'CONFLICT', message: 'CONFLICT|The branch moved.' } },
    { status: 500, text: '<html>not json</html>' },
  ]);
  const client = api(fetchImpl);
  await assert.rejects(client.request('/api/connect', 'POST', { url: 'x' }), (e: ApiError) => e instanceof ApiError && e.code === 'BAD_REQUEST' && e.status === 400 && e.message === 'Enter a valid project address.');
  await assert.rejects(client.request('/api/start', 'POST', { name: 'x' }), (e: ApiError) => e.code === 'CONFLICT' && e.message === 'The branch moved.');
  await assert.rejects(client.request('/api/status'), (e: ApiError) => e.code === 'BAD_RESPONSE' && e.message === 'Invalid service response');
});

test('a 401 SESSION tells the page the session ended', async () => {
  const { fetchImpl } = scripted([{ status: 401, body: { error: 'SESSION', message: 'This session ended. Open the link in the PowerShell window.' } }]);
  let told = '';
  const client = api(fetchImpl, { onSessionEnded: (m: string) => { told = m; } });
  await assert.rejects(client.request('/api/status'), (e: ApiError) => e.code === 'SESSION' && e.status === 401);
  assert.match(told, /session ended/);
});

test('a job is polled until it succeeds; progress and chunks arrive in order', async () => {
  const { seen, fetchImpl } = scripted([
    { status: 202, body: { job: 'job-abc123abc123' } },
    { body: { state: 'running', progress: 'Downloading', chunks: ['He'], next: 1, result: null, error: '' } },
    { body: { state: 'running', progress: 'Unpacking', chunks: ['llo'], next: 2, result: null, error: '' } },
    { body: { state: 'succeeded', progress: 'Done', chunks: [], next: 2, result: { folder: 'C:\\work\\demo' }, error: '' } },
  ]);
  const progress: string[] = [], chunks: string[] = [];
  let started = '';
  const result = await api(fetchImpl).runJob<{ folder: string }>('/api/download', { branch: 'main' }, {
    onStart: (id) => { started = id; }, onProgress: (p) => progress.push(p), onChunk: (c) => chunks.push(c),
  });
  assert.equal(result.folder, 'C:\\work\\demo');
  assert.equal(started, 'job-abc123abc123');
  assert.deepEqual(progress, ['Downloading', 'Unpacking', 'Done']);
  assert.deepEqual(chunks, ['He', 'llo']);
  assert.deepEqual(seen.slice(1).map((s) => s.path), ['/api/jobs/job-abc123abc123?after=0', '/api/jobs/job-abc123abc123?after=1', '/api/jobs/job-abc123abc123?after=2'], 'each poll resumes after the chunks already seen');
});

test('a failed job throws with its code, a cancelled one with CANCELLED', async () => {
  const failed = scripted([{ status: 202, body: { job: 'job-1' } }, { body: { state: 'failed', progress: '', chunks: [], next: 0, result: null, error: 'CONFLICT|The branch changed online.' } }]);
  await assert.rejects(api(failed.fetchImpl).runJob('/api/save', { paths: ['a'] }), (e: ApiError) => e.code === 'CONFLICT' && e.message === 'The branch changed online.');
  const plain = scripted([{ status: 202, body: { job: 'job-2' } }, { body: { state: 'failed', progress: '', chunks: [], next: 0, result: null, error: '' } }]);
  await assert.rejects(api(plain.fetchImpl).runJob('/api/save', {}), (e: ApiError) => e.code === '' && e.message === 'The operation failed.');
  const cancelled = scripted([{ status: 202, body: { job: 'job-3' } }, { body: { state: 'cancelling', progress: 'Stopping', chunks: [], next: 0, result: null, error: '' } }, { body: { state: 'cancelled', progress: '', chunks: [], next: 0, result: null, error: '' } }]);
  await assert.rejects(api(cancelled.fetchImpl).runJob('/api/download', {}), (e: ApiError) => e.code === 'CANCELLED' && /Stopped before it finished/.test(e.message));
});

test('an answer without a job is returned as it is, and a job can be cancelled', async () => {
  const { seen, fetchImpl } = scripted([{ body: { url: 'https://example.test/pull/5', existing: true } }, { body: { cancelled: true } }]);
  const client = api(fetchImpl);
  assert.deepEqual(await client.runJob('/api/review', {}), { url: 'https://example.test/pull/5', existing: true });
  assert.deepEqual(await client.cancelJob('job-9'), { cancelled: true });
  assert.equal(seen[1].path, '/api/jobs/job-9/cancel');
  assert.equal(seen[1].init.method, 'POST');
});

test('plainMessage drops only a leading CODE| prefix', () => {
  assert.equal(plainMessage('AUTH_REJECTED|GitHub rejected the token.'), 'GitHub rejected the token.');
  assert.equal(plainMessage('No prefix | here'), 'No prefix | here');
  assert.equal(plainMessage(undefined), '');
});
