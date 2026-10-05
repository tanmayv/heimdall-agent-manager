// SCRATCH — REQ-VIEWPORT-SWEEP-1. Serves the fixture and sinks its POSTed readings,
// the same shape as scratch-req-kbd-1/probe-server.mjs. No driver needed: the page
// measures itself and posts, so headless Firefox is only a page loader.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const DIR = '/home/tanmay/heimdall-agent-manager/scratch-sweep1';
const PORT = Number(process.env.PORT || 5191);
http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/report') {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      fs.writeFileSync(path.join(DIR, 'report.json'), body);
      res.writeHead(204).end();
      console.log('REPORT RECEIVED\n' + body);
    });
    return;
  }
  const file = req.url === '/' ? 'composer-reach.html' : req.url.slice(1).split('?')[0];
  const full = path.join(DIR, file);
  if (!full.startsWith(DIR) || !fs.existsSync(full)) { res.writeHead(404).end('no'); return; }
  res.writeHead(200, { 'content-type': file.endsWith('.html') ? 'text/html; charset=utf-8' : 'text/plain' });
  res.end(fs.readFileSync(full));
}).listen(PORT, '127.0.0.1', () => console.log('probe server on ' + PORT));
