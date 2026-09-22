/**
 * shellModel — the Shells pages' shared vocabulary.
 * ------------------------------------------------------------------
 * Inherited silently from actionModel/agentModel; only what DIFFERS is remarked.
 * A **shell session** is a live process the bridge is running on a host — started by
 * an agent, by `ham-ctl shell`, or by a chain — not something a person creates in the
 * UI. Everything below was verified in source; the citations are load-bearing.
 *
 * What differs for this resource, and why:
 *
 *  1. **No create, no edit (REQ-UI-15).** Sessions are runtime. The single mutable
 *     field, `server_port`, is a menu item plus the existing `SetShellPortDialog`,
 *     not a form page. §7 of the plan template is N/A here and deliberately so.
 *
 *  2. **The row's bottom-right time switches field with the row's own state.**
 *     A live session's meaningful time is `last_activity_at` — when it last spoke.
 *     A terminal one's is `finished_at` — when it stopped; its activity clock froze
 *     at that moment and reading it as "active 4h ago" would imply a process that is
 *     not there. `started_at` is the absolute in the `title` for both. Every other
 *     resource has one time field; this one honestly has two.
 *
 *  3. **Tabs are Live | Finished**, the `shell_session_is_terminal` split
 *     (`src/hub/domain/shell_session.odin:51`). Status itself is not a tab: a session
 *     moves starting -> running -> exited while it is being read, and a status tab
 *     would carry rows out from under the reader. The terminal split is the one line
 *     a row crosses exactly once.
 *
 *  4. **Verbs are asymmetric across that split, because the HUB is asymmetric** and
 *     this was checked rather than assumed:
 *       - kill    409s on a terminal session — `shell_session_service.odin:236`,
 *                 "session has already terminated". So Kill is not offered there.
 *       - signal  has NO terminal guard (`:249`) but a signal to a dead pid is a
 *                 no-op, so Interrupt is not offered there either.
 *       - restart has NO terminal guard (`:268`) and IS meaningful there — it is the
 *                 main reason to want it. It can still fail, because the bridge looks
 *                 the session up in an IN-MEMORY map (`hub_runtime_client.odin:2414`)
 *                 that a bridge restart empties. That failure gets its own copy
 *                 (`restartFailureText`) rather than a generic "Restart failed",
 *                 which would leave a user retrying something that cannot succeed.
 *       - port    is a property of a live session; the hub refuses it once terminal.
 *
 *  5. **No markdown anywhere.** REQ-UI-11 says a view page renders markdown "where the
 *     field is markdown". A shell has no such field — its body is a byte stream, and
 *     rendering a stream as markdown would mangle it. Read-only here means the user
 *     WATCHES output and cannot type into it: `/shells/:id/input` and `/resize` exist
 *     and these pages never call them.
 */
import { buildRouteHash } from '../../utils/appLocation';
import type { IconName, Tone } from '@ui';
import type { ShellSession, ShellSessionKind, ShellSessionStatus, ShellStatusFilter } from '../../api/endpoints/shells';

/* ------------------------------------------------------------------ *
 * Status
 * ------------------------------------------------------------------ */

/** Mirrors `shell_session_is_terminal` (src/hub/domain/shell_session.odin:51). */
const TERMINAL_STATUSES: ReadonlySet<ShellSessionStatus> = new Set<ShellSessionStatus>([
  'exited',
  'killed',
  'failed',
]);

export function isTerminal(session: Pick<ShellSession, 'status'>): boolean {
  return TERMINAL_STATUSES.has(session.status);
}

export function statusLabel(status: ShellSessionStatus): string {
  switch (status) {
    case 'starting': return 'Starting';
    case 'running': return 'Running';
    case 'exited': return 'Exited';
    case 'killed': return 'Killed';
    case 'failed': return 'Failed';
    default: return status;
  }
}

export function statusTone(status: ShellSessionStatus): Tone {
  switch (status) {
    case 'running': return 'success';
    case 'starting': return 'warning';
    case 'killed':
    case 'failed': return 'danger';
    case 'exited':
    default: return 'neutral';
  }
}

export function kindLabel(kind: ShellSessionKind): string {
  switch (kind) {
    case 'agent': return 'Agent';
    case 'interactive': return 'Interactive';
    case 'server': return 'Server';
    case 'command': return 'Command';
    default: return kind;
  }
}

export const KIND_FILTER_OPTIONS: { value: ShellSessionKind; label: string }[] = [
  { value: 'agent', label: 'Agent' },
  { value: 'interactive', label: 'Interactive' },
  { value: 'server', label: 'Server' },
  { value: 'command', label: 'Command' },
];

