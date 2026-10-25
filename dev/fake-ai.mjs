// Synthetic AI gateway for LocalDev and tests. Zero dependencies, loopback only.
//   mode "openai": GET /v1/models, POST /v1/chat/completions (stream and non-stream)
//   mode "ollama": GET /api/tags (no /v1/models), POST /v1/chat/completions
// Echoes a short answer; records calls (with whether a token was sent) at GET /__fake/state.
// CLI: node dev/fake-ai.mjs [port|0] [--mode=openai|ollama] [--token=x]  -> prints {"url","token","mode"}
import http from 'node:http';
import { pathToFileURL } from 'node:url';

const MODELS = ['text-embedding-3-small', 'gpt-4o-mini', 'whisper-1', 'gpt-4.1', 'llama-3.1-8b-instruct', 'tts-1'];

export function startFakeAi({ port = 0, mode = 'openai', token = 'fake-ai-token' } = {}) {
  const calls = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (d) => { body += d; if (body.length > 1e6) req.destroy(); });
    req.on('end', () => {
      const url = new URL(req.url, 'http://x');
      const auth = req.headers.authorization || '';
      calls.push({ method: req.method, path: url.pathname, authorizationSent: !!auth });
      const json = (status, obj) => { const b = JSON.stringify(obj); res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) }); res.end(b); };
      if (url.pathname === '/__fake/state') return json(200, { mode, calls });
      const needsAuth = mode === 'openai';
      if (needsAuth && auth !== `Bearer ${token}`) return json(401, { error: { message: 'invalid api key' } });
      if (req.method === 'GET' && url.pathname === '/v1/models' && mode === 'openai') return json(200, { object: 'list', data: MODELS.map((id) => ({ id, object: 'model' })) });
      if (req.method === 'GET' && url.pathname === '/api/tags' && mode === 'ollama') return json(200, { models: [{ name: 'llama3.1:8b' }, { name: 'nomic-embed-text:latest' }, { name: 'qwen2.5:7b' }] });
      if (req.method === 'POST' && url.pathname === '/v1/chat/completions') {
        let p = {}; try { p = JSON.parse(body); } catch { return json(400, { error: { message: 'bad json' } }); }
        const last = (p.messages || []).slice(-1)[0]?.content || '';
        const answer = /single word OK/.test(last) ? 'OK' : `Echo from ${p.model}: ${String(last).slice(0, 60)}`;
        if (p.stream) {
          res.writeHead(200, { 'Content-Type': 'text/event-stream' });
          for (const part of answer.match(/.{1,8}/g) || []) res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: part } }] })}\n\n`);
          res.write('data: [DONE]\n\n');
          return res.end();
        }
        return json(200, { choices: [{ message: { role: 'assistant', content: answer } }], model: p.model });
      }
      return json(404, { error: { message: 'not found' } });
    });
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => {
    const url = `http://127.0.0.1:${server.address().port}`;
    resolve({ url, token, mode, calls, close: () => new Promise((r) => server.close(r)) });
  }));
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const args = process.argv.slice(2);
  const port = Number(args.find((a) => /^\d+$/.test(a)) || 0);
  const opt = (k, d) => (args.find((a) => a.startsWith(`--${k}=`)) || '').split('=')[1] || d;
  startFakeAi({ port, mode: opt('mode', 'openai'), token: opt('token', 'fake-ai-token') }).then((f) => console.log(JSON.stringify({ url: f.url, token: f.token, mode: f.mode })));
}
