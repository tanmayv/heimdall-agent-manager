/** Shared API v2 display, navigation and editable form model. */
import { buildRouteHash } from '../../utils/appLocation';
import type { Tone } from '@ui';
import type { Action, ActionTrigger, ActionTarget, CreateActionInput } from '../../api/endpoints/actions';
import { triggerSummary } from './scheduleUtils';

export type ActionState = 'enabled' | 'disabled';
export const actionState = (record: Pick<Action, 'enabled'>): ActionState => record.enabled ? 'enabled' : 'disabled';
export const stateLabel = (state: ActionState) => state === 'enabled' ? 'Enabled' : 'Disabled';
export const stateTone = (state: ActionState): Tone => state === 'enabled' ? 'success' : 'neutral';
export const STATE_FILTER_OPTIONS = [{ value: 'enabled' as const, label: 'Enabled' }, { value: 'disabled' as const, label: 'Disabled' }];
export type ActionTab = 'all' | 'scheduled' | 'event' | 'none';
export const ACTION_TABS: { value: ActionTab; label: string }[] = [{ value: 'all', label: 'All' }, { value: 'scheduled', label: 'Scheduled' }, { value: 'event', label: 'Event' }, { value: 'none', label: 'No trigger' }];
export const isScheduled = (record: Pick<Action, 'triggers'>) => record.triggers.some(t => t.kind === 'schedule');
export function matchesTab(record: Action, tab: ActionTab) {
  return tab === 'all' || (tab === 'none' ? !record.triggers.length : record.triggers.some(t => t.kind === (tab === 'scheduled' ? 'schedule' : 'event')));
}
export type ActionVerb = 'edit' | 'delete';
export const VERB_LABEL = { edit: 'Edit', delete: 'Delete' };
export const verbsForState = (_state: ActionState): ActionVerb[] => ['edit', 'delete'];
export const deleteConfirmBody = (titles: string[]) => 'Delete ' + titles.join(', ') + '? This permanently removes their triggers and run history.';
export function actionTitle(record: Pick<Action, 'prompt_text'> & Partial<Pick<Action, 'name'>> | null | undefined) {
  return record?.name?.trim() || record?.prompt_text.split('\n').find(line => line.trim())?.trim() || 'Untitled action';
}
export const actionSnippet = (record: Pick<Action, 'prompt_text'>) => record.prompt_text;
export const scheduleLabel = (record: Pick<Action, 'triggers'>) => record.triggers.map(triggerSummary).join(' · ') || 'No trigger';
export const absoluteTime = (iso?: string) => iso ? (Number.isFinite(Date.parse(iso)) ? new Date(iso).toLocaleString() : iso) : '—';
export const absoluteRun = (iso?: string, _timezone?: string) => absoluteTime(iso);
export const relativeTime = absoluteTime;
export function nextRunLabel(record: Action) {
  const iso = record.triggers.map(t => t.next_fire_at || '').filter(Boolean).sort()[0];
  return { text: iso ? absoluteTime(iso) : '', title: iso ? 'Next fire ' + iso : '' };
}
export const targetMode = (record: Action) => record.target.kind;

export interface ActionListUrlState {
  tab: ActionTab | '';
  q: string;
  /** Filters. All client-side — the whole list is loaded, so there is no query param
   *  to back them with, and single-select per Amendment 8. */
  state: ActionState | '';
  project: string;
  bridge: string;
}

export const EMPTY_LIST_URL_STATE: ActionListUrlState = { tab: '', q: '', state: '', project: '', bridge: '' };

export function parseActionListUrl(search: string): ActionListUrlState {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = String(params.get('tab') || '');
  const state = String(params.get('state') || '');
  return {
    tab: (ACTION_TABS.some((entry) => entry.value === tab) ? tab : '') as ActionTab | '',
    q: String(params.get('q') || ''),
    state: (STATE_FILTER_OPTIONS.some((entry) => entry.value === state) ? state : '') as ActionState | '',
    project: String(params.get('project') || ''),
    bridge: String(params.get('bridge') || ''),
  };
}

export function actionListSearch(state: ActionListUrlState): string {
  const params = new URLSearchParams();
  if (state.tab) params.set('tab', state.tab);
  if (state.q) params.set('q', state.q);
  if (state.state) params.set('state', state.state);
  if (state.project) params.set('project', state.project);
  if (state.bridge) params.set('bridge', state.bridge);
  const query = params.toString();
  return query ? `?${query}` : '';
}

export function hasActiveFilters(state: ActionListUrlState): boolean {
  return Boolean(state.state || state.project || state.bridge);
}

export function activeFilterCount(state: ActionListUrlState): number {
  return [state.state, state.project, state.bridge].filter(Boolean).length;
}

/* ------------------------------------------------------------------ *
 * Routes and breadcrumbs
 * ------------------------------------------------------------------ */

export const ACTION_LIST_PATH = '/actions';

export function actionListHref(state?: ActionListUrlState): string {
  return buildRouteHash(ACTION_LIST_PATH, state ? actionListSearch(state) : '');
}

export function actionViewHref(actionId: string, listState?: ActionListUrlState): string {
  return buildRouteHash(
    `${ACTION_LIST_PATH}/${encodeURIComponent(actionId)}`,
    listState ? actionListSearch(listState) : '',
  );
}

