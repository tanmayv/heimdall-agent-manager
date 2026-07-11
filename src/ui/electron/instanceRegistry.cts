import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

export interface InstanceEntry {
  pid: number;
  port: number;
  startedAt: number;
  daemonUrl: string;
}

function registryPath(): string {
  const dataDir = path.join(os.homedir(), '.local', 'share', 'heimdall');
  fs.mkdirSync(dataDir, { recursive: true });
  return path.join(dataDir, 'debug-instances.json');
}

function readAll(): InstanceEntry[] {
  try {
    return JSON.parse(fs.readFileSync(registryPath(), 'utf8')) as InstanceEntry[];
  } catch {
    return [];
  }
}

function writeAll(entries: InstanceEntry[]): void {
  try {
    fs.writeFileSync(registryPath(), JSON.stringify(entries, null, 2), 'utf8');
  } catch {
    // best-effort
  }
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export function pruneAndRegister(daemonUrl: string): void {
  const live = readAll().filter((e) => e.pid !== process.pid && isAlive(e.pid));
  live.push({ pid: process.pid, port: 0, startedAt: Date.now(), daemonUrl });
  writeAll(live);
}

export function updatePort(port: number): void {
  const entries = readAll().map((e) => (e.pid === process.pid ? { ...e, port } : e));
  writeAll(entries);
}

export function deregister(): void {
  writeAll(readAll().filter((e) => e.pid !== process.pid));
}

export function listInstances(): InstanceEntry[] {
  return readAll().filter((e) => isAlive(e.pid));
}