/* ------------------------------------------------------------------ *
 * Tabs
 * ------------------------------------------------------------------ */

export type ShellTab = 'live' | 'finished';

export const SHELL_TABS: { value: ShellTab; label: string }[] = [
  { value: 'live', label: 'Live' },
  { value: 'finished', label: 'Finished' },
];

export function matchesTab(session: ShellSession, tab: ShellTab): boolean {
  return isTerminal(session) === (tab === 'finished');
}

/**
 * The statuses a tab can contain. The Status filter offers only these, because a
 * Status of "exited" under the Live tab is a filter that can only ever return nothing
 * — the same "offer only the verbs that mean something in this state" rule the row
 * menu follows, applied to a filter.
 */
export function statusOptionsForTab(tab: ShellTab): { value: ShellSessionStatus; label: string }[] {
  return tab === 'live'
    ? [
        { value: 'starting', label: 'Starting' },
        { value: 'running', label: 'Running' },
      ]
    : [
        { value: 'exited', label: 'Exited' },
        { value: 'killed', label: 'Killed' },
        { value: 'failed', label: 'Failed' },
      ];
}

/**
 * The single `status` value to send for a given tab + Status filter. The tab is the
 * composite (`live`/`finished`); an explicit Status narrows it to one exact value.
 * One value, never a CSV — Amendment 8: the hub honours only the first token of a
 * CSV filter, so sending one would display three chips and apply one.
 */
export function statusParamFor(tab: ShellTab, status: ShellSessionStatus | ''): ShellStatusFilter {
  return status || tab;
}

/* ------------------------------------------------------------------ *
 * Verbs
 * ------------------------------------------------------------------ */

export type ShellVerb = 'preview' | 'copy-url' | 'set-port' | 'interrupt' | 'restart' | 'kill';

export const VERB_LABEL: Record<ShellVerb, string> = {
  preview: 'Open preview',
  'copy-url': 'Copy access URL',
  'set-port': 'Set server port…',
  interrupt: 'Interrupt (SIGINT)',
  restart: 'Restart',
  kill: 'Kill',
};

/**
 * Icons are distinct per tone so a destructive verb is never one ambiguous glyph away
 * from a constructive one (Amendment 6). Inside a menu these ride BESIDE the label,
 * never instead of it.
 */
export const VERB_ICON: Record<ShellVerb, IconName> = {
  preview: 'eye',
  'copy-url': 'copy',
  'set-port': 'gear',
  interrupt: 'zap',
  restart: 'refresh',
  kill: 'stop',
};

export function isDestructive(verb: ShellVerb): boolean {
  return verb === 'kill';
}

/** T11-UI-5 / XM-8: reachable exactly when the hub has a live port to proxy. */
export function canPreview(session: ShellSession): boolean {
  return session.status === 'running' && session.server_port > 0;
}

/**
 * Offer only the verbs that mean something in this state — see the header for the
 * hub citation behind every exclusion.
 */
export function verbsForSession(session: ShellSession): ShellVerb[] {
  if (isTerminal(session)) {
    // Restart is the only verb a dead session can still honour. Kill 409s, a signal
    // reaches no pid, a port cannot be declared, and there is nothing to preview.
    return ['restart'];
  }
  const verbs: ShellVerb[] = [];
  if (canPreview(session)) verbs.push('preview', 'copy-url');
  verbs.push('set-port', 'interrupt', 'restart', 'kill');
  return verbs;
}

/**
 * Whether the preview affordance applies to this session at all, as distinct from
 * whether it can be used right now. Inherited from `ShellsPanel` (:53-57) with its
 * reasoning intact: a LIVE session without a port is transiently unreachable — the
 * port can still be declared, and the verb that declares it sits in the same menu —
 * so the control is shown disabled with the reason. A TERMINAL portless session is
 * permanently unreachable, and a permanently disabled control would lie about being
 * actionable, so nothing is rendered.
 */
export function hasPreviewAffordance(session: ShellSession): boolean {
  return session.server_port > 0 || !isTerminal(session);
}

export function previewUnavailableReason(session: ShellSession): string {
  if (canPreview(session)) return '';
  if (isTerminal(session)) return `This session ${session.status} — there is nothing left to preview.`;
  if (session.server_port <= 0) return 'No port declared yet. Set one from the menu and the preview opens.';
  return `The session is ${session.status}; the preview opens once it is running.`;
}

