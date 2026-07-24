import { useEffect, useState } from 'react';
import type { ReactNode } from 'react';

// UI-13: responsive/mobile primitives shared across the shell.
// Breakpoints (approx, per arch doc §6D): <768px mobile, 768–1024px tablet,
// >1024px desktop. The desktop "two panes side-by-side" collapses to mobile
// screens/sheets: sidebar = off-canvas drawer; main = full-width; a bottom tab
// bar with a command-palette center button replaces sidebar chrome; the right
// inspector becomes a bottom sheet; chain list/detail become a drill-down.

export const MOBILE_MAX = 767;
export const TABLET_MAX = 1023;

export type Viewport = 'mobile' | 'tablet' | 'desktop';

export function useViewport(): Viewport {
  const [viewport, setViewport] = useState<Viewport>(() => readViewport());
  useEffect(() => {
    const update = () => setViewport(readViewport());
    update();
    window.addEventListener('resize', update);
    return () => window.removeEventListener('resize', update);
  }, []);
  return viewport;
}

function readViewport(): Viewport {
  if (typeof window === 'undefined') return 'desktop';
  const w = window.innerWidth;
  if (w <= MOBILE_MAX) return 'mobile';
  if (w <= TABLET_MAX) return 'tablet';
  return 'desktop';
}

export function useIsMobile(): boolean {
  return useViewport() === 'mobile';
}

// UI-13: keyboard-aware layout. Mobile soft keyboards shrink window.visualViewport
// without resizing the layout viewport. We expose the gap as an inset so the
// bottom-pinned composer / inspector sheet can lift above the keyboard. Returns
// 0 on desktop or when no keyboard is visible.
export function useKeyboardInset(): number {
  const [inset, setInset] = useState(0);
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const vv: VisualViewport | undefined = window.visualViewport;
    if (!vv) return;
    const update = () => {
      if (window.innerWidth > MOBILE_MAX) { setInset(0); return; }
      const gap = window.innerHeight - vv.height - vv.offsetTop;
      // Hysteresis: ignore sub-threshold deltas (browser chrome/bouncing).
      setInset(gap > 24 ? Math.max(0, gap) : 0);
    };
    update();
    vv.addEventListener('resize', update);
    vv.addEventListener('scroll', update);
    window.addEventListener('resize', update);
    return () => {
      vv.removeEventListener('resize', update);
      vv.removeEventListener('scroll', update);
      window.removeEventListener('resize', update);
    };
  }, []);
  return inset;
}

// Touch-target floor: >=44px where practical (arch doc §6D). Components compose
// this with their own min-w/h utilities to guarantee the hit area.
export const TOUCH_TARGET_CLASS = 'min-h-11 min-w-11';

export type MobileTab = {
  id: string;
  label: string;
  icon: string;
  route: string;
  badge?: number;
};

// UI-13: the mobile bottom tab bar. Chat / Chains / (palette center) / Library / More.
// `onOpenPalette` opens the command palette from the center button. The four
// outer tabs navigate; debug-ids are layout-independent (same as desktop nav).
export type MobileTabBarProps = {
  activePath: string;
  onNavigate: (route: string) => void;
  onOpenPalette: () => void;
  chatBadge?: number;
  chainsBadge?: number;
  // The center palette button's debug-id is owned by the shell so the palette
  // entry point has one stable, layout-independent id (also satisfies UI-12).
  paletteDebugId?: string;
};

const TABS: { id: string; label: string; icon: string; route: string }[] = [
  { id: 'chat', label: 'Chat', icon: '💬', route: '/conversations' },
  { id: 'chains', label: 'Chains', icon: '⛓', route: '/chains' },
  { id: 'library', label: 'Library', icon: '▣', route: '/library' },
  { id: 'more', label: 'More', icon: '⋯', route: '/settings' },
];

