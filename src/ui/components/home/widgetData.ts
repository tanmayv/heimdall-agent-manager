import type { ChainListItem } from '../../api/endpoints/tasks';

export type WidgetResource<T> =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; data: T };
export type WidgetLoader<T> = (signal: AbortSignal) => Promise<T>;
export type ActivityMetric = 'tasks_completed' | 'active_chains' | 'agent_instances' | 'bridges_connected';
export const ACTIVITY_METRICS: { id: ActivityMetric; label: string; unit: string }[] = [
  { id: 'tasks_completed', label: 'Tasks completed', unit: 'tasks completed' },
  { id: 'active_chains', label: 'Active chains', unit: 'active chains' },
  { id: 'agent_instances', label: 'Agent instances', unit: 'agent instances' },
  { id: 'bridges_connected', label: 'Connected bridges', unit: 'connected bridges' },
];
export interface ActivityDay { date: string; value: number; future?: boolean }
export interface ActivityData {
  metric: ActivityMetric;
  kind: 'counter' | 'gauge';
  days: ActivityDay[];
  levels: number[];
  summary: { total?: number; average?: number; best: ActivityDay; activeDays: number; streakDays: number };
}

export function localDate(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}
export function dateFromKey(key: string): Date { return new Date(`${key}T12:00:00`); }
/** Values are supplied by the loader; the view never recomputes level edges. */
export function activityLevel(value: number, levels: number[]): number {
  if (value <= 0) return 0;
  let level = 1;
  for (let i = 1; i < Math.min(4, levels.length); i++) if (value > levels[i]) level = i + 1;
  return level;
}

export function summarizeActivity(days: ActivityDay[], kind: ActivityData['kind']): ActivityData['summary'] {
  const elapsed = days.filter((day) => !day.future);
  const total = elapsed.reduce((sum, day) => sum + day.value, 0);
  const best = elapsed.reduce((a, b) => b.value > a.value ? b : a, elapsed[0] || { date: '', value: 0 });
  let streakDays = 0;
  for (let i = elapsed.length - 1; i >= 0 && elapsed[i].value > 0; i--) streakDays++;
  return {
    ...(kind === 'counter' ? { total } : { average: elapsed.length ? total / elapsed.length : 0 }),
    best, activeDays: elapsed.filter((day) => day.value > 0).length, streakDays,
  };
}

/** Deterministic local-day fixture. Replace this loader when Activity ships its API. */
export function mockActivity(metric: ActivityMetric, today = new Date()): ActivityData {
  const end = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 12);
  end.setDate(end.getDate() + 6 - end.getDay());
  const days: ActivityDay[] = Array.from({ length: 371 }, (_, index) => {
    const date = new Date(end);
    date.setDate(date.getDate() - 370 + index);
    return { date: localDate(date), value: 0, future: localDate(date) > localDate(today) };
  });
  const last = days.findIndex((day) => day.date === localDate(today));
  const positive = new Set<number>();
  for (let i = 0; i < 141; i++) positive.add(Math.floor(i * (last - 9) / 141));
  for (let i = last - 6; i <= last; i++) positive.add(i);
  // Keep the fixture's busiest day separate from the current seven-day streak.
  positive.add(last - 9);
  for (const index of positive) days[index].value = 1;
  days[last - 9].value = 17;
  const ordered = [...positive].filter((index) => index !== last - 9);
  let remaining = 834 - days.reduce((sum, day) => sum + day.value, 0);
  for (let i = 0; remaining > 0; i++, remaining--) days[ordered[(i * 43) % ordered.length]].value++;
  if (metric !== 'tasks_completed') {
    const max = metric === 'active_chains' ? 7 : metric === 'agent_instances' ? 12 : 3;
    for (let i = 0; i <= last; i++) days[i].value = days[i].value ? 1 + (i * 5 % max) : 0;
  }
  const max = Math.max(...days.map((day) => day.value));
  const kind = metric === 'tasks_completed' ? 'counter' : 'gauge';
  return { metric, kind, days, levels: [0, max / 4, max / 2, max * 3 / 4, max], summary: summarizeActivity(days, kind) };
}
export const loadMockActivity = async (metric: ActivityMetric, _signal: AbortSignal): Promise<ActivityData> => mockActivity(metric);