/**
 * The browser-openable preview URL: the hub's own preview path, made absolute against
 * the origin the UI is served from. Deliberately NOT the bridge-local proxy URL from
 * `ham-ctl shell --help` — that one only resolves from a process on the bridge host
 * and would be dead text in a browser.
 */
export function previewAccessUrl(session: ShellSession): string {
  const origin = typeof window === 'undefined' ? '' : window.location.origin;
  return `${origin}/api/v1/preview/${encodeURIComponent(session.session_id)}/`;
}

/* ------------------------------------------------------------------ *
 * Confirm + failure copy
 * ------------------------------------------------------------------ *
 * REQ-UI-18, proportional: the three verbs are NOT equally destructive.
 *   Interrupt — no confirm. SIGINT to a dev server is routine and recoverable, and a
 *     confirm on a routine act trains people to dismiss confirms.
 *   Restart   — confirms only while the session is LIVE, where it destroys running
 *     work. Restarting something already dead destroys nothing, so it asks nothing.
 *   Kill      — always confirms.
 */

export function needsConfirm(session: ShellSession, verb: ShellVerb): boolean {
  if (verb === 'kill') return true;
  if (verb === 'restart') return !isTerminal(session);
  return false;
}

export function confirmTitle(session: ShellSession, verb: ShellVerb): string {
  const name = shellTitle(session);
  return verb === 'kill' ? `Kill "${name}"?` : `Restart "${name}"?`;
}

export function confirmBody(session: ShellSession, verb: ShellVerb): string {
  if (verb === 'kill') {
    return 'The process is terminated immediately and anything it was doing is lost. Its output stays readable afterwards.';
  }
  return 'The running process is stopped and re-spawned with the same command and working directory. Anything it was part-way through is lost.';
}

export function bulkKillTitle(count: number): string {
  return count === 1 ? 'Kill 1 session?' : `Kill ${count} sessions?`;
}

/**
 * The bulk confirm names what it will act on AND what it will skip. A selection can
 * contain rows that have terminated since they were ticked — the hub 409s on those —
 * so saying "3 of these 5 have already finished and will be left alone" before the
 * fact is better than reporting three failures after it.
 */
export function bulkKillBody(names: string[], skipped: number): string {
  const subject = names.length === 1 ? `"${names[0]}"` : `${names.length} sessions`;
  const head = `Killing ${subject} terminates ${names.length === 1 ? 'its process' : 'their processes'} immediately. Their output stays readable afterwards.`;
  if (skipped <= 0) return head;
  return `${head} ${skipped} selected ${skipped === 1 ? 'session has' : 'sessions have'} already finished and will be left alone.`;
}

/**
 * Why a restart failed, in words that tell the user whether to retry.
 *
 * The bridge resolves a restart against an IN-MEMORY session map
 * (`hub_runtime_client.odin:2414`); a bridge that has restarted since the session
 * died no longer holds it, replies `ok:false`, and the hub turns that into
 * "bridge failed to restart shell session" (`shell_session_service.odin:290`).
 * That is a permanent condition for this session, so the copy says so instead of
 * inviting a retry that cannot work. Anything else keeps the server's own words.
 */
export function restartFailureText(err: unknown): string {
  const raw = shellErrorText(err, '');
  if (/failed to restart shell session/i.test(raw)) {
    return "This session's bridge no longer has it, so it can't be restarted. Start a new shell instead.";
  }
  return raw || "Heimdall couldn't reach the bridge to restart this session.";
}

/* ------------------------------------------------------------------ *
 * Display helpers
 * ------------------------------------------------------------------ */

/** The row title. Unlike an action, a shell HAS a name field; `cmd` is the fallback. */
export function shellTitle(session: Pick<ShellSession, 'label' | 'cmd' | 'session_id'> | null | undefined): string {
  const label = String(session?.label || '').trim();
  if (label) return label;
  const cmd = String(session?.cmd || '').trim();
  if (cmd) return cmd;
  return String(session?.session_id || 'Untitled session');
}

/**
 * The two reserved body lines: the command, then the working directory. Both are
 * paths and shell strings rather than prose — long, unbroken, and meaningful at both
 * ends — so the row truncates them and keeps the full text in a `title`.
 * The command is omitted when it IS the title, so a label-less row does not say the
 * same thing twice.
 */
export function shellBodyLines(session: ShellSession): { cmd: string; cwd: string } {
  const cmd = String(session.cmd || '').trim();
  const usedAsTitle = !String(session.label || '').trim() && Boolean(cmd);
  return {
    cmd: usedAsTitle ? '' : cmd,
    cwd: String(session.cwd || '').trim(),
  };
}

