import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { DatabaseSync } from 'node:sqlite';
import { check, eventually } from '../helpers/nativeMcpAcceptance.ts';
import { sealSecureForm, verifySecureForm } from '../../src/ui/utils/secureFormCrypto.ts';
import { signatureObjectText } from '../../src/ui/utils/vaultStatements.ts';
import { startSecureFormRuntime } from './lib/secureFormRuntime.mjs';

const [control, origin] = process.argv.slice(2);
const secret = fs.readFileSync(0, 'utf8');
const chromium = process.env.HEIMDALL_TEST_CHROMIUM;
const expiry = process.env.HEIMDALL_E2E_SECURE_FORM_EXPIRY === '1';
const formPath = '/api/v1/secure-forms';
// Let nativeMcpHub's exit cleanup stop its owned sessions on a test timeout.
let browser;
process.once('SIGTERM', () => process.exit(143));
process.once('exit', () => browser?.kill());
const { h, bridgeId, bridgeRuntime, task, instance, profile, port } = await startSecureFormRuntime(control);
try {
  const headers = { 'X-Heimdall-Expected-User': h.owner };
  const answer = (method, suffix = '', body) => h.request(method, formPath + suffix, body, headers);
  const endpoint = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(control, 'browser.log'), 'w', 0o600);
  browser = spawn(chromium, [
    '--headless', '--no-sandbox', '--disable-background-networking', '--no-first-run',
    '--enable-automation', '--remote-debugging-address=127.0.0.1', `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`, origin + '/login',
  ], { env: { PATH: process.env.PATH, HOME: control }, stdio: ['ignore', log, log] });
  fs.closeSync(log);
  const launch = await eventually(async () => {
    if (browser.exitCode !== null) throw new Error('fixture browser exited');
    try {
      const tabs = await (await fetch(endpoint + '/json/list', { signal: AbortSignal.timeout(500) })).json();
      return tabs.find(tab => tab.type === 'page' && tab.url === origin + '/login');
    } catch { return undefined; }
  }, 'fixture browser tab');
  fs.writeFileSync(path.join(control, 'login-target.json'), JSON.stringify({ origin, target_id: launch.id }));
  const script = path.join(control, 'login.sh');
  const schema = path.join(control, 'form.json');
  fs.writeFileSync(schema, JSON.stringify({
    version: 1, purpose: 'Sign in to the isolated fixture.',
    fields: [{ id: 'password', label: 'Password', type: 'password' }],
  }));
  fs.writeFileSync(script, 'cat >/dev/null\nprintf "first\\n" >> attempts\nexit 7\n');

  let count = 0;
  function command(...args) {
    const id = ++count;
    const output = path.join(control, 'output-' + id);
    const status = path.join(control, 'status-' + id);
    fs.writeFileSync(path.join(control, 'command.tmp'), args.join('\n') + '\n');
    fs.renameSync(path.join(control, 'command.tmp'), path.join(control, 'command-' + id));
    const read = () => fs.existsSync(output) ? fs.readFileSync(output, 'utf8') : '';
    return {
      request: () => eventually(async () => {
        const m = /secure-form request ([a-f0-9]{64}), attempt (\d+)/.exec(read());
        if (m) return m[1];
        if (fs.existsSync(status)) throw new Error('CLI terminated before request registration, fixed code ' + fs.readFileSync(status, 'utf8').trim());
      }, 'CLI request identifier'),
      code: () => eventually(async () => fs.existsSync(status) ? Number(fs.readFileSync(status, 'utf8')) : undefined, 'CLI terminal status'),
      read,
    };
  }
  const run = () => command('run', '--form', schema, '--script', script, '--timeout', '45', '--execution-timeout', '15');
  const first = run();
  const id = await first.request();
  const route = '/' + id;
  const view = await eventually(async () => {
    const r = await answer('GET', route);
    return r.status === 200 && r.data?.registration ? r.data : undefined;
  }, 'signed form pending on owner route');
  const { registration } = view;
  const transcript = () => {
    const db = new DatabaseSync(path.join(h.root, 'hub.db'), { readOnly: true });
    try {
      return JSON.stringify(db.prepare(
        'SELECT message_id, body, metadata_json FROM chat_messages WHERE conversation_id = ? ORDER BY message_id',
      ).all(registration.request.conversation));
    } finally { db.close(); }
  };
  const transcriptBefore = transcript();
  check(registration.request.task === task && registration.request.instance === instance && registration.request.script === script, 'form binds the real lease and script path');
  const directory = (await h.request('GET', '/api/v1/vault/directory')).data;
  const chain = await h.chain();
  const bridge = [...chain.trusted.values()].find(d => d.kind === 'bridge' && d.row.bridge_id === bridgeId);
  const form = await verifySecureForm(registration, {
    owner: h.owner, bridge: bridgeId, conversation: registration.request.conversation,
  }, bridge.sign_public_key);
  const proof = JSON.stringify({
    owner: h.owner, root_device_id: chain.rootDeviceId, head_hash: chain.headHash, version: chain.version,
    current_epoch: chain.currentEpoch, pin_seq: chain.version, pin_hash: chain.headHash, vault_id: chain.vaultId,
    log: directory.log.map(({ seq, statement, signature }) => ({ seq, statement, signature: signatureObjectText(signature) })),
    devices: directory.devices.map(d => ({
      id: d.device_id, kind: d.kind, sign_alg: d.sign_alg, wrap_alg: d.wrap_alg, sign_public_key: d.sign_public_key,
      ecdh_public_key: d.ecdh_public_key, approved: d.status === 'approved', pending: d.status === 'pending',
    })),
  });
  const envelope = await sealSecureForm(form, { password: secret }, {
    deviceId: h.identity.deviceId, signPrivateKey: h.identity.signPrivateKey,
    sequence: chain.version, head: chain.headHash, proof,
  });
  check(!JSON.stringify(envelope).includes(secret), 'owner sends ciphertext only');
  check((await answer('POST', route + '/submit', envelope)).status === 202, 'one owner submission routed to live Bridge');
  check(await first.code() === 26 && first.read().includes('script exit 7'), 'fixed CLI status and distinct child exit');
  const firstAttemptEndedAt = performance.now();
  check(fs.readFileSync(path.join(control, 'attempts'), 'utf8') === 'first\n', 'one initial spawn');
  const duplicate = await answer('POST', route + '/submit', envelope);
  check(duplicate.status === 409, 'Hub refuses owner replay');
  // Leave enough time between the answer and its actual retry to distinguish
  // expiry from an incorrectly renewed deadline, without injecting a clock.
  const waitUntil = async offset => {
    const remaining = offset - (performance.now() - firstAttemptEndedAt);
    if (remaining > 0) await new Promise(resolve => setTimeout(resolve, remaining));
  };
  if (expiry) await waitUntil(8_000);
  fs.writeFileSync(script, 'printf "second\\n" >> attempts\nexec bash ./fill.sh\n');
  const retry = command('retry', '--request', id, '--after-attempt', '1');
  check(await retry.code() === 0, 'explicit retry runs edited script at same path and fills browser');
  await eventually(async () => {
    const list = await (await fetch(endpoint + '/json/list')).json();
    return list.find(tab => tab.id === launch.id && tab.url === origin + '/account');
  }, 'same browser reaches signed-in account');
  check(await command('retry', '--request', id, '--after-attempt', '1').code() === 0, 'duplicate retry joins existing result');
  check(fs.readFileSync(path.join(control, 'attempts'), 'utf8') === 'first\nsecond\n', 'duplicate request did not spawn or submit again');
  const afterSuccess = await command('retry', '--request', id, '--after-attempt', '2').code();
  check(afterSuccess === 20, `a successful predecessor cannot start another attempt (CLI ${afterSuccess})`);
  if (expiry) {
    // Exercise the real monotonic TTL without changing production clocks or code.
    await waitUntil(302_000);
    const expiredCode = await command('retry', '--request', id, '--after-attempt', '2').code();
    check(expiredCode === 29, `original receipt deadline rejects retry (CLI ${expiredCode}, Bridge ${bridgeRuntime.exitCode ?? bridgeRuntime.signalCode ?? 'running'})`);
  }
  const fresh = run();
  const freshId = await fresh.request();
  check(freshId !== id, 'a fresh form has a distinct request identity');
  const freshView = await eventually(async () => {
    const r = await answer('GET', '/' + freshId);
    return r.status === 200 && r.data?.registration ? r.data : undefined;
  }, 'fresh form pending');
  check((await answer('POST', '/' + freshId + '/decline', {
    version: 1, request_id: freshId, generation: freshView.registration.request.generation,
  })).status === 202 && await fresh.code() === 21, 'declining fresh input does not launch the script');
  check(fs.readFileSync(path.join(control, 'attempts'), 'utf8') === 'first\nsecond\n', 'only explicit authorized attempts ran');
  function confidentialFiles(root) {
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      const file = path.join(root, entry.name);
      if (entry.isDirectory()) confidentialFiles(file);
      if (entry.isFile()) {
        if (fs.readFileSync(file).includes(secret)) throw new Error('synthetic value appeared in captured or persisted bytes');
      }
    }
  }
  check(transcript() === transcriptBefore, 'secure input, retries and decline leave no transcript rows or edits');
  // Both the temporary Hub root and CLI output are inside control.
  confidentialFiles(control);
  check(true, 'no plaintext in CLI output, runtime captures, SQLite or NATS storage');
} finally {
  try {
    if (browser && browser.exitCode === null && browser.signalCode === null) {
      const exited = once(browser, 'exit');
      browser.kill();
      await exited;
    }
  } finally {
    await h.close();
    fs.rmSync(h.root, { recursive: true, force: true });
  }
}
