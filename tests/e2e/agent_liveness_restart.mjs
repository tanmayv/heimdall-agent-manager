// Run against private fixture processes only. Set LIVENESS_BIN_DIR to the
// source-built Hub, Bridge, CLI and dev proxy, LIVENESS_OLD_PTY_HOST to a
// retained daemon executable, and LIVENESS_PTY_HOST to its replacement.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { scrubHeimdallEnv } from './realHomeGuard.mjs';

const exec = promisify(execFile);
const bin = path.resolve(process.env.LIVENESS_BIN_DIR);
const oldHost = path.resolve(process.env.LIVENESS_OLD_PTY_HOST);
const newHost = path.resolve(process.env.LIVENESS_PTY_HOST);
assert.notEqual(oldHost, newHost, 'use distinct old/current daemon paths');
scrubHeimdallEnv();
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'hl-'));
const local = path.join(root, 'local');
const home = path.join(root, 'home');
await fs.mkdir(home);
const env = { ...process.env, HOME: home, XDG_CONFIG_HOME: path.join(home, '.config'),
  HEIMDALL_LOCAL_STATE_ROOT: local, PATH: root + ':' + process.env.PATH };
const launch = (kind, verb, args = []) => exec('bash',
  ['scripts/local-' + kind + '.sh', verb, '--name', 'live', ...args], { env, timeout: 120000 });
const db = path.join(local, 'hubs/live/hub.db');
const sql = async (query, args = []) => JSON.parse((await exec('python3', ['-c',
  'import sqlite3,json,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute(sys.argv[2],json.loads(sys.argv[3])); print(json.dumps(r.fetchall())); c.commit()',
  db, query, JSON.stringify(args)])).stdout);
const listeners = await Promise.all(Array.from({ length: 6 }, () => new Promise((resolve, reject) => {
  const server = net.createServer();
  server.once('error', reject);
  server.listen(0, '127.0.0.1', () => resolve(server));
})));
const [hubPort, proxyPort, uiPort, oidcPort, bridgePort, agentPort] =
  listeners.map(server => String(server.address().port));
await Promise.all(listeners.map(server => new Promise(resolve => server.close(resolve))));
const origin = 'http://127.0.0.1:' + uiPort;
const request = (route, method = 'GET', body) => fetch('http://127.0.0.1:' + proxyPort + '/api/v1' + route, {
  method, body: body && JSON.stringify(body), signal: AbortSignal.timeout(35000),
  headers: { 'X-Dev-User': 'tanmay', 'Content-Type': 'application/json', Origin: origin },
});
const api = async (route, method, body) => {
  const response = await request(route, method, body);
  const result = await response.json();
  assert.ok(response.ok, method + ' ' + route + ': ' + JSON.stringify(result.error || response.status));
  return result.data;
};
const waitFor = async (predicate, label, ms = 20000) => {
  for (const deadline = Date.now() + ms; Date.now() < deadline;) {
    const result = await predicate();
    if (result) return result;
    await delay(100);
  }
  throw new Error('Timed out waiting for ' + label);
};

let bridge, instance, socket;
const agentEnvPath = path.join(root, 'agent-env.json');
const agentEnv = async () => JSON.parse(await fs.readFile(agentEnvPath, 'utf8'));
const leaseNext = async () => {
  const reply = await exec(path.join(bin, 'ham-ctl'), ['lease', 'next'], {
    env: { ...env, ...await agentEnv() }, timeout: 10000,
  });
  return JSON.parse(reply.stdout).data?.data?.lease;
};
const ptyPid = async () => {
  const output = (await exec(oldHost, ['--socket', socket, 'list'], { env, timeout: 5000 })).stdout;
  const line = output.split('\n').find(row => row.startsWith(instance.agent_instance_id));
  return line?.includes('alive') ? Number(/pid=(\d+)/.exec(line)?.[1] || 0) : 0;
};
const bridgeLog = () => fs.readFile(path.join(local, 'bridges/live/logs/bridge.log'), 'utf8');
const launchBridge = (host, extra = []) => launch('bridge', 'start', ['--hub', 'live', '--port', bridgePort,
  '--local-endpoint-port', agentPort, '--bin-dir', bin, '--pty-host-bin', host, ...extra]);

