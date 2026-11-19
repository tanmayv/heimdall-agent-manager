// Opt-in pin/API spike. Runs the real adapter in an isolated local bridge's
// provider HOME; never changes provider auth or any managed agent instance.
// ACP_ADAPTER_ENTRY and ACP_ISOLATED_HOME are required absolute paths.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import assert from 'node:assert/strict';
import { resolve, isAbsolute } from 'node:path';
import { mkdirSync } from 'node:fs';

const entry = process.env.ACP_ADAPTER_ENTRY;
const home = process.env.ACP_ISOLATED_HOME;
assert(entry && home && isAbsolute(entry) && isAbsolute(home));
assert(home.includes('/heimdall-local/bridges/'), 'use an isolated local bridge provider home');
const cwd = resolve(home, 't16-steering-spike');
mkdirSync(cwd, { recursive: true });
const env = { ...process.env, HOME: home, XDG_CONFIG_HOME: `${home}/.config`, XDG_DATA_HOME: `${home}/.local/share`, XDG_STATE_HOME: `${home}/.local/state`, XDG_CACHE_HOME: `${home}/.cache`, CLAUDE_AGENT_ACP_PROTOCOL: 'v1', CLAUDE_CODE_EXECUTABLE: process.env.ACP_CLAUDE_EXECUTABLE || '/etc/profiles/per-user/tanmay/bin/claude' };
for (const key of ['CLAUDE_CONFIG_DIR', 'HEIMDALL_AGENT_TOKEN', 'HEIMDALL_AGENT_INSTANCE_ID', 'HEIMDALL_BRIDGE_ENDPOINT', 'HEIMDALL_STARTUP_KEY']) delete env[key];
const child = spawn(process.execPath, [entry], { cwd, env, stdio: ['pipe', 'pipe', 'pipe'], detached: true });
const pending = new Map();
let nextId = 1;
let promptRequests = 0;
let toolSeen;
const toolStarted = new Promise((resolve) => { toolSeen = resolve; });
let output = '';
child.stderr.resume(); // diagnostics can contain local config; do not print it.
const request = (method, params) => {
  if (method === 'session/prompt') promptRequests += 1;
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timeout`)); }, 120000);
    pending.set(id, { resolve: (result) => { clearTimeout(timeout); resolve(result); }, reject: (err) => { clearTimeout(timeout); reject(err); } });
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
};
createInterface({ input: child.stdout }).on('line', (line) => {
  const msg = JSON.parse(line);
  if (msg.id !== undefined && (msg.result !== undefined || msg.error)) {
    const p = pending.get(msg.id); pending.delete(msg.id);
    if (msg.error) p?.reject(new Error(JSON.stringify(msg.error))); else p?.resolve(msg.result);
  } else if (msg.method === 'session/update') {
    const u = msg.params.update;
    if (u.sessionUpdate === 'tool_call') toolSeen();
    if (u.sessionUpdate === 'agent_message_chunk' && u.content?.type === 'text') output += u.content.text;
  } else if (msg.id !== undefined) {
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Unsupported in API spike' } })}\n`);
  }
});
const deadline = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 160000);
try {
  const init = await request('initialize', { protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: 'heimdall-t16-spike', version: '1' } });
  assert.equal(init._meta?.steering?.supported, true);
  console.log(JSON.stringify({ steering: init._meta.steering, claudeCode: init.agentCapabilities?._meta?.claudeCode }));
  const session = await request('session/new', { cwd, mcpServers: [] });
  const sessionId = session.sessionId;
  console.log(JSON.stringify({ sessionId }));
  const mode = session.configOptions.find((o) => o.category === 'mode');
  await request('session/set_config_option', { sessionId, configId: mode.id, value: 'bypassPermissions' });
  const steer = (text) => request('_session/steering', { sessionId, prompt: [{ type: 'text', text }], _meta: { steering: { idleBehavior: 'promptRequired' } } });
  const idle = await steer('This idle probe must not start a turn.');
  assert.equal(idle.outcome, 'promptRequired');
  console.log(JSON.stringify({ idle }));
  const running = request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'Use Bash to run sleep 12, then reply ORIGINAL_T16. Do not read or modify files.' }] });
  await Promise.race([toolStarted, new Promise((_, reject) => setTimeout(() => reject(new Error('no tool call to steer')), 60000).unref())]);
  const active = await steer('Change the final answer: reply with only STEERED_T16. Do not run any more tools.');
  assert.equal(active.outcome, 'injected');
  console.log(JSON.stringify({ active }));
  const result = await running;
  assert(output.includes('STEERED_T16'));
  assert.equal(promptRequests, 1);
  console.log(JSON.stringify({ result, promptRequests, sawSteeredAnswer: true }));
} finally {
  clearTimeout(deadline);
  for (const p of pending.values()) p.reject(new Error('spike shutdown'));
  try { process.kill(-child.pid, 'SIGTERM'); } catch {}
}
