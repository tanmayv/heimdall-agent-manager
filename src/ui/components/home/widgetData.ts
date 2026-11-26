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

export interface UptimeDay { date: string; state: 'up' | 'partial' | 'down' | 'none'; downSeconds: number }
export interface UptimeBridge {
  id: string; label: string; online: boolean; uptimePercent: number; connectedFor: string; incidents: number; days: UptimeDay[];
}
export interface UptimeData { connected: number; total: number; uptimePercent: number; bridges: UptimeBridge[] }
export interface FleetOverride { id: string; agent: string; provider: string; provider_profile?: string; model: string }
export interface FleetBridge { id: string; label: string; os: string; agents: number; online: boolean; provider: string; provider_profile?: string; model: string; overrides: FleetOverride[]; availableAgents?: { agent_id: string; name: string }[]; catalog?: import('../tasks/fleetSelection').FleetProviderCapability[] }
export function activeWidgetChains(chains: ChainListItem[]): ChainListItem[] {
  return chains.filter((chain) => chain.status.toLowerCase() === 'active')
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

export interface ActivityWire {
  metric: ActivityMetric; kind: 'counter' | 'gauge'; tz: string; from: string; to: string; tracking_since: string;
  days: { date: string; value: number }[]; levels: number[];
  summary: { total?: number; avg?: number; best: ActivityDay; active_days: number; streak_days: number };
}
export interface UptimeWire {
  tz: string; window_days: number;
  fleet: { connected: number; total: number; uptime_pct: number };
  bridges: { bridge_id: string; label: string; status: string; connected_since: string; uptime_pct: number; incidents: number; days: { date: string; down_s: number; state: UptimeDay['state'] }[] }[];
}
export interface FleetWire {
  providers?: import('../tasks/fleetSelection').FleetProviderCapability[];
  bridges: { bridge_id: string; label: string; machine_os: string; status: string; agent_count: number }[];
  defaults: Record<string, { bridge_id: string; provider: string; model: string; updated_at: string }>;
  overrides: Record<string, { bridge_id: string; agent_id: string; provider: string; model: string; updated_at: string }[]>;
  agents: { bridge_id: string; agents: { agent_id: string; name: string }[] }[];
}
export interface HomeChainRow { chain_id: string; title: string; status: string; project_name: string; updated_at: string; user_validation_count?: number }
export interface HomeChainPage { chains: HomeChainRow[]; total: number; next_cursor: string }
export interface HomeChainDetail { chain_id: string; members: { role: string; display_name: string; bridge_id: string; bridge_label?: string }[]; tasks: { state: string }[] }

export function activityFromWire(data: ActivityWire): ActivityData {
  const end = dateFromKey(data.to); end.setDate(end.getDate() + 6 - end.getDay());
  const values = new Map(data.days.map((day) => [day.date, day.value]));
  const days = Array.from({ length: 371 }, (_, index) => {
    const date = new Date(end); date.setDate(date.getDate() - 370 + index);
    const key = localDate(date);
    return { date: key, value: values.get(key) || 0, future: key > data.to };
  });
  return { metric: data.metric, kind: data.kind, days, levels: data.levels, summary: { total: data.summary.total, average: data.summary.avg, best: data.summary.best, activeDays: data.summary.active_days, streakDays: data.summary.streak_days } };
}
export function uptimeFromWire(data: UptimeWire, today = new Date()): UptimeData {
  return {
    connected: data.fleet.connected, total: data.fleet.total, uptimePercent: data.fleet.uptime_pct,
    bridges: data.bridges.map((bridge) => {
      const hours = Math.max(0, Math.floor((today.getTime() - Date.parse(bridge.connected_since)) / 3600000));
      return {
        id: bridge.bridge_id, label: bridge.label, online: bridge.status === 'online', uptimePercent: bridge.uptime_pct, incidents: bridge.incidents,
        connectedFor: `${Math.floor(hours / 24)}d ${hours % 24}h`,
        days: Array.from({ length: data.window_days }, (_, index) => {
          const date = new Date(today); date.setDate(date.getDate() - data.window_days + 1 + index);
          const key = localDate(date); const day = bridge.days.find((item) => item.date === key);
          return { date: key, state: day?.state || 'up', downSeconds: day?.down_s || 0 };
        }),
      };
    }),
  };
}
export function fleetFromWire(data: FleetWire): FleetBridge[] {
  return data.bridges.map((bridge) => ({
    id: bridge.bridge_id, label: bridge.label, os: bridge.machine_os, online: bridge.status === 'online', agents: bridge.agent_count,
    provider: data.defaults[bridge.bridge_id].provider, model: data.defaults[bridge.bridge_id].model,
    catalog: data.providers,
    availableAgents: data.agents.find((entry) => entry.bridge_id === bridge.bridge_id)?.agents || [],
    overrides: (data.overrides[bridge.bridge_id] || []).map((item) => ({
      id: item.agent_id, agent: data.agents.find((entry) => entry.bridge_id === bridge.bridge_id)?.agents.find((agent) => agent.agent_id === item.agent_id)?.name || 'Agent',
      provider: item.provider, model: item.model,
    })),
  }));
}
