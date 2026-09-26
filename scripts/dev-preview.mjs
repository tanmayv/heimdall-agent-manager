#!/usr/bin/env node
// dev-preview.mjs — runs a live Vite dev server with instant HMR inside a
// Heimdall shell session preview tunnel (/api/v1/preview/<session_id>/).
//
// Architecture
// ------------
// 1. Declared session port (PORT, default 5173):
//    A lightweight Node reverse proxy accepts incoming HTTP and WebSocket requests
//    forwarded by the Hub preview tunnel (where /api/v1/preview/<session_id> was stripped).
//    It re-adds the prefix and forwards to internal Vite, and injects the hash routing
//    slash guard into HTML responses.
// 2. Internal Vite dev server (VITE_PORT, default 5174):
//    Runs standard `vite` with `--base /api/v1/preview/<session_id>/`.
//    This guarantees that all module URLs (/@vite/client, /src/ui/main.tsx, dynamic chunks)
//    and the WebSocket HMR endpoint carry the preview tunnel prefix in browser requests.
// 3. Hot Module Replacement (HMR):
//    The reverse proxy forwards WebSocket upgrade requests to Vite on VITE_PORT, enabling
//    real-time live reload and state-preserving React Fast Refresh across the tunnel.

import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import { spawn, execSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function argValue(name, fallback = '') {
  const idx = process.argv.indexOf(name);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return fallback;
}

// Directory the script was invoked from is assumed to be the target project/repo to watch
const ROOT = path.resolve(argValue('--root', process.env.HEIMDALL_ROOT || process.cwd()));

const PORT = Number(argValue('--port', process.env.HEIMDALL_PREVIEW_PORT || '5173'));
const VITE_PORT = Number(argValue('--vite-port', process.env.HEIMDALL_VITE_PORT || '5174'));
let sessionId = argValue('--session-id', process.env.HEIMDALL_PREVIEW_SESSION_ID || '');
const UPSTREAM = new URL(argValue('--upstream', process.env.HEIMDALL_PREVIEW_UPSTREAM || 'http://127.0.0.1:8080'));
const isProd = process.argv.includes('--prod') || process.env.HEIMDALL_PREVIEW_PROD === '1';

/** Forward `/api/v1/...` and `/_dev/...` to local ham-dev-proxy (127.0.0.1:8080). */
function proxyApi(req, res, targetPath) {
  const headers = {};
  for (const [key, value] of Object.entries(req.headers)) {
    const lower = key.toLowerCase();
    if (lower.startsWith('x-authentik')) continue;
    if (lower === 'host' || lower === 'connection') continue;
    headers[key] = value;
  }
  headers.host = UPSTREAM.host;

  const upstreamReq = http.request(
    {
      protocol: UPSTREAM.protocol,
      hostname: UPSTREAM.hostname,
      port: UPSTREAM.port,
      method: req.method,
      path: targetPath,
      headers,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
      upstreamRes.pipe(res);
    },
  );
  upstreamReq.on('error', (err) => {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'upstream_unreachable', message: String(err.message || err) } }));
  });
  req.pipe(upstreamReq);
}

// Two URL traps the preview prefix creates (from preview-server.mjs / ham-ctl-reference):
// 1. TRAILING SLASH: /api/v1/preview/<sid> must have trailing slash.
// 2. EMPTY HASH: Routing is hash-based; with no hash getRoutePathname() falls back to
//    window.location.pathname (/api/v1/preview/<sid>/) which matches no route.
//    history.replaceState seeds #/ without aborting module parsing in the browser.
const SLASH_GUARD =
  '<script data-heimdall-preview-guard>(function(){' +
  'var p=location.pathname,q=location.search,h=location.hash;' +
  'var g=!h||h==="#";' +
  'if(p.charAt(p.length-1)!=="/"){location.replace(p+"/"+q+(g?"#/":h));}' +
  'else if(g&&history.replaceState){history.replaceState(null,"",p+q+"#/");}' +
  '})();</script>';

/** Log static and module requests for diagnostics */
function logRequest(req, res, targetUrl) {
  const startedAt = Date.now();
  res.on('finish', () => {
    console.log(`[dev-preview] ${req.method} ${req.url} -> Vite ${targetUrl} -> ${res.statusCode} (${Date.now() - startedAt}ms)`);
  });
}

