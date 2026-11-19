// Same real-server contract as src/lib/natstest: OS-assigned port, private
// JetStream store, and ownership of exactly one child. Never use ambient NATS.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export async function startNats(directory) {
  const dir = path.join(directory, 'nats');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const logPath = path.join(dir, 'server.log');
  const log = fs.openSync(logPath, 'a', 0o600);
  const child = spawn(process.env.HEIMDALL_E2E_NATS_BIN || process.env.HEIMDALL_TEST_NATS_BIN || 'nats-server',
    ['-js', '-a', '127.0.0.1', '-p', '-1', '-sd', path.join(dir, 'store'), '--ports_file_dir', dir],
    { stdio: ['ignore', log, log], windowsHide: true });
  fs.closeSync(log);
  let failure;
  child.once('error', err => { failure = err; });
  const kill = () => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); };
  process.once('exit', kill);
  child.once('exit', () => process.removeListener('exit', kill));
  const stop = async () => {
    if (child.exitCode !== null || child.signalCode !== null || !child.pid) return;
    child.kill();
    await new Promise(resolve => {
      const timer = setTimeout(() => { kill(); resolve(); }, 3000);
      child.once('exit', () => { clearTimeout(timer); resolve(); });
    });
  };
  try {
    for (const deadline = Date.now() + 10000; Date.now() < deadline;) {
      if (failure) throw failure;
      if (child.exitCode !== null || child.signalCode !== null) throw new Error('nats-server exited during startup');
      try {
        // NATS uses the executable basename (nats-server.exe on Windows).
        // The private directory and exact child PID identify our server even
        // when HEIMDALL_E2E_NATS_BIN points to a renamed binary.
        const portFile = fs.readdirSync(dir).find(name => name.endsWith('_' + child.pid + '.ports'));
        if (!portFile) throw new Error('waiting for child ports file');
        const ports = JSON.parse(fs.readFileSync(path.join(dir, portFile), 'utf8'));
        const url = ports.nats?.[0];
        if (url && new URL(url).hostname === '127.0.0.1') {
          return { url, child, kill, stop,
            hubEnv: { HEIMDALL_NATS_URL: url, HEIMDALL_NATS_CREDS_FILE: '', HEIMDALL_NATS_CA_FILE: '' } };
        }
      } catch { /* port file is published after the listener is ready */ }
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    throw new Error('nats-server readiness timeout');
  } catch (err) {
    await stop();
    process.removeListener('exit', kill);
    throw new Error('private NATS failed (install nats-server or set HEIMDALL_E2E_NATS_BIN): ' + err.message + '\n' + fs.readFileSync(logPath, 'utf8'));
  }
}