export function absoluteTime(iso?: string): string {
  if (!iso) return '';
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  return new Date(ms).toLocaleString();
}

export function relativeTime(iso?: string): string {
  if (!iso) return '';
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  const delta = Date.now() - ms;
  if (delta < 45000) return 'just now';
  const mins = Math.floor(delta / 60000);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString();
}

/**
 * The row's bottom-right label. Which FIELD it reads depends on the row's own state —
 * see the header, point 2. Returns the text and the absolute form for its `title`.
 */
export function shellTimeLabel(session: ShellSession): { text: string; title: string } {
  const started = session.started_at ? `Started ${absoluteTime(session.started_at)}` : '';
  // The LAST resort is `started_at`, never the status word. `last_activity_at` and
  // `finished_at` are both optional in the envelope — a session the bridge has not
  // reported activity on since it was created comes back with an empty string — but
  // `started_at` is the repo's ORDER BY column and is therefore always populated.
  // Falling back to the status instead printed a word that merely repeated the pill
  // immediately to its left and gave the slot's only job — when — to nobody.
  const fallback = relativeTime(session.started_at);
  if (isTerminal(session)) {
    const iso = session.finished_at || session.last_activity_at;
    const when = relativeTime(iso);
    const verb = statusLabel(session.status).toLowerCase();
    return {
      text: when ? `${verb} ${when}` : fallback ? `started ${fallback}` : verb,
      title: [started, iso ? `Finished ${absoluteTime(iso)}` : ''].filter(Boolean).join(' · '),
    };
  }
  const when = relativeTime(session.last_activity_at);
  return {
    text: when ? `active ${when}` : fallback ? `started ${fallback}` : statusLabel(session.status).toLowerCase(),
    title: [started, session.last_activity_at ? `Last activity ${absoluteTime(session.last_activity_at)}` : '']
      .filter(Boolean)
      .join(' · '),
  };
}

/** The exit-code pill's text, or '' when there is no exit code to report. */
export function exitLabel(session: ShellSession): string {
  if (!session.exit_code_set || session.exit_code === null || session.exit_code === undefined) return '';
  return session.exit_code === 0 ? 'exit 0' : `exit ${session.exit_code}`;
}

export function exitTone(session: ShellSession): Tone {
  return session.exit_code === 0 ? 'neutral' : 'danger';
}

/* ------------------------------------------------------------------ *
 * Client-side search (REQ-UI-4)
 * ------------------------------------------------------------------ *
 * There is no `shell` scope in the hub's search (`src/hub/domain/search.odin:11`), so
 * this is the whole of it. Same shape as the Actions search: every whitespace-separated
 * term must appear somewhere in the row's searchable text, so narrowing by adding a
 * word is predictable. The reach is named in the placeholder and in the no-results
 * copy, because a search whose reach is invisible reads as "it isn't there".
 *
 * NOTE the honest limit, stated wherever the user can act on it: this searches the
 * sessions ALREADY LOADED, not the server's whole table. The list is keyset-paged, so
 * scrolling loads more and widens the reach.
 */
