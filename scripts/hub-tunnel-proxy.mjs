#!/usr/bin/env node
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import { URL } from 'node:url';

function argValue(name, fallback = '') {
  const idx = process.argv.indexOf(name);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return fallback;
}

const listen = argValue('--listen', process.env.HEIMDALL_TUNNEL_PROXY_LISTEN || '127.0.0.1:18080');
const targetRaw = argValue('--target', process.env.HEIMDALL_TUNNEL_PROXY_TARGET || 'https://hub-dev.mundus.in');
const target = new URL(targetRaw);
const listenMatch = listen.match(/^([^:]+):(\d+)$/);

if (!listenMatch) {
  console.error('usage: node scripts/hub-tunnel-proxy.mjs [--listen 127.0.0.1:18080] [--target https://hub-dev.mundus.in] [--connect-host 192.168.0.200] [--connect-port 443]');
  process.exit(2);
}
if (target.protocol !== 'https:') {
  console.error('target must be https://... so bridge traffic is encrypted from this machine to the hub');
  process.exit(2);
}

const listenHost = listenMatch[1];
const listenPort = Number(listenMatch[2]);
const targetHost = target.hostname;
const targetPort = Number(target.port || 443);
const connectHost = argValue('--connect-host', process.env.HEIMDALL_TUNNEL_PROXY_CONNECT_HOST || targetHost);
const connectPort = Number(argValue('--connect-port', process.env.HEIMDALL_TUNNEL_PROXY_CONNECT_PORT || String(targetPort)));
const targetOrigin = `${target.protocol}//${target.host}`;

function targetPath(incomingUrl) {
  const basePath = target.pathname && target.pathname !== '/' ? target.pathname.replace(/\/$/, '') : '';
  return `${basePath}${incomingUrl || '/'}`;
}

function filteredHeaders(headers) {
  const out = { ...headers };
  delete out.host;
  delete out.connection;
  delete out['proxy-connection'];
  delete out['keep-alive'];
  delete out['transfer-encoding'];
  delete out.upgrade;
  out.host = target.host;
  return out;
}

const server = http.createServer((req, res) => {
  const upstream = https.request({
    hostname: connectHost,
    port: connectPort,
    servername: targetHost,
    method: req.method,
    path: targetPath(req.url),
    headers: filteredHeaders(req.headers),
  }, (upstreamRes) => {
    const responseHeaders = { ...upstreamRes.headers };
    delete responseHeaders['transfer-encoding'];
    delete responseHeaders.connection;
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.statusMessage, responseHeaders);
    upstreamRes.pipe(res);
  });

  upstream.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`hub tunnel proxy upstream error: ${err.message}\n`);
  });

  req.pipe(upstream);
});

server.on('upgrade', (req, socket, head) => {
  const upstream = tls.connect({
    host: connectHost,
    port: connectPort,
    servername: targetHost,
  });

  upstream.once('secureConnect', () => {
    const headers = { ...req.headers, host: target.host, connection: 'Upgrade', upgrade: 'websocket' };
    const lines = [`${req.method || 'GET'} ${targetPath(req.url)} HTTP/1.1`];
    for (const [name, value] of Object.entries(headers)) {
      if (Array.isArray(value)) {
        for (const item of value) lines.push(`${name}: ${item}`);
      } else if (value !== undefined) {
        lines.push(`${name}: ${value}`);
      }
    }
    lines.push('', '');
    upstream.write(lines.join('\r\n'));
    if (head && head.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });

  upstream.on('error', (err) => {
    try {
      socket.write('HTTP/1.1 502 Bad Gateway\r\ncontent-type: text/plain\r\nconnection: close\r\n\r\n');
      socket.write(`hub tunnel proxy websocket upstream error: ${err.message}\n`);
    } catch {}
    socket.destroy();
  });
});

server.listen(listenPort, listenHost, () => {
  console.log(`[hub-tunnel-proxy] listening http://${listenHost}:${listenPort}`);
  console.log(`[hub-tunnel-proxy] forwarding HTTP -> ${targetOrigin}`);
  console.log(`[hub-tunnel-proxy] forwarding WS   -> ${targetOrigin.replace(/^https:/, 'wss:')}`);
  if (connectHost !== targetHost || connectPort !== targetPort) {
    console.log(`[hub-tunnel-proxy] TCP connect override ${connectHost}:${connectPort}; TLS SNI/Host/cert name ${targetHost}`);
  }
});
