import { localDate, summarizeActivity, fleetFromWire, type ActivityData, type ActivityMetric, type ActivityDay, type UptimeData, type FleetBridge, type WidgetLoader, type ActivityWire, type UptimeWire, type FleetWire, type HomeChainPage, type HomeChainDetail } from './widgetData';

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

/** Wire fixtures match the spec; all fixture values are isolated in this module. */
export function activityFixture(metric: ActivityMetric, today = new Date()): ActivityWire {
  const data = mockActivity(metric, today);
  return {
    metric, kind: data.kind, tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
    from: data.days[0].date, to: localDate(today), tracking_since: data.days[0].date,
    days: data.days.filter((day) => day.value > 0 && !day.future).map(({ date, value }) => ({ date, value })),
    summary: {
      ...(data.kind === 'counter' ? { total: data.summary.total } : { avg: data.summary.average }),
      best: data.summary.best, active_days: data.summary.activeDays, streak_days: data.summary.streakDays,
    }, levels: data.levels,
  };
}
export function uptimeFixture(today = new Date()): UptimeWire {
  const data = mockUptime(today);
  return {
    tz: Intl.DateTimeFormat().resolvedOptions().timeZone, window_days: 30,
    fleet: { connected: data.connected, total: data.total, uptime_pct: data.uptimePercent },
    bridges: data.bridges.map((bridge) => ({
      bridge_id: bridge.id, label: bridge.label, status: bridge.online ? 'online' : 'offline',
      connected_since: new Date(today.getTime() - ({ '4d 3h': 99, '12d 6h': 294, '21d 9h': 513 }[bridge.connectedFor] || 0) * 3600000).toISOString(),
      uptime_pct: bridge.uptimePercent, incidents: bridge.incidents,
      days: bridge.days.filter((day) => day.state !== 'up').map((day) => ({ date: day.date, down_s: day.downSeconds, state: day.state })),
    })),
  };
}
export function fleetFixture(): FleetWire {
  const bridges: FleetBridge[] = [
    { id: 'mock-bridge-0', label: 'riverwood', os: 'Fedora Atomic', agents: 4, online: true, provider: 'claude', model: 'claude-opus-5-5',
      overrides: [
        { id: 'mock-worker', agent: 'Worker', provider: 'claude', model: 'claude-sonnet-5-5' },
        { id: 'mock-reviewer', agent: 'Reviewer', provider: 'codex', model: 'gpt-6.1-sol' },
      ] },
    { id: 'mock-bridge-1', label: 'dawnstar', os: 'macOS', agents: 2, online: true, provider: 'claude', model: 'claude-opus-5-5', overrides: [] },
    { id: 'mock-bridge-2', label: 'kamsharm-mn4988.linkedin.biz', os: 'macOS', agents: 1, online: true, provider: 'claude', model: 'claude-sonnet-5-5', overrides: [] },
  ];
  return {
    providers: MOCK_PROVIDERS.map((p) => ({ provider: p.id, profile_id: p.id, label: p.label, models: p.models })),
    bridges: bridges.map((bridge) => ({ bridge_id: bridge.id, label: bridge.label, machine_os: bridge.os, status: 'online', agent_count: bridge.agents })),
    defaults: Object.fromEntries(bridges.map((bridge) => [bridge.id, { bridge_id: bridge.id, provider: bridge.provider, model: bridge.model, updated_at: '2026-11-25T00:00:00Z' }])),
    overrides: Object.fromEntries(bridges.map((bridge) => [bridge.id, bridge.overrides.map((item) => ({ bridge_id: bridge.id, agent_id: item.id, provider: item.provider, model: item.model, updated_at: '2026-11-25T00:00:00Z' }))])),
    agents: bridges.map((bridge) => ({ bridge_id: bridge.id, agents: MOCK_AGENTS.slice(0, bridge.agents).map((name) => ({ agent_id: name === 'Worker' ? 'mock-worker' : name === 'Reviewer' ? 'mock-reviewer' : 'mock-' + name.toLowerCase(), name })) })),
  };
}
export function chainsFixture(page: number): HomeChainPage {
  const titles = ['Static HTML bundle artifacts', 'Release local binaries', 'Trail detail screen polish', 'Bridge supervisor updates', 'Ninjy bot notification wiring', 'Review task scheduling', 'Fleet management polish'];
  const now = Date.now();
  return {
    total: titles.length, next_cursor: page < 2 ? String(page + 1) : '',
    chains: titles.slice(page * 3, page * 3 + 3).map((title, offset) => {
      const index = page * 3 + offset;
      return {
        chain_id: 'mock-chain-' + index, title, status: 'active', user_validation_count: index === 1 ? 1 : 0,
        project_name: index === 2 ? 'five-trails-ios' : 'heimdall-agent-manager',
        updated_at: new Date(now - [0, 18, 60, 120, 180, 240, 300][index] * 60000).toISOString(),
      };
    }),
  };
}
export function chainDetailFixture(id: string): HomeChainDetail {
  const index = Number(id.split('-').pop()) || 0;
  const done = [1, 4, 2][index % 3];
  const review = [1, 2, 0][index % 3];
  const progress = [2, 0, 1][index % 3];
  return {
    chain_id: id,
    members: [{ role: 'coordinator', display_name: ['spec-coordinator', 'coordinator', 'soloist'][index % 3], bridge_id: 'mock-bridge-1' }],
    tasks: Array.from({ length: index % 3 === 2 ? 5 : 6 }, (_, task) => ({ state: task < done ? 'done' : task < done + review ? 'in_review' : task < done + review + progress ? 'in_progress' : 'ready' })),
  };
}

export const loadMockFleet: WidgetLoader<FleetBridge[]> = async () => fleetFromWire(fleetFixture());