export function MobileTabBar({ activePath, onNavigate, onOpenPalette, chatBadge = 0, chainsBadge = 0, paletteDebugId = 'shell-mobile-palette-button' }: MobileTabBarProps) {
  const isActive = (route: string) => activePath === route || activePath.startsWith(`${route}/`);
  return (
    <nav
      data-debug-id="shell-mobile-tab-bar"
      aria-label="Mobile bottom navigation"
      className="ui-safe-bottom fixed inset-x-0 bottom-0 z-40 grid grid-cols-5 items-stretch border-t border-white/10 bg-[#101010]/95 backdrop-blur md:hidden"
    >
      {TABS.slice(0, 2).map((tab) => (
        <MobileTabButton key={tab.id} tab={tab} active={isActive(tab.route)} badge={tab.id === 'chat' ? chatBadge : tab.id === 'chains' ? chainsBadge : 0} onClick={() => onNavigate(tab.route)} />
      ))}
      {/* Center = command palette (dedicated center button per arch doc §6D). */}
      <div className="flex items-end justify-center pb-1">
        <button
          type="button"
          data-debug-id={paletteDebugId}
          onClick={onOpenPalette}
          aria-label="Command palette"
          className={`grid h-12 w-12 -translate-y-2 place-items-center rounded-full border border-white/15 bg-[#1c1c1c] text-zinc-100 shadow-lg shadow-black/40 hover:bg-[#262626] ${TOUCH_TARGET_CLASS}`}
        >
          <span aria-hidden="true">⌘</span>
        </button>
      </div>
      {TABS.slice(2).map((tab) => (
        <MobileTabButton key={tab.id} tab={tab} active={isActive(tab.route)} onClick={() => onNavigate(tab.route)} />
      ))}
    </nav>
  );
}

function MobileTabButton({ tab, active, badge = 0, onClick }: { tab: { id: string; label: string; icon: string; route: string }; active: boolean; badge?: number; onClick: () => void }) {
  return (
    <button
      type="button"
      data-debug-id={`shell-mobile-tab-${tab.id}`}
      onClick={onClick}
      aria-current={active ? 'page' : undefined}
      className={`relative flex flex-col items-center justify-center gap-0.5 py-1.5 text-[10px] ${active ? 'text-zinc-100' : 'text-zinc-500'} ${TOUCH_TARGET_CLASS}`}
    >
      <span aria-hidden="true" className="text-lg leading-none">{tab.icon}</span>
      <span>{tab.label}</span>
      {badge > 0 ? <span data-debug-id={`shell-mobile-tab-${tab.id}-badge`} className="absolute right-3 top-0.5 min-w-4 rounded-full bg-sky-400 px-1 text-center text-[9px] font-bold leading-4 text-black">{badge > 99 ? '99+' : badge}</span> : null}
    </button>
  );
}

// UI-13: mobile-only top bar that replaces desktop sidebar chrome. Carries the
// drawer (off-canvas sidebar) toggle, the current title, and an optional
// inspector toggle (conversation right inspector -> bottom sheet).
export type MobileTopBarProps = {
  title: string;
  onOpenDrawer: () => void;
  inspectorToggle?: { label?: string; badge?: number; open?: boolean; onToggle: () => void };
};

export function MobileTopBar({ title, onOpenDrawer, inspectorToggle }: MobileTopBarProps) {
  return (
    <header
      data-debug-id="shell-mobile-top-bar"
      className="ui-safe-top sticky top-0 z-30 flex min-h-12 items-center gap-2 border-b border-white/10 bg-[#101010]/95 px-2 backdrop-blur md:hidden"
    >
      <button
        type="button"
        data-debug-id="shell-mobile-drawer-open"
        onClick={onOpenDrawer}
        aria-label="Open navigation"
        className={`grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-zinc-200 hover:bg-white/10 ${TOUCH_TARGET_CLASS}`}
      >
        <span aria-hidden="true">☰</span>
      </button>
      <h1 data-debug-id="shell-mobile-title" className="min-w-0 flex-1 truncate text-sm font-semibold text-zinc-100">{title}</h1>
      {inspectorToggle ? (
        <button
          type="button"
          data-debug-id="shell-mobile-inspector-toggle"
          onClick={inspectorToggle.onToggle}
          aria-pressed={inspectorToggle.open ? 'true' : 'false'}
          aria-label={inspectorToggle.label || 'Toggle inspector'}
          className={`relative inline-flex shrink-0 items-center gap-1 rounded-xl border px-3 text-xs font-semibold ${inspectorToggle.open ? 'border-sky-400/40 bg-sky-400/15 text-sky-100' : 'border-white/10 bg-white/5 text-zinc-300 hover:bg-white/10'} ${TOUCH_TARGET_CLASS}`}
        >
          <span>{inspectorToggle.label || 'Inspector'}</span>
          {typeof inspectorToggle.badge === 'number' && inspectorToggle.badge > 0 ? (
            <span data-debug-id="shell-mobile-inspector-badge" className="min-w-4 rounded-full bg-sky-400 px-1 text-center text-[9px] font-bold leading-4 text-black">{inspectorToggle.badge > 99 ? '99+' : inspectorToggle.badge}</span>
          ) : null}
        </button>
      ) : null}
    </header>
  );
}

