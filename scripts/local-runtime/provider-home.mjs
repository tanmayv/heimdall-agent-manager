#!/usr/bin/env node
// Seed an isolated provider home for one local bridge instance (REQ-ISOHOME-2).
//
//   node scripts/local-runtime/provider-home.mjs seed --real-home <dir> --home <dir>
//        [--providers claude,codex,gemini,pi,git] [--trust-root <abs-path>]...
//
// An isolated local bridge runs every provider CLI with HOME=<instance>/home, so
// extensions installed from a local or preview hub land there and never in the
// developer's real ~/.claude, ~/.codex, ... This copies in what a provider needs to
// start already signed in and without first-run dialogs: auth files, account and
// onboarding state, the consent to skip permission prompts, and per-project trust.
// Plugins, marketplaces, hooks, history and sessions are NOT copied, so the instance
// starts with no extensions.
//
// The real home is only ever read. Re-running (`local-bridge.sh reseed-auth`)
// re-applies the real values on top of the instance's files and keeps what the
// instance added itself (its installed extensions, its own project trust). Every
// file written is recorded in <home>/.heimdall-home-manifest.json with the source
// path and both checksums, so a test can prove the real home is untouched.
//
// Provider OAuth refresh tokens may rotate on use: a copy that refreshes can end
// the real CLI's session, or the other way round. When that happens, sign in again
// on the real side and reseed. Env credentials (ANTHROPIC_API_KEY,
// CLAUDE_CODE_OAUTH_TOKEN, OPENAI_API_KEY) are passed through by the launcher and
// avoid the problem entirely.
import { createHash } from 'node:crypto';
import {
  chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, realpathSync, renameSync,
  rmSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MANIFEST = '.heimdall-home-manifest.json';

// claude: .claude.json keys that carry the signed-in account and skip onboarding.
const CLAUDE_JSON_KEYS = [
  'oauthAccount', 'userID', 'hasCompletedOnboarding', 'lastOnboardingVersion',
  'customApiKeyResponses', 'bypassPermissionsModeAccepted', 'migrationVersion',
  'opusProMigrationComplete', 'sonnet1m45MigrationComplete', 'firstStartTime',
];
// claude: settings.json keys that select plugins; the instance keeps its own.
const CLAUDE_PLUGIN_SETTINGS = ['enabledPlugins', 'extraKnownMarketplaces'];
// codex: config.toml tables that belong to installed plugins.
const CODEX_PLUGIN_TABLE = /^\[(plugins|marketplaces|hooks\.state)([.\]])/;

// Per provider: the files seeded. kind copy = verbatim (symlinks into a read-only
// store, e.g. home-manager's /nix/store files, are recreated as symlinks); the
// filter kinds merge real values into the instance's file.
export const PROVIDERS = {
  claude: [
    { path: '.claude/.credentials.json', kind: 'copy' },
    { path: '.claude.json', kind: 'claude-json' },
    { path: '.claude/settings.json', kind: 'claude-settings' },
    { path: '.claude/CLAUDE.md', kind: 'copy' },
  ],
  codex: [
    { path: '.codex/auth.json', kind: 'copy' },
    { path: '.codex/config.toml', kind: 'codex-toml' },
    { path: '.codex/AGENTS.md', kind: 'copy' },
  ],
  // gemini CLI and Antigravity (agy) share ~/.gemini.
  gemini: [
    { path: '.gemini/oauth_creds.json', kind: 'copy' },
    { path: '.gemini/google_accounts.json', kind: 'copy' },
    { path: '.gemini/settings.json', kind: 'copy' },
    { path: '.gemini/config/config.json', kind: 'copy' },
    { path: '.gemini/antigravity-cli/antigravity-oauth-token', kind: 'copy' },
    { path: '.gemini/antigravity-cli/settings.json', kind: 'copy' },
    { path: '.gemini/hooks.json', kind: 'copy' },
    { path: '.gemini/GEMINI.md', kind: 'copy' },
    { path: '.gemini/CLAUDE.md', kind: 'copy' },
    { path: '.gemini/CODEX.md', kind: 'copy' },
    { path: '.gemini/PI.md', kind: 'copy' },
  ],
  pi: [
    { path: '.pi/agent/auth.json', kind: 'copy' },
    { path: '.pi/agent/settings.json', kind: 'copy' },
  ],
  // git keeps working for agents: identity, ignore rules and https credentials.
  // ssh remotes use the developer's agent (SSH_AUTH_SOCK is passed through).
  git: [
    { path: '.gitconfig', kind: 'copy' },
    { path: '.config/git/config', kind: 'copy' },
    { path: '.config/git/ignore', kind: 'copy' },
    { path: '.git-credentials', kind: 'copy' },
    { path: '.config/gh/hosts.yml', kind: 'copy' },
    { path: '.config/gh/config.yml', kind: 'copy' },
  ],
};
export const ALL_PROVIDERS = Object.keys(PROVIDERS);

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

function writeAtomic(file, data) {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp-${process.pid}`;
  writeFileSync(tmp, data, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
}

/** claude .claude.json: account/onboarding/consent keys + project trust flags. */
export function mergeClaudeJson(real, current, trustRoots = []) {
  const out = { ...current };
  for (const key of CLAUDE_JSON_KEYS) if (key in real) out[key] = real[key];
  const projects = { ...(current.projects || {}) };
  const trusted = Object.entries(real.projects || {})
    .filter(([, p]) => p && p.hasTrustDialogAccepted === true).map(([path]) => path);
  for (const path of [...trusted, ...trustRoots]) {
    projects[path] = { ...(projects[path] || {}), hasTrustDialogAccepted: true };
  }
  out.projects = projects;
  return out;
}

/** claude settings.json: the real settings, but the instance's own plugin selection. */
export function mergeClaudeSettings(real, current) {
  const out = { ...real };
  for (const key of CLAUDE_PLUGIN_SETTINGS) {
    delete out[key];
    if (key in current) out[key] = current[key];
  }
  return out;
}

/** Split TOML text into a preamble and [table] blocks (header line + body). */
function tomlBlocks(text) {
  const blocks = [{ header: '', lines: [] }];
  for (const line of text.split('\n')) {
    if (/^\s*\[/.test(line)) blocks.push({ header: line.trim(), lines: [line] });
    else blocks[blocks.length - 1].lines.push(line);
  }
  return blocks;
}

/**
 * codex config.toml: the real config without its plugin tables, plus the
 * instance's own plugin tables and any project trust the instance added.
 * trustRoots get [projects."<path>"] trust_level = "trusted".
 */
export function mergeCodexToml(realText, currentText = '', trustRoots = []) {
  const real = tomlBlocks(realText).filter((b) => !CODEX_PLUGIN_TABLE.test(b.header));
  const headers = new Set(real.map((b) => b.header));
  const kept = tomlBlocks(currentText).filter((b) => b.header
    && (CODEX_PLUGIN_TABLE.test(b.header) || (/^\[projects\./.test(b.header) && !headers.has(b.header))));
  for (const b of kept) headers.add(b.header);
  const extra = trustRoots
    .map((path) => `[projects.${JSON.stringify(path)}]`)
    .filter((h) => !headers.has(h))
    .map((h) => ({ header: h, lines: [h, 'trust_level = "trusted"', ''] }));
  const body = [...real, ...kept, ...extra].map((b) => b.lines.join('\n')).join('\n');
  return body.endsWith('\n') ? body : `${body}\n`;
}

/** A symlink whose target is outside the real home (e.g. /nix/store) is immutable. */
function storeLinkTarget(src, realHome) {
  if (!lstatSync(src).isSymbolicLink()) return '';
  const raw = readlinkSync(src);
  const target = isAbsolute(raw) ? raw : resolve(dirname(src), raw);
  const rel = relative(realHome, target);
  return rel.startsWith('..') || isAbsolute(rel) ? target : '';
}

/**
 * seed({ realHome, home, providers, trustRoots }) -> manifest. Reads realHome only.
 */
export function seed({ realHome, home, providers = ALL_PROVIDERS, trustRoots = [] }) {
  const realAbs = resolve(realHome);
  const homeAbs = resolve(home);
  if (realAbs === homeAbs || !relative(homeAbs, realAbs).startsWith('..')) {
    throw new Error(`refusing to seed: home ${homeAbs} is the real home or contains it`);
  }
  for (const p of providers) if (!PROVIDERS[p]) throw new Error(`unknown provider '${p}' (${ALL_PROVIDERS.join(', ')})`);
  mkdirSync(homeAbs, { recursive: true, mode: 0o700 });
  const files = [];
  for (const provider of providers) {
    for (const { path, kind } of PROVIDERS[provider]) {
      const src = join(realAbs, path);
      const dst = join(homeAbs, path);
      if (!existsSync(src)) continue;
      const srcBytes = readFileSync(src);
      const link = kind === 'copy' ? storeLinkTarget(src, realAbs) : '';
      mkdirSync(dirname(dst), { recursive: true, mode: 0o700 });
      if (link) {
        rmSync(dst, { force: true });
        symlinkSync(link, dst);
      } else if (kind === 'copy') {
        writeAtomic(dst, srcBytes);
      } else {
        const current = existsSync(dst) && !lstatSync(dst).isSymbolicLink() ? readFileSync(dst, 'utf8') : '';
        let text;
        if (kind === 'claude-json') {
          text = `${JSON.stringify(mergeClaudeJson(JSON.parse(srcBytes), current ? JSON.parse(current) : {}, trustRoots), null, 2)}\n`;
        } else if (kind === 'claude-settings') {
          text = `${JSON.stringify(mergeClaudeSettings(JSON.parse(srcBytes), current ? JSON.parse(current) : {}), null, 2)}\n`;
        } else if (kind === 'codex-toml') {
          text = mergeCodexToml(srcBytes.toString('utf8'), current, trustRoots);
        } else {
          throw new Error(`unknown kind ${kind}`);
        }
        if (existsSync(dst) && lstatSync(dst).isSymbolicLink()) rmSync(dst);
        writeAtomic(dst, text);
      }
      files.push({
        provider, path, kind: link ? 'link' : kind, source: src,
        source_sha256: sha256(srcBytes), sha256: sha256(readFileSync(dst)),
        ...(link ? { target: link } : {}),
      });
    }
  }
  // A reseed of some providers keeps the record of the others it did not touch.
  const manifestPath = join(homeAbs, MANIFEST);
  const previous = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')).files || [] : [];
  const allFiles = [...previous.filter((f) => !providers.includes(f.provider)), ...files];
  const manifest = {
    version: 1, real_home: realAbs, home: homeAbs, seeded_at: new Date().toISOString(),
    providers: [...new Set(allFiles.map((f) => f.provider))], requested: providers, files: allFiles,
  };
  writeAtomic(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

function main(argv) {
  const [cmd, ...rest] = argv;
  const a = { 'trust-root': [] };
  for (let i = 0; i < rest.length; i += 2) {
    const key = rest[i].replace(/^--/, '');
    if (key === 'trust-root') a[key].push(rest[i + 1]); else a[key] = rest[i + 1];
  }
  if (cmd !== 'seed') throw new Error('usage: provider-home.mjs seed --real-home <dir> --home <dir> [--providers a,b] [--trust-root <path>]...');
  for (const k of ['real-home', 'home']) if (!a[k]) throw new Error(`missing --${k}`);
  const providers = a.providers ? a.providers.split(',').map((s) => s.trim()).filter(Boolean) : ALL_PROVIDERS;
  const m = seed({ realHome: a['real-home'], home: a.home, providers, trustRoots: a['trust-root'] });
  const by = Object.fromEntries(m.requested.map((p) => [p, m.files.filter((f) => f.provider === p).length]));
  console.log(`provider home: ${Object.entries(by).map(([p, n]) => `${p}=${n ? `${n} file${n === 1 ? '' : 's'}` : 'none found'}`).join(' ')}`);
}

if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  try { main(process.argv.slice(2)); } catch (err) { console.error(`provider-home: ${err.message}`); process.exit(1); }
}