export function actionEditHref(actionId: string): string {
  return buildRouteHash(`${ACTION_LIST_PATH}/${encodeURIComponent(actionId)}/edit`, '');
}

export function actionNewHref(): string {
  return buildRouteHash(`${ACTION_LIST_PATH}/new`, '');
}

export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

export function replaceListSearch(state: ActionListUrlState): void {
  window.history.replaceState(
    window.history.state,
    '',
    buildRouteHash(ACTION_LIST_PATH, actionListSearch(state)),
  );
}

export interface ActionCrumb {
  label: string;
  href?: string;
}

/** A list page is the root of its own section — one heading, no trail (Amendment 5). */
export function listCrumbs(): ActionCrumb[] {
  return [{ label: 'Actions' }];
}

export function detailCrumbs(title: string, record: Action | null, listState?: ActionListUrlState): ActionCrumb[] {
  const tab: ActionTab = listState?.tab || (record && isScheduled(record) ? 'scheduled' : 'none');
  const label = ACTION_TABS.find((entry) => entry.value === tab)?.label || 'Scheduled';
  const full: ActionListUrlState = { ...(listState || EMPTY_LIST_URL_STATE), tab };
  return [
    { label: 'Actions', href: actionListHref({ ...full, tab: '' }) },
    { label, href: actionListHref(full) },
    { label: title },
  ];
}

export function viewCrumbs(title: string, listState?: ActionListUrlState): ActionCrumb[] {
  return [{ label: 'Actions', href: actionListHref(listState) }, { label: title }];
}

export function newCrumbs(listState?: ActionListUrlState): ActionCrumb[] {
  return [{ label: 'Actions', href: actionListHref(listState) }, { label: 'New action' }];
}

export function editCrumbs(title: string, actionId: string, listState?: ActionListUrlState): ActionCrumb[] {
  return [
    { label: 'Actions', href: actionListHref(listState) },
    { label: title, href: actionViewHref(actionId) },
    { label: 'Edit' },
  ];
}

/* ------------------------------------------------------------------ *
 * Scroll restoration
 * ------------------------------------------------------------------ */

const LAST_ROW_KEY = 'heimdall:actions:last-row';

export function rememberRow(actionId: string): void {
  try {
    window.sessionStorage.setItem(LAST_ROW_KEY, actionId);
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

export function actionErrorText(err: unknown, fallback = 'Something went wrong.'): string {
  if (!err) return fallback;
  const anyErr = err as any;
  const message = String(
    anyErr?.data?.error?.message || anyErr?.data?.error || anyErr?.error || anyErr?.message || '',
  ).trim();
  return message || fallback;
}

/* ------------------------------------------------------------------ *
 * The form
 * ------------------------------------------------------------------ */


export type FormTrigger = ActionTrigger & { clientKey?: string };
export type ActionForm = { name: string; prompt_text: string; enabled: boolean; min_interval_s: number; target: ActionTarget; triggers: FormTrigger[] };
export function emptyActionForm(defaultInterval = 30): ActionForm {
  return { name: '', prompt_text: '', enabled: true, min_interval_s: defaultInterval, target: { kind: 'agent', agent_id: '', project_id: '', instance_strategy: 'reuse', selector: 'first', rules: [] }, triggers: [] };
}
export function formFromAction(action: Action): ActionForm {
  const { name, prompt_text, enabled, min_interval_s, target, triggers } = action;
  return structuredClone({ name, prompt_text, enabled, min_interval_s, target, triggers });
}
export function actionFormBody(form: ActionForm): CreateActionInput {
  const target = structuredClone(form.target);
  if (target.kind === 'agent') delete target.last_spawned_instance_id;
  return { ...form, target, triggers: form.triggers.map(({ id, kind, config, enabled }) => ({ ...(id ? { id } : {}), kind, config: structuredClone(config), enabled } as ActionTrigger)) };
}
export type ActionFormField = 'prompt_text' | 'min_interval_s' | 'target' | 'triggers' | 'form';
export function mapServerError(err: any): { field: ActionFormField; message: string } {
  const details = err?.data?.details;
  let parsed = details;
  if (typeof details === 'string') { try { parsed = JSON.parse(details); } catch { parsed = {}; } }
  const code = String(parsed?.code || err?.data?.code || '');
  const field: ActionFormField = code === 'prompt_required' ? 'prompt_text'
    : code === 'min_interval_out_of_range' ? 'min_interval_s'
    : /target|strategy|selector|rule|candidate|bridge|provider|model/.test(code) ? 'target'
    : /trigger|cron|timezone|schedule|event|chain|interval|run_at|blackout|window|active_/.test(code) ? 'triggers' : 'form';
  return { field, message: actionErrorText(err) };
}

export function actionMessageContext(metadata: unknown) {
  let meta: any = metadata;
  if (typeof meta === 'string') { try { meta = JSON.parse(meta); } catch { meta = {}; } }
  if (!meta || typeof meta !== 'object') meta = {};
  return { eventType: String(meta.event_type || ''), actionName: String(meta.action_name || ''), movedTo: String(meta.moved_to_instance_id || ''), joinedCount: Number(meta.joined_count) || 0, triggeredAt: String(meta.triggered_at || '') };
}