// UI-13: chain drill-down header. Desktop shows task list + detail side-by-side;
// mobile drills down: list (full-screen) -> tap task -> detail (full-screen) with
// a back affordance. This header provides that back navigation on mobile only.
export type MobileBackHeaderProps = {
  title: string;
  onBack: () => void;
  action?: ReactNode;
};

export function MobileBackHeader({ title, onBack, action }: MobileBackHeaderProps) {
  return (
    <header data-debug-id="shell-mobile-back-header" className="ui-safe-top sticky top-0 z-30 flex min-h-12 items-center gap-2 border-b border-white/10 bg-[#101010]/95 px-2 backdrop-blur md:hidden">
      <button
        type="button"
        data-debug-id="shell-mobile-back-btn"
        onClick={onBack}
        aria-label="Back"
        className={`grid h-10 w-10 shrink-0 place-items-center rounded-xl border border-white/10 bg-white/5 text-zinc-200 hover:bg-white/10 ${TOUCH_TARGET_CLASS}`}
      >
        <span aria-hidden="true">‹</span>
      </button>
      <h2 data-debug-id="shell-mobile-back-title" className="min-w-0 flex-1 truncate text-sm font-semibold text-zinc-100">{title}</h2>
      {action ? <div className="shrink-0">{action}</div> : null}
    </header>
  );
}

// UI-13: mobile bottom-sheet shell for the conversation right inspector. The
// desktop right-aside inspector collapses to a slide-up sheet on mobile; tabs
// render as a segmented control. Content/labels/debug-ids are supplied by the
// caller (ContextInspector) so they stay layout-independent (arch doc §6D).
export type MobileInspectorSheetProps = {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  subtitle?: ReactNode;
  headerActions?: ReactNode;
  keyboardInset?: number;
  children: ReactNode;
};

export function MobileInspectorSheet({ open, onClose, title, subtitle, headerActions, keyboardInset = 0, children }: MobileInspectorSheetProps) {
  if (!open) return null;
  return (
    <div data-debug-id="shell-mobile-inspector-sheet-root" className="fixed inset-0 z-50 flex items-end justify-center md:hidden" role="dialog" aria-modal="true" aria-label="Inspector">
      <div data-debug-id="shell-mobile-inspector-sheet-scrim" onClick={onClose} className="absolute inset-0 bg-black/60 backdrop-blur-sm" aria-hidden="true" />
      <div
        data-debug-id="workspace-inspector"
        data-mobile-sheet="true"
        className="ui-safe-bottom relative flex max-h-[80vh] w-full flex-col rounded-t-3xl border-t border-white/12 bg-[#0d0d0d] shadow-2xl shadow-black/60"
        style={{ paddingBottom: keyboardInset || undefined }}
      >
        <div data-debug-id="shell-mobile-inspector-sheet-grab" className="mx-auto mt-2 h-1.5 w-10 shrink-0 rounded-full bg-white/20" aria-hidden="true" />
        <div className="flex items-start justify-between gap-3 px-4 pb-2 pt-3">
          <div className="min-w-0">
            <div className="text-[10.5px] font-semibold uppercase tracking-[0.2em] text-zinc-500">Inspector</div>
            {title ? <div className="mt-0.5 truncate text-[15px] font-semibold text-zinc-100">{title}</div> : null}
            {subtitle ? <div className="truncate text-[11.5px] text-zinc-500">{subtitle}</div> : null}
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {headerActions}
            <button
              type="button"
              data-debug-id="workspace-inspector-toggle-btn"
              onClick={onClose}
              aria-label="Close inspector"
              title="Close inspector"
              className={`grid h-8 w-8 place-items-center rounded-full border border-white/10 bg-[#141414] text-sm text-zinc-400 hover:text-zinc-100 ${TOUCH_TARGET_CLASS}`}
            >
              ×
            </button>
          </div>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-4">{children}</div>
      </div>
    </div>
  );
}
