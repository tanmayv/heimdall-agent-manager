// Projects found in past agent sessions on a bridge, for the setup wizard's
// Projects step. Unit-tested in tests/ui_setup_wizard_test.ts.
//
// Claude Code keeps one folder per working directory under ~/.claude/projects,
// named after the directory with every path separator and other non-alphanumeric
// character replaced by "-" (/home/me/my-app → -home-me-my-app, C:\Users\me\app →
// C--Users-me-app). That name is lossy ("-" may have been "/", "-", "." or "_"),
// so each candidate is resolved against the bridge with fs/stat, one path
// component at a time; anything that does not resolve to an existing folder is
// dropped. Only the bridge's own sandboxed fs API is used (GET /bridges/{id}/fs and
// /fs/stat), so nothing outside the bridge's fs_root is read.
//
// Codex keeps its sessions as dated JSONL files whose working directory is inside
// the file; reading those needs a bridge endpoint that does not exist yet, so Codex
// history is not discovered here.

export interface FsEntry { name: string; is_dir: boolean }
export interface FsListing { ok: boolean; path: string; entries: FsEntry[] }
export interface FsStat { ok: boolean; exists: boolean; is_dir: boolean }

export interface SessionFs {
  list(path: string): Promise<FsListing | null>;
  stat(path: string): Promise<FsStat | null>;
}

export interface DiscoveredProject {
  /** Folder name, used as the project name. */
  name: string;
  /** Absolute path on the bridge. */
  path: string;
  sessions: number;
  source: 'Claude Code';
}

const JOINERS = ['-', '.', '_', ' '];
/** Stat calls one folder name may spend before it is given up on. */
const MAX_STATS_PER_ENTRY = 48;

interface Encoded { root: string; sep: string; tokens: string[] }

/** Split a Claude project folder name into its root and "-"-separated tokens. */
export function parseClaudeProjectDir(name: string): Encoded | null {
  const drive = /^([A-Za-z])--(.*)$/.exec(name);
  if (drive) return { root: `${drive[1].toUpperCase()}:\\`, sep: '\\', tokens: drive[2].split('-') };
  if (name.startsWith('-')) return { root: '/', sep: '/', tokens: name.slice(1).split('-') };
  return null;
}

/**
 * Resolve an encoded folder name to the directory it came from, or '' when no
 * existing directory matches. Depth-first: at each "-" either a new path component
 * starts (its parent must be an existing folder) or the current component goes on
 * with one of the characters "-" also stands for. An empty token (two "-" in a row)
 * starts a component with "." (a hidden folder such as .config).
 */
export async function resolveClaudeProjectDir(name: string, stat: SessionFs['stat']): Promise<string> {
  const parsed = parseClaudeProjectDir(name);
  if (!parsed || parsed.tokens.length === 0 || parsed.tokens.every((t) => !t)) return '';
  const { root, sep, tokens } = parsed;
  const cache = new Map<string, boolean>();
  let budget = MAX_STATS_PER_ENTRY;
  const isDir = async (path: string): Promise<boolean> => {
    if (cache.has(path)) return cache.get(path) as boolean;
    if (budget-- <= 0) return false;
    const result = await stat(path).catch(() => null);
    const ok = Boolean(result?.ok && result.exists && result.is_dir);
    cache.set(path, ok);
    return ok;
  };
  const join = (base: string, part: string) => (base.endsWith(sep) ? base + part : base + sep + part);

  // base: the resolved folders so far; current: the component being built.
  const walk = async (i: number, base: string, current: string): Promise<string> => {
    // Out of stats: give up on the whole name. Without this the search keeps
    // branching on cached/refused lookups (JOINERS^tokens) and never returns.
    if (budget <= 0) return '';
    if (i === tokens.length) {
      const full = join(base, current);
      return current && (await isDir(full)) ? full : '';
    }
    const token = tokens[i];
    if (!current) {
      // Start of a component: an empty token is the "." of a hidden folder.
      if (!token) return i + 1 < tokens.length ? walk(i + 2, base, `.${tokens[i + 1]}`) : '';
      return walk(i + 1, base, token);
    }
    // Close the current component and start a new one…
    const closed = join(base, current);
    if (await isDir(closed)) {
      const found = await walk(i, closed, '');
      if (found) return found;
    }
    // …or keep building it with a character "-" stood for.
    if (!token) return '';
    for (const joiner of JOINERS) {
      const found = await walk(i + 1, base, current + joiner + token);
      if (found) return found;
    }
    return '';
  };
  return walk(0, root, '');
}

function lastSegment(path: string): string {
  const parts = path.split(/[\\/]+/).filter(Boolean);
  return parts[parts.length - 1] || path;
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      out[index] = await fn(items[index]);
    }
  });
  await Promise.all(workers);
  return out;
}

/**
 * Folders that have Claude Code sessions on this bridge, most sessions first.
 * Returns [] when the bridge has no ~/.claude/projects.
 */
export async function discoverClaudeProjects(fs: SessionFs, limit = 40): Promise<DiscoveredProject[]> {
  const listing = await fs.list('~/.claude/projects').catch(() => null);
  if (!listing?.ok) return [];
  const sep = listing.path.includes('\\') ? '\\' : '/';
  const dirs = listing.entries.filter((e) => e.is_dir && parseClaudeProjectDir(e.name)).slice(0, limit);
  const found = await mapLimit<FsEntry, DiscoveredProject | null>(dirs, 4, async (entry) => {
    const sessionsDir = listing.path.endsWith(sep) ? listing.path + entry.name : listing.path + sep + entry.name;
    const [inside, path] = await Promise.all([
      fs.list(sessionsDir).catch(() => null),
      resolveClaudeProjectDir(entry.name, fs.stat),
    ]);
    if (!path) return null;
    const sessions = (inside?.entries || []).filter((e) => !e.is_dir && e.name.endsWith('.jsonl')).length;
    if (sessions === 0) return null;
    return { name: lastSegment(path), path, sessions, source: 'Claude Code' };
  });
  const byPath = new Map<string, DiscoveredProject>();
  for (const project of found) if (project && !byPath.has(project.path)) byPath.set(project.path, project);
  return [...byPath.values()].sort((a, b) => b.sessions - a.sessions || a.name.localeCompare(b.name));
}

/** Drop the discovered folders that are already a project on this bridge. */
export function newProjectsOnly(found: DiscoveredProject[], existing: any[] | null | undefined, bridgeId: string): DiscoveredProject[] {
  const norm = (p: string) => p.replace(/[\\/]+$/, '');
  const taken = new Set<string>();
  for (const project of Array.isArray(existing) ? existing : []) {
    for (const bp of Array.isArray(project?.bridge_paths) ? project.bridge_paths : []) {
      if (String(bp?.bridge_id || '') === bridgeId && bp?.path) taken.add(norm(String(bp.path)));
    }
    if (project?.default_path) taken.add(norm(String(project.default_path)));
  }
  return found.filter((p) => !taken.has(norm(p.path)));
}