export interface UptimeDay { date: string; state: 'up' | 'partial' | 'down' | 'none'; downSeconds: number }
export interface UptimeBridge {
  id: string; label: string; online: boolean; uptimePercent: number; connectedFor: string; incidents: number; days: UptimeDay[];
}
export interface UptimeData { connected: number; total: number; uptimePercent: number; bridges: UptimeBridge[] }
export function mockUptime(today = new Date()): UptimeData {
  const bridges = ['riverwood', 'dawnstar', 'kamsharm-mn4988.linkedin.biz'].map((label, index) => ({
    id: `mock-bridge-${index}`, label, online: true, uptimePercent: [99.91, 96.45, 100][index],
    connectedFor: ['4d 3h', '12d 6h', '21d 9h'][index], incidents: [1, 2, 0][index],
    days: Array.from({ length: 30 }, (_, day) => {
      const date = new Date(today); date.setDate(date.getDate() - 29 + day);
      const partial = index === 0 && day === 23 || index === 1 && day === 8;
      const down = index === 1 && day === 16;
      return { date: localDate(date), state: down ? 'down' as const : partial ? 'partial' as const : 'up' as const, downSeconds: down ? 86400 : partial ? (index ? 5616 : 2280) : 0 };
    }),
  }));
  return { connected: 3, total: 3, uptimePercent: 98.79, bridges };
}
export const loadMockUptime: WidgetLoader<UptimeData> = async () => mockUptime();

export const MOCK_PROVIDERS = [
  { id: 'claude', label: 'Claude Code', models: ['claude-opus-5-5', 'claude-sonnet-5-5'] },
  { id: 'codex', label: 'Codex', models: ['gpt-6.1-sol', 'gpt-6.1-terra'] },
];
export const MOCK_AGENTS = ['Worker', 'Reviewer', 'Coordinator', 'Assistant'];
export interface FleetOverride { id: string; agent: string; provider: string; model: string }
export interface FleetBridge { id: string; label: string; os: string; agents: number; online: boolean; provider: string; model: string; overrides: FleetOverride[] }
export const loadMockFleet: WidgetLoader<FleetBridge[]> = async () => [
  { id: 'mock-bridge-0', label: 'riverwood', os: 'Fedora Atomic', agents: 4, online: true, provider: 'claude', model: 'claude-opus-5-5',
    overrides: [
      { id: 'mock-worker', agent: 'Worker', provider: 'claude', model: 'claude-sonnet-5-5' },
      { id: 'mock-reviewer', agent: 'Reviewer', provider: 'codex', model: 'gpt-6.1-sol' },
    ] },
  { id: 'mock-bridge-1', label: 'dawnstar', os: 'macOS', agents: 2, online: true, provider: 'claude', model: 'claude-opus-5-5', overrides: [] },
  { id: 'mock-bridge-2', label: 'kamsharm-mn4988.linkedin.biz', os: 'macOS', agents: 1, online: true, provider: 'claude', model: 'claude-sonnet-5-5', overrides: [] },
];

export function activeWidgetChains(chains: ChainListItem[]): ChainListItem[] {
  return chains.filter((chain) => ['active', 'running', 'needs_review', 'in_review'].includes(chain.status.toLowerCase()))
    .sort((a, b) => (Date.parse(b.updatedAt) || 0) - (Date.parse(a.updatedAt) || 0) || a.chainId.localeCompare(b.chainId));
}
export function chainWidgetPage(chains: ChainListItem[], page: number) {
  const index = Math.max(0, Math.min(Math.trunc(page) || 0, Math.max(0, Math.ceil(chains.length / 3) - 1)));
  return { index, rows: chains.slice(index * 3, index * 3 + 3), start: chains.length ? index * 3 + 1 : 0, end: Math.min(index * 3 + 3, chains.length) };
}
export interface ChainProgress { total: number; done: number; review: number; progress: number }
export function chainProgress(tasks: { state?: string; status?: string }[]): ChainProgress {
  const count = (state: string) => tasks.filter((task) => (task.state || task.status) === state).length;
  return { total: tasks.length, done: count('done'), review: count('in_review'), progress: count('in_progress') };
}
