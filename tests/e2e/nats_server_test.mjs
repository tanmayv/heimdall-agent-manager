import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { startNats } from './natsServer.mjs';

const connect = url => new Promise((resolve, reject) => {
  const address = new URL(url);
  const socket = net.connect(Number(address.port), address.hostname);
  socket.once('error', reject);
  socket.once('data', data => { socket.destroy(); resolve(String(data)); });
});

test('private NATS servers own separate ports/stores and stop independently', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nats-helper-test-'));
  const servers = [];
  try {
    const a = await startNats(path.join(root, 'a')); servers.push(a);
    const b = await startNats(path.join(root, 'b')); servers.push(b);
    assert.notEqual(a.url, b.url);
    assert.match(await connect(a.url), /^INFO /);
    assert.match(await connect(b.url), /^INFO /);
    assert.equal(a.hubEnv.HEIMDALL_NATS_URL, a.url);
    assert.equal(a.hubEnv.HEIMDALL_NATS_CREDS_FILE, '');
    await a.stop();
    await assert.rejects(connect(a.url));
    assert.match(await connect(b.url), /^INFO /);
    await a.stop(); // idempotent, never targets a replacement PID
  } finally {
    await Promise.all(servers.map(server => server.stop()));
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('missing NATS binary fails promptly with an actionable error', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nats-helper-failure-'));
  const previous = process.env.HEIMDALL_E2E_NATS_BIN;
  process.env.HEIMDALL_E2E_NATS_BIN = path.join(root, 'missing-binary');
  try { await assert.rejects(startNats(root), /private NATS failed.*install nats-server/); }
  finally {
    if (previous === undefined) delete process.env.HEIMDALL_E2E_NATS_BIN;
    else process.env.HEIMDALL_E2E_NATS_BIN = previous;
    fs.rmSync(root, { recursive: true, force: true });
  }
});