try {
  await launch('hub', 'start', ['--hub-port', hubPort, '--proxy-port', proxyPort,
    '--ui-port', uiPort, '--oidc-port', oidcPort, '--user', 'tanmay',
    '--no-ui', '--no-plan-limits', '--bin-dir', bin]);
  console.log('fixture Hub ready');
  const provider = path.join(root, 'liveness-fixture-provider');
  await fs.writeFile(provider, '#!/usr/bin/env python3\n'
    + 'import json, os, sys, subprocess, signal\n'
    + 'if "--version" in sys.argv: print("codex-cli 0.162.0"); sys.exit()\n'
    + 'if "plugin" in sys.argv: print(\'{"installed":[],"available":[]}\'); sys.exit()\n'
    + 'if not os.environ.get("HEIMDALL_AGENT_INSTANCE_ID"): sys.exit(2)\n'
    + 'p = ' + JSON.stringify(agentEnvPath) + '\n'
    + 'with open(p+".new","w") as f: json.dump({k:v for k,v in os.environ.items() if k.startswith("HEIMDALL_")}, f)\n'
    + 'os.rename(p+".new",p)\n'
    + 'subprocess.run([' + JSON.stringify(path.join(bin, 'ham-ctl')) + ', "start-success"],check=True)\n'
    + 'while True: signal.pause()\n', { mode: 0o700 });
  await sql("UPDATE provider_catalog SET binary=?, base_args='[]', yolo_args='[]', ask_args='[]', extension='{}' WHERE provider='codex'", [path.basename(provider)]);
  await sql("UPDATE provider_catalog_meta SET catalog_etag='liveness-synthetic-provider'");
  await launchBridge(oldHost, ['--auto-enroll']);
  [bridge] = await api('/bridges');
  assert.ok(bridge?.bridge_id);
  socket = path.join(local, 'bridges/live/endpoint', 'pty-host-' + bridge.bridge_id + '.sock');
  assert.ok(Buffer.byteLength(socket) <= 103, 'fixture socket must not be relocated');
  await api('/bridges/' + bridge.bridge_id + '/providers/discover', 'POST', {});
  await api('/bridges/' + bridge.bridge_id + '/providers/codex', 'PUT', { enabled: true });
  const agent = await api('/agents', 'POST', { name: 'Liveness fixture worker', slug: 'liveness-fixture', instructions: 'Synthetic loopback process' });
  const chain = await api('/task-chains', 'POST', { title: 'Live child lease fixture' });
  const chainRoute = '/task-chains/' + chain.chain_id;
  const [[model]] = await sql("SELECT model_id FROM provider_models WHERE provider='codex' AND state='active' ORDER BY rank LIMIT 1");
  instance = await api('/agent-instances', 'POST', { agent_id: agent.agent_id, bridge_id: bridge.bridge_id,
    provider: 'codex', model, chain_id: chain.chain_id, display_name: 'Liveness fixture worker' });
  const instanceRoute = '/agent-instances/' + instance.agent_instance_id;
  await waitFor(async () => (await api(instanceRoute)).runtime_status === 'running', 'fixture start-success');
  const oldPid = await waitFor(ptyPid, 'old daemon child');
  console.log('fixture worker started PID', oldPid);
  await api(chainRoute + '/fleets/' + agent.agent_id, 'PUT', { capacity: 1, min_warm: 0, provider: 'codex', model });
  await api(chainRoute + '/tasks', 'POST', { title: 'Keep the child', bridge_id: bridge.bridge_id, assignee: agent.agent_id,
    brief: { goal: 'Keep the same child and lease across reconnect', acceptance: ['same lease and PID'] } });
  await api(chainRoute + '/publish', 'POST', {});
  const original = await waitFor(leaseNext, 'confirmed fixture lease');
  console.log('lease before restart', original.lease_id, 'PID', oldPid);

  // The test launcher stops a whole process group. A real binary swap
  // stops only the Bridge. Verify the fixture PID before signaling it.
  const pidFile = path.join(local, 'bridges/live/run/bridge.pid');
  const bridgePid = Number((await fs.readFile(pidFile, 'utf8')).split(' ')[0]);
  assert.ok(Number.isSafeInteger(bridgePid) && bridgePid > 1);
  const bridgeExe = '/proc/' + bridgePid + '/exe';
  assert.equal(await fs.readlink(bridgeExe), await fs.realpath(path.join(bin, 'ham-bridge')));
  process.kill(bridgePid, 'SIGTERM');
  await waitFor(async () => {
    try { await fs.readlink(bridgeExe); return false; }
    catch (error) { if (error.code !== 'ENOENT') throw error; return true; }
  }, 'fixture Bridge exited');
  await fs.rm(pidFile);
  assert.equal(await ptyPid(), oldPid, 'stopping the Bridge leaves the daemon child alive');
  await launchBridge(newHost);
  await waitFor(async () => /keeping the stale daemon while it hosts/.test(await bridgeLog()), 'Bridge retained the old daemon');
  assert.equal(await ptyPid(), oldPid, 'new Bridge adopts the same child');
  const input = await request('/bridges/' + bridge.bridge_id + '/shells/' + instance.agent_instance_id + '/input',
    'POST', { data: Buffer.from('plaintext is invalid when the vault is unlocked').toString('base64') });
  await input.arrayBuffer();
  assert.ok(!input.ok, 'wrong encoding is rejected');
  await waitFor(async () => (await bridgeLog()).includes('shell_pty_input rejected'), 'Bridge input rejection');
  const preserved = await leaseNext();
  assert.equal(preserved.lease_id, original.lease_id, 'same active claim after rejected input');
  assert.equal(preserved.phase, 'active');
  assert.equal(await ptyPid(), oldPid, 'no duplicate process after rejected input');
  assert.equal((await api(instanceRoute)).runtime_status, 'running');
  console.log('PASS retained old daemon/PID, rejected terminal input, and preserved the original claim');
  const restarted = await api(instanceRoute + '/start', 'POST', {});
  assert.equal(restarted.runtime_status, 'running', 'explicit start returns after start-success');
  const newPid = await waitFor(ptyPid, 'replacement child');
  assert.notEqual(newPid, oldPid, 'explicit Start replaces the live PID');
  assert.equal(restarted.run_count, instance.run_count + 1, 'a single generation was opened');
  const stopped = await api(instanceRoute + '/stop', 'POST', {});
  assert.equal(stopped.runtime_status, 'stopped', 'only publish stopped after confirmation');
  assert.equal(await ptyPid(), 0, 'the replacement is no longer alive');
  console.log('PASS explicit Start acknowledged ready replacement PID', newPid, 'and Stop confirmed its exit');
} catch (err) {
  // Only print the narrowly relevant fixture log lines. Startup logs may
  // contain credentials minted for the fixture.
  const log = await bridgeLog().catch(() => '');
  console.error(log.split('\n').filter(line => /stale daemon|child exited|shell_pty_input rejected|agent_runtime_transition/.test(line)).slice(-15).join('\n'));
  throw err;
} finally {
  if (instance) await api('/agent-instances/' + instance.agent_instance_id + '/stop', 'POST', {}).catch(() => {});
  for (const kind of ['bridge', 'hub']) await launch(kind, 'stop').catch(() => {});
  if (socket) await exec(oldHost, ['--socket', socket, 'stop'], { env, timeout: 5000 }).catch(() => {});
  await fs.rm(root, { recursive: true, force: true });
}
