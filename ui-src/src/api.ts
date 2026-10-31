// Typed client for the Gangplank host API. It behaves exactly like api() and runJob() in
// web/app.js, which this will replace screen by screen (docs/ROADMAP.md items 8 and 9):
//   - every call carries the X-Gangplank-Client header, JSON bodies, no cache, same-origin cookies;
//   - errors are { error: CODE, message }, shown without the CODE| prefix, with the code kept;
//   - long operations answer { job }, which is polled until it succeeds, fails or is cancelled.
// Only erasable TypeScript syntax is used, so Node can run this file and its tests directly
// (type stripping) without a build step.

export type JobState = 'running' | 'cancelling' | 'succeeded' | 'failed' | 'cancelled';

export interface JobView<T = unknown> {
  id: string;
  kind: string;
  state: JobState;
  progress: string;
  chunks: string[];
  next: number;
  result: T | null;
  error: string;
  started: string;
  finished: string;
}

export interface ApiOptions {
  /** The per-session client secret the page was opened with. */
  clientSecret: () => string;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  /** How often a running job is polled. */
  pollMs?: number;
  /** Called when the host says the session is over (HTTP 401 with error SESSION). */
  onSessionEnded?: (message: string) => void;
}

export interface JobHooks {
  onStart?: (jobId: string) => void;
  onProgress?: (text: string) => void;
  onChunk?: (text: string) => void;
}

export class ApiError extends Error {
  code: string;
  status: number;
  constructor(message: string, code = '', status = 0) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.status = status;
  }
}

/** A message without its CODE| prefix, as people should read it. */
export function plainMessage(message: unknown): string {
  return String(message ?? '').replace(/^[A-Z][A-Z0-9_]{2,40}\|/, '');
}

const CODED = /^[A-Z][A-Z0-9_]{2,40}\|/;

export function createApi(options: ApiOptions) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const pollMs = options.pollMs ?? 400;

  async function request<T>(path: string, method = 'GET', body?: unknown): Promise<T> {
    const headers: Record<string, string> = { 'X-Gangplank-Client': options.clientSecret() };
    if (body) headers['Content-Type'] = 'application/json';
    const response = await fetchImpl(path, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store',
      credentials: 'same-origin',
    });
    const text = await response.text();
    let parsed: { error?: string; message?: string };
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new ApiError('Invalid service response', 'BAD_RESPONSE', response.status);
    }
    if (response.status === 401 && parsed.error === 'SESSION') {
      options.onSessionEnded?.(String(parsed.message ?? ''));
      throw new ApiError(String(parsed.message ?? 'The session has ended.'), 'SESSION', 401);
    }
    if (!response.ok) {
      throw new ApiError(plainMessage(parsed.message || parsed.error || 'Request failed'), parsed.error || '', response.status);
    }
    return parsed as T;
  }

  /** Start a long operation and wait for it. Resolves with the job's result. */
  async function runJob<T>(path: string, body?: unknown, hooks: JobHooks = {}): Promise<T> {
    const started = await request<{ job?: string }>(path, 'POST', body ?? {});
    if (!started.job) return started as unknown as T;     // answered straight away, no job
    const id = started.job;
    hooks.onStart?.(id);
    let after = 0;
    for (;;) {
      await sleep(pollMs);
      const view = await request<JobView<T>>(`/api/jobs/${id}?after=${after}`);
      if (view.chunks) for (const chunk of view.chunks) hooks.onChunk?.(chunk);
      after = view.next;
      hooks.onProgress?.(view.progress);
      if (view.state === 'succeeded') return (view.result ?? {}) as T;
      if (view.state === 'cancelled') {
        throw new ApiError('Stopped before it finished. The History tab shows whether the change went through.', 'CANCELLED');
      }
      if (view.state !== 'running' && view.state !== 'cancelling') {
        const raw = view.error || 'The operation failed.';
        throw new ApiError(plainMessage(raw), CODED.test(raw) ? raw.split('|')[0] : '');
      }
    }
  }

  function cancelJob(id: string): Promise<{ cancelled: boolean }> {
    return request<{ cancelled: boolean }>(`/api/jobs/${id}/cancel`, 'POST', {});
  }

  return { request, runJob, cancelJob };
}