/** Find this session's ID from ham-ctl shell list or state file */
function discoverSessionId(port) {
  const stateFile = path.join(ROOT, '.dev-preview-session');
  if (fs.existsSync(stateFile)) {
    try {
      const sid = fs.readFileSync(stateFile, 'utf8').trim();
      if (sid.startsWith('sh_')) return sid;
    } catch {}
  }

  const hamCtlBins = [
    'ham-ctl',
    '/usr/local/google/home/tanmayvijay/.nix-profile/bin/ham-ctl',
    path.join(process.env.HOME || '', '.nix-profile/bin/ham-ctl'),
  ];
  for (const bin of hamCtlBins) {
    try {
      const out = execSync(`${bin} shell list --status running`, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'], timeout: 3000 });
      const data = JSON.parse(out);
      const sessions = data?.data?.data?.sessions || [];
      const match = sessions.find((s) => s.server_port === port && s.status === 'running');
      if (match && match.session_id) {
        return match.session_id;
      }
    } catch {}
  }
  return '';
}

let viteProcess = null;
let viteReady = false;
let pendingRequests = [];

function startVite(sid) {
  const base = sid ? `/api/v1/preview/${sid}/` : '/';
  console.log(`[dev-preview] launching internal Vite on 127.0.0.1:${VITE_PORT} with base: ${base}`);

  const args = [
    'vite',
    '--port', String(VITE_PORT),
    '--host', '127.0.0.1',
    '--base', base,
    '--strictPort',
  ];

  viteProcess = spawn('npx', args, {
    cwd: ROOT,
    stdio: ['inherit', 'pipe', 'pipe'],
    env: {
      ...process.env,
      VITE_API_BASE: isProd ? '' : (process.env.VITE_API_BASE ?? '.'),
      VITE_BASE_API: isProd ? '' : (process.env.VITE_BASE_API ?? '.'),
      FORCE_COLOR: '1',
    },
  });

  viteProcess.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    process.stdout.write(`[vite] ${text}`);
    if (text.includes('ready in') || text.includes('Local:')) {
      viteReady = true;
      flushPending();
    }
  });

  viteProcess.stderr.on('data', (chunk) => {
    process.stderr.write(`[vite-err] ${chunk.toString()}`);
  });

  viteProcess.on('exit', (code, signal) => {
    console.log(`[dev-preview] Vite exited with code ${code} signal ${signal}`);
    process.exit(code || 0);
  });
}

function flushPending() {
  while (pendingRequests.length > 0) {
    const fn = pendingRequests.shift();
    try { fn(); } catch {}
  }
}

// Persistent HTTP agent for upstream requests to Vite, enabling TCP connection pooling
const upstreamAgent = new http.Agent({
  keepAlive: true,
  maxSockets: 100,
  maxFreeSockets: 20,
  timeout: 60000,
});

// Clean shutdown on signals
function cleanup() {
  upstreamAgent.destroy();
  if (viteProcess) {
    try { viteProcess.kill('SIGTERM'); } catch {}
  }
  process.exit(0);
}
process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

// Attempt discovery if sessionId was not passed explicitly
if (!sessionId) {
  for (let attempt = 0; attempt < 5; attempt++) {
    sessionId = discoverSessionId(PORT);
    if (sessionId) {
      console.log(`[dev-preview] discovered session ID: ${sessionId}`);
      break;
    }
    // Synchronous sleep 300ms
    try {
      const waitTill = new Date(new Date().getTime() + 300);
      while (waitTill > new Date()) {}
    } catch {}
  }
  if (!sessionId) {
    console.warn(`[dev-preview] warning: could not determine session ID for port ${PORT}, starting Vite with base /`);
  }
}

startVite(sessionId);

// Start the reverse proxy server on PORT
const server = http.createServer((req, res) => {
  const handler = () => {
    const basePrefix = sessionId ? `/api/v1/preview/${sessionId}` : '';
    let targetPath = req.url || '/';

    // Normalize path by stripping preview prefix if present
    let cleanPath = targetPath;
    if (basePrefix && cleanPath.startsWith(basePrefix)) {
      cleanPath = cleanPath.slice(basePrefix.length) || '/';
    }

    // Forward API and dev-auth routes directly to local ham-dev-proxy (8080)
    if (cleanPath.startsWith('/api/v1/') || cleanPath.startsWith('/_dev/')) {
      proxyApi(req, res, cleanPath);
      return;
    }

    // If incoming request doesn't have the base prefix, prepend it so Vite router matches
    if (basePrefix && !targetPath.startsWith(basePrefix)) {
      if (!targetPath.startsWith('/')) targetPath = '/' + targetPath;
      targetPath = `${basePrefix}${targetPath}`;
    }

    logRequest(req, res, targetPath);

    const headers = { ...req.headers };
    headers.host = `127.0.0.1:${VITE_PORT}`;
    // Strip incoming 'connection: close' so upstreamAgent can maintain persistent TCP keep-alive sockets to Vite
    delete headers.connection;

    const upstreamReq = http.request(
      {
        hostname: '127.0.0.1',
        port: VITE_PORT,
        method: req.method,
        path: targetPath,
        headers,
        agent: upstreamAgent,
      },
      (upstreamRes) => {
        const contentType = upstreamRes.headers['content-type'] || '';
        const isHtml = contentType.toLowerCase().includes('text/html');

        if (isHtml) {
          // Buffer HTML to inject the slash guard
          const chunks = [];
          upstreamRes.on('data', (c) => chunks.push(c));
          upstreamRes.on('end', () => {
            const raw = Buffer.concat(chunks).toString('utf8');
            const injected = raw.includes('<head>')
              ? raw.replace('<head>', `<head>${SLASH_GUARD}`)
              : SLASH_GUARD + raw;
            const body = Buffer.from(injected, 'utf8');

            const outHeaders = { ...upstreamRes.headers };
            delete outHeaders['content-length'];
            delete outHeaders['transfer-encoding'];
            outHeaders['content-length'] = body.length;
            outHeaders['cache-control'] = 'no-store';
            outHeaders['connection'] = 'close';

            res.writeHead(upstreamRes.statusCode || 200, outHeaders);
            res.end(body);
          });
        } else {
          // Non-HTML assets (JS, CSS, images, maps) stream directly.
          // Preserve ETag and allow conditional 304 caching (via cache-control: no-cache)
          // while ensuring HMR remains live.
          const outHeaders = { ...upstreamRes.headers };
          const upstreamCache = upstreamRes.headers['cache-control'];
          outHeaders['cache-control'] = upstreamCache && upstreamCache !== 'no-store' ? upstreamCache : 'no-cache';
          outHeaders['connection'] = 'close';

          res.writeHead(upstreamRes.statusCode || 200, outHeaders);
          upstreamRes.pipe(res);
        }
      }
    );

    upstreamReq.on('error', (err) => {
      console.error(`[dev-preview] upstream error: ${err.message}`);
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'text/plain' });
      }
      res.end(`dev preview upstream error: ${err.message}\n`);
    });

    req.pipe(upstreamReq);
  };

  if (viteReady) {
    handler();
  } else {
    pendingRequests.push(handler);
  }
});