export function shellSearchableText(session: ShellSession): string {
  return [
    session.label,
    session.cmd,
    session.cwd,
    session.session_id,
    session.kind,
    session.status,
    session.server_port > 0 ? String(session.server_port) : '',
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
}

export function matchesQuery(session: ShellSession, query: string): boolean {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return true;
  const haystack = shellSearchableText(session);
  return terms.every((term) => haystack.includes(term));
}

/* ------------------------------------------------------------------ *
 * URL state (REQ-UI-17)
 * ------------------------------------------------------------------ */

export interface ShellListUrlState {
  tab: ShellTab | '';
  q: string;
  /** Exact status within the tab. Server-side (`status=`), single-select. */
  status: ShellSessionStatus | '';
  /** Server-side (`bridge_id=` / `project_id=`), single-select per Amendment 8. */
  bridge: string;
  project: string;
  /** CLIENT-side: `kind` is not a query parameter the list endpoint accepts. */
  kind: ShellSessionKind | '';
}

export const EMPTY_LIST_URL_STATE: ShellListUrlState = {
  tab: '',
  q: '',
  status: '',
  bridge: '',
  project: '',
  kind: '',
};

export function parseShellListUrl(search: string): ShellListUrlState {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = String(params.get('tab') || '');
  const status = String(params.get('status') || '');
  const kind = String(params.get('kind') || '');
  const validStatus = ['starting', 'running', 'exited', 'killed', 'failed'].includes(status);
  const validKind = KIND_FILTER_OPTIONS.some((entry) => entry.value === kind);
  return {
    tab: (SHELL_TABS.some((entry) => entry.value === tab) ? tab : '') as ShellTab | '',
    q: String(params.get('q') || ''),
    status: (validStatus ? status : '') as ShellSessionStatus | '',
    bridge: String(params.get('bridge') || ''),
    project: String(params.get('project') || ''),
    kind: (validKind ? kind : '') as ShellSessionKind | '',
  };
}

export function shellListSearch(state: ShellListUrlState): string {
  const params = new URLSearchParams();
  if (state.tab) params.set('tab', state.tab);
  if (state.q) params.set('q', state.q);
  if (state.status) params.set('status', state.status);
  if (state.bridge) params.set('bridge', state.bridge);
  if (state.project) params.set('project', state.project);
  if (state.kind) params.set('kind', state.kind);
  const query = params.toString();
  return query ? `?${query}` : '';
}

export function hasActiveFilters(state: ShellListUrlState): boolean {
  return Boolean(state.status || state.bridge || state.project || state.kind);
}

/** An active-VALUE count, not a count of filter controls (Amendment 6). */
export function activeFilterCount(state: ShellListUrlState): number {
  return [state.status, state.bridge, state.project, state.kind].filter(Boolean).length;
}

/* ------------------------------------------------------------------ *
 * Routes and breadcrumbs
 * ------------------------------------------------------------------ */

export const SHELL_LIST_PATH = '/shells';

export function shellListHref(state?: ShellListUrlState): string {
  return buildRouteHash(SHELL_LIST_PATH, state ? shellListSearch(state) : '');
}

/** The detail href carries the LIST's state, so opening a row does not reset the
 *  list underneath the user at >=1024 where both are on screen (Amendment 6). */
export function shellViewHref(sessionId: string, listState?: ShellListUrlState): string {
  return buildRouteHash(
    `${SHELL_LIST_PATH}/${encodeURIComponent(sessionId)}`,
    listState ? shellListSearch(listState) : '',
  );
}

export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

export function replaceListSearch(state: ShellListUrlState): void {
  window.history.replaceState(
    window.history.state,
    '',
    buildRouteHash(SHELL_LIST_PATH, shellListSearch(state)),
  );
}

export interface ShellCrumb {
  label: string;
  href?: string;
}

/** A list page is the root of its own section — one heading, no trail (Amendment 5). */
export function listCrumbs(): ShellCrumb[] {
  return [{ label: 'Shells' }];
}

export function detailCrumbs(title: string, session: ShellSession | null, listState?: ShellListUrlState): ShellCrumb[] {
  const tab: ShellTab = listState?.tab || (session && isTerminal(session) ? 'finished' : 'live');
  const label = SHELL_TABS.find((entry) => entry.value === tab)?.label || 'Live';
  const full: ShellListUrlState = { ...(listState || EMPTY_LIST_URL_STATE), tab };
  return [
    { label: 'Shells', href: shellListHref({ ...full, tab: '' }) },
    { label, href: shellListHref(full) },
    { label: title },
  ];
}

export function viewCrumbs(title: string, listState?: ShellListUrlState): ShellCrumb[] {
  return [{ label: 'Shells', href: shellListHref(listState) }, { label: title }];
}

/* ------------------------------------------------------------------ *
 * Scroll restoration
 * ------------------------------------------------------------------ */

const LAST_ROW_KEY = 'heimdall:shells:last-row';

export function rememberRow(sessionId: string): void {
  try {
    window.sessionStorage.setItem(LAST_ROW_KEY, sessionId);
  } catch {
    /* Private mode / blocked storage: restoration is a convenience, not a contract. */
  }
}

export function takeRememberedRow(): string {
  try {
    const value = window.sessionStorage.getItem(LAST_ROW_KEY) || '';
    window.sessionStorage.removeItem(LAST_ROW_KEY);
    return value;
  } catch {
    return '';
  }
}

/* ------------------------------------------------------------------ *
 * Errors
 * ------------------------------------------------------------------ */

export function shellErrorText(err: unknown, fallback = 'Something went wrong.'): string {
  if (!err) return fallback;
  const anyErr = err as any;
  const message = String(
    anyErr?.data?.error?.message || anyErr?.data?.error || anyErr?.error || anyErr?.message || '',
  ).trim();
  return message || fallback;
}
