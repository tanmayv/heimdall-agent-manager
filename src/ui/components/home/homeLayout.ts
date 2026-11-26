/** Shared browser/server Home layout contract. */
export const HOME_WIDGETS = [
  { id: 'activity', name: 'Activity', description: 'Daily heatmap of tasks, chains, agents and bridges', width: 2 },
  { id: 'chains', name: 'Task chains', description: 'Active task chains and their progress', width: 1 },
  { id: 'uptime', name: 'Uptime', description: 'Bridge connections over the last 30 days', width: 1 },
  { id: 'fleet', name: 'Fleet', description: 'Default and per-agent provider and model', width: 2 },
] as const;
export type HomeWidgetId = typeof HOME_WIDGETS[number]['id'];
export interface HomeWidgetLayout {
  id: HomeWidgetId;
  width: 1 | 2;
  hidden: boolean;
  options?: Record<string, unknown>;
}
export interface HomeLayout { version: number; widgets: HomeWidgetLayout[] }
export function defaultHomeLayout(): HomeLayout {
  return { version: 0, widgets: HOME_WIDGETS.map(({ id, width }) => ({ id, width, hidden: false })) };
}
export function normalizeHomeLayout(value: unknown): HomeLayout {
  const fallback = defaultHomeLayout();
  if (!value || typeof value !== 'object') return fallback;
  const raw = value as Partial<HomeLayout>;
  if (!Array.isArray(raw.widgets) || !Number.isSafeInteger(raw.version) || raw.version < 0) return fallback;
  const seen = new Set<string>();
  const widgets: HomeWidgetLayout[] = [];
  for (const item of raw.widgets) {
    const definition = HOME_WIDGETS.find((widget) => widget.id === item?.id);
    if (!definition || seen.has(item.id)) continue;
    seen.add(item.id);
    widgets.push({
      id: definition.id, width: item.width === 1 || item.width === 2 ? item.width : definition.width,
      hidden: item.hidden === true,
      ...(item.options && typeof item.options === 'object' && !Array.isArray(item.options) ? { options: { ...item.options } } : {}),
    });
  }
  for (const item of fallback.widgets) if (!seen.has(item.id)) widgets.push(item);
  return { version: raw.version, widgets };
}
/** Greedy consecutive rows; a lone half stretches without modifying its stored width. */
export function packHomeRows<T extends { width: 1 | 2 }>(items: readonly T[]): { item: T; span: 1 | 2 }[] {
  return items.map((item, index) => {
    if (item.width === 2) return { item, span: 2 };
    // Count half-width siblings since the preceding full-width item.
    let start = index;
    while (start > 0 && items[start - 1].width === 1) start--;
    const pairedBefore = (index - start) % 2 === 1;
    const pairedAfter = items[index + 1]?.width === 1;
    return { item, span: pairedBefore || pairedAfter ? 1 : 2 };
  });
}
export function setWidgetHidden(layout: HomeLayout, id: HomeWidgetId, hidden: boolean): HomeLayout {
  return { ...layout, widgets: layout.widgets.map((item) => item.id === id ? { ...item, hidden } : item) };
}
/** Move into a target slot while retaining hidden widgets and their previous positions. */
const MOBILE_ORDER: Record<HomeWidgetId, number> = { uptime: 0, chains: 1, fleet: 2, activity: 3 };
/** Mobile ranks live in options so the desktop array order and width stay unchanged. */
function mobileRank(widget: HomeWidgetLayout) {
  const rank = widget.options?.mobile_order;
  return typeof rank === 'number' && Number.isSafeInteger(rank) && rank >= 0 ? rank : MOBILE_ORDER[widget.id];
}
export function visibleHomeWidgets(layout: HomeLayout, mobile: boolean): HomeWidgetLayout[] {
  const visible = layout.widgets.filter((widget) => !widget.hidden && (!mobile || widget.id !== 'activity'));
  return mobile ? visible.sort((a, b) => mobileRank(a) - mobileRank(b) || MOBILE_ORDER[a.id] - MOBILE_ORDER[b.id]) : visible;
}
export function moveHomeWidget(layout: HomeLayout, id: HomeWidgetId, target: HomeWidgetId, mobile = false): HomeLayout {
  if (mobile) {
    const order = layout.widgets.filter((widget) => widget.id !== 'activity').sort((a, b) => mobileRank(a) - mobileRank(b) || MOBILE_ORDER[a.id] - MOBILE_ORDER[b.id]);
    const from = order.findIndex((widget) => widget.id === id);
    const to = order.findIndex((widget) => widget.id === target);
    if (from < 0 || to < 0 || from === to) return layout;
    const [moved] = order.splice(from, 1);
    order.splice(to, 0, moved);
    return { ...layout, widgets: layout.widgets.map((widget) => widget.id === 'activity' ? widget : {
      ...widget, options: { ...widget.options, mobile_order: order.findIndex((item) => item.id === widget.id) },
    }) };
  }
  const widgets = [...layout.widgets];
  const from = widgets.findIndex((item) => item.id === id);
  const to = widgets.findIndex((item) => item.id === target);
  if (from < 0 || to < 0 || from === to) return layout;
  const [moved] = widgets.splice(from, 1);
  widgets.splice(to, 0, moved);
  return { ...layout, widgets };
}
export interface HomeLayoutAdapter {
  load(userId: string, signal?: AbortSignal): Promise<HomeLayout>;
  save(userId: string, layout: HomeLayout, expectedVersion: number, signal?: AbortSignal): Promise<HomeLayout>;
}
export class HomeLayoutConflict extends Error {
  readonly status = 409;
  constructor() { super('The home layout changed elsewhere.'); }
}
export const homeLayoutStorageKey = (userId: string) => 'heimdall:home-layout:' + encodeURIComponent(userId);
export function createLocalHomeLayoutAdapter(storage: Pick<Storage, 'getItem' | 'setItem'>): HomeLayoutAdapter {
  const read = (userId: string): HomeLayout => {
    const text = storage.getItem(homeLayoutStorageKey(userId));
    if (!text) return defaultHomeLayout();
    try { return normalizeHomeLayout(JSON.parse(text)); } catch { return defaultHomeLayout(); }
  };
  return {
    async load(userId) { return read(userId); },
    async save(userId, layout, expectedVersion) {
      if (read(userId).version !== expectedVersion) throw new HomeLayoutConflict();
      const saved = normalizeHomeLayout({ ...layout, version: expectedVersion + 1 });
      storage.setItem(homeLayoutStorageKey(userId), JSON.stringify(saved));
      return saved;
    },
  };
}
export type HomeLayoutStatus = 'loading' | 'saved' | 'saving' | 'conflict' | 'error';
export interface HomeLayoutSnapshot { layout: HomeLayout; status: HomeLayoutStatus; error?: string; canEdit?: boolean }
/** Serializes saves, debounces edits, and never lets a stale response replace newer edits. */
export class HomeLayoutSession {
  private good = defaultHomeLayout();
  private current = this.good;
  private status: HomeLayoutStatus = 'loading';
  private timer: ReturnType<typeof setTimeout> | undefined;
  private saving = false;
  private revision = 0;
  private due = false;
  private disposed = false;
  private loaded = false;
  private error: string | undefined;
  private loading: Promise<void> | undefined;
  private loadController: AbortController | undefined;
  private saveController: AbortController | undefined;
  private refreshPending = false;
  constructor(private adapter: HomeLayoutAdapter, private userId: string, private notify: (snapshot: HomeLayoutSnapshot) => void, private delay = 500, private isCurrentUser = () => true) {}
  private canEdit() { return this.loaded && this.status !== 'conflict' && this.status !== 'error'; }
  private emit() {
    if (!this.disposed && this.isCurrentUser()) this.notify({ layout: this.current, status: this.status, error: this.error, canEdit: this.canEdit() });
  }
  load(): Promise<void> {
    if (this.disposed || !this.isCurrentUser()) return Promise.resolve();
    if (this.saving || this.status === 'saving') { this.refreshPending = true; return Promise.resolve(); }
    if (this.loading) return this.loading;
    this.refreshPending = false;
    const revision = this.revision;
    const controller = new AbortController();
    this.loadController = controller;
    if (!this.loaded) this.status = 'loading';
    this.emit();
    this.loading = (async () => {
      await Promise.resolve();
      try {
        const saved = this.userId ? await this.adapter.load(this.userId, controller.signal) : defaultHomeLayout();
        if (this.disposed || !this.isCurrentUser()) return;
        // A focus GET may finish after a new edit (or even its save). Fetch again
        // after it settles rather than applying this older snapshot.
        if (revision !== this.revision) { this.refreshPending = true; return; }
        this.good = normalizeHomeLayout(saved); this.current = this.good;
        this.loaded = true; this.status = 'saved'; this.error = undefined;
      } catch (error) {
        if (this.disposed || !this.isCurrentUser() || controller.signal.aborted) return;
        if (revision !== this.revision) { this.refreshPending = true; return; }
        this.status = 'error';
        this.error = `Your layout could not be loaded. ${error instanceof Error ? error.message : 'Please reload to try again.'}`;
      } finally {
        this.loading = undefined; this.loadController = undefined;
        this.emit(); this.refreshWhenClean();
      }
    })();
    return this.loading;
  }
  refresh() {
    // Keep changed-elsewhere feedback until the user explicitly reloads.
    if (this.status !== 'conflict') return this.load();
    return Promise.resolve();
  }
  private refreshWhenClean() {
    if (this.refreshPending && !this.loading && !this.saving && this.status === 'saved') void this.load();
  }
  edit(change: (layout: HomeLayout) => HomeLayout) {
    if (!this.canEdit() || this.disposed || !this.isCurrentUser()) return;
    const next = change(this.current);
    if (next === this.current) return;
    this.due = false; this.current = next; this.revision++; this.status = 'saving'; this.error = undefined; this.emit();
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { this.timer = undefined; void this.flush(); }, this.delay);
  }
  async flush() {
    clearTimeout(this.timer); this.timer = undefined;
    if (!this.isCurrentUser()) { this.saveController?.abort(); return; }
    if (this.saving) { this.due = true; return; }
    if (!this.loaded || this.status !== 'saving') return;
    if (!this.userId) { this.good = this.current; this.status = 'saved'; this.emit(); return; }
    this.saving = true;
    const controller = new AbortController();
    this.saveController = controller;
    const sentRevision = this.revision;
    try {
      const saved = await this.adapter.save(this.userId, { ...this.current, version: this.good.version }, this.good.version, controller.signal);
      if (!this.isCurrentUser() || controller.signal.aborted) return;
      this.good = normalizeHomeLayout(saved);
      this.current = sentRevision === this.revision ? this.good : { ...this.current, version: this.good.version };
      if (sentRevision === this.revision) this.status = 'saved';
    } catch (error) {
      if (!this.isCurrentUser() || controller.signal.aborted) return;
      clearTimeout(this.timer); this.timer = undefined; this.due = false;
      this.current = this.good;
      this.status = error instanceof HomeLayoutConflict ? 'conflict' : 'error';
      this.error = this.status === 'conflict' ? undefined : `Your layout could not be saved. Your last saved layout has been restored. ${error instanceof Error ? error.message : 'Please reload to try again.'}`;
    } finally {
      this.saving = false; this.saveController = undefined; this.emit();
      if (this.isCurrentUser() && (this.due || (this.disposed && this.status === 'saving'))) {
        this.due = false; void this.flush();
      }
      this.refreshWhenClean();
    }
  }
  dispose() {
    this.disposed = true;
    this.refreshPending = false;
    this.loadController?.abort();
    // Navigation flushes only while the captured account is still active. Auth
    // clears expectedUser before its switching render unmounts Home.
    if (this.isCurrentUser()) void this.flush();
    else {
      clearTimeout(this.timer); this.timer = undefined; this.due = false;
      this.saveController?.abort();
    }
  }
}