// Relay WebSocket upgrades (API WebSockets to ham-dev-proxy, HMR to Vite)
server.on('upgrade', (req, clientSocket, head) => {
  const basePrefix = sessionId ? `/api/v1/preview/${sessionId}` : '';
  let targetPath = req.url || '/';
  let cleanPath = targetPath;
  if (basePrefix && cleanPath.startsWith(basePrefix)) {
    cleanPath = cleanPath.slice(basePrefix.length) || '/';
  }

  // Forward API WebSockets (e.g. /api/v1/user-ws, /api/v1/lsp/) to ham-dev-proxy (8080)
  if (cleanPath.startsWith('/api/v1/')) {
    const headers = { ...req.headers, host: UPSTREAM.host };
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase().startsWith('x-authentik')) delete headers[key];
    }
    const upstreamReq = http.request({
      protocol: UPSTREAM.protocol,
      hostname: UPSTREAM.hostname,
      port: UPSTREAM.port,
      method: req.method,
      path: cleanPath,
      headers,
    });
    upstreamReq.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
      const statusLine = Object.entries(upstreamRes.headers)
        .map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(', ') : v}`)
        .join('\r\n');
      clientSocket.write(`HTTP/1.1 101 Switching Protocols\r\n${statusLine}\r\n\r\n`);
      if (upstreamHead?.length) clientSocket.unshift(upstreamHead);
      upstreamSocket.pipe(clientSocket).pipe(upstreamSocket);
      upstreamSocket.on('error', () => clientSocket.destroy());
      clientSocket.on('error', () => upstreamSocket.destroy());
    });
    upstreamReq.on('response', (upstreamRes) => {
      clientSocket.end(`HTTP/1.1 ${upstreamRes.statusCode} ${upstreamRes.statusMessage}\r\n\r\n`);
    });
    upstreamReq.on('error', () => clientSocket.destroy());
    if (head?.length) upstreamReq.write(head);
    upstreamReq.end();
    return;
  }

  if (basePrefix && !targetPath.startsWith(basePrefix)) {
    if (!targetPath.startsWith('/')) targetPath = '/' + targetPath;
    targetPath = `${basePrefix}${targetPath}`;
  }

  console.log(`[dev-preview] WebSocket upgrade for ${req.url} -> forwarding to Vite ${targetPath}`);

  const upstreamSocket = net.connect(VITE_PORT, '127.0.0.1', () => {
    const headers = { ...req.headers };
    headers.host = `127.0.0.1:${VITE_PORT}`;

    const lines = [`${req.method || 'GET'} ${targetPath} HTTP/1.1`];
    for (const [name, val] of Object.entries(headers)) {
      if (Array.isArray(val)) {
        for (const item of val) lines.push(`${name}: ${item}`);
      } else if (val !== undefined) {
        lines.push(`${name}: ${val}`);
      }
    }
    lines.push('', '');

    upstreamSocket.write(lines.join('\r\n'));
    if (head && head.length) upstreamSocket.write(head);

    clientSocket.pipe(upstreamSocket).pipe(clientSocket);
  });

  upstreamSocket.on('error', (err) => {
    console.error(`[dev-preview] WebSocket relay error: ${err.message}`);
    clientSocket.destroy();
  });

  clientSocket.on('error', (err) => {
    upstreamSocket.destroy();
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[dev-preview] listening on http://127.0.0.1:${PORT}`);
  console.log(`[dev-preview] proxying to Vite on http://127.0.0.1:${VITE_PORT}`);
  if (sessionId) {
    console.log(`[dev-preview] base path: /api/v1/preview/${sessionId}/`);
  }
});
