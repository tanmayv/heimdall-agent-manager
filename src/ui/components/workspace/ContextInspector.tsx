import type { ReactNode } from 'react';
import type { WorkspaceInspectorTab } from './types';

export default function ContextInspector({
  title = 'Context',
  subtitle,
  tabs,
  activeTabId,
  onTabChange,
  collapsed = false,
  onToggleCollapsed,
  headerActions,
  className,
}: {
  title?: ReactNode;
  subtitle?: ReactNode;
  tabs: WorkspaceInspectorTab[];
  activeTabId: string;
  onTabChange: (tabId: string) => void;
  collapsed?: boolean;
  onToggleCollapsed?: () => void;
  headerActions?: ReactNode;
  className?: string;
}) {
  const visibleTabs = tabs.filter((tab) => !tab.hidden);
  const activeTab = visibleTabs.find((tab) => tab.id === activeTabId) || visibleTabs[0] || null;

  return (
    <aside
      data-debug-id="workspace-inspector"
      data-collapsed={collapsed ? 'true' : 'false'}
      className={className || `${collapsed ? 'w-0 border-l-0 p-0' : 'w-[420px] border-l border-[#262626] p-4'} min-h-0 shrink-0 overflow-hidden bg-[#0d0d0d] transition-[width,padding] duration-200`}
    >
      {collapsed ? (
        onToggleCollapsed ? (
          <div className="flex h-full flex-col items-center gap-3 py-3">
            <button
              type="button"
              data-debug-id="workspace-inspector-expand-btn"
              onClick={onToggleCollapsed}
              className="grid h-8 w-8 place-items-center rounded-full border border-white/10 bg-[#141414] text-sm text-zinc-400 hover:text-zinc-100"
              aria-label="Expand context inspector"
              title="Expand context inspector"
            >
              ‹
            </button>
            <span className="text-[10px] font-semibold uppercase tracking-[0.2em] text-zinc-600 [writing-mode:vertical-rl]">Inspector</span>
          </div>
        ) : null
      ) : (
        <div className="flex h-full min-h-0 flex-col">
          <div className="mb-4 flex items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="text-[10.5px] font-semibold uppercase tracking-[0.2em] text-zinc-500">Inspector</div>
              <h2 className="mt-1 truncate text-[15px] font-semibold text-zinc-100">{title}</h2>
              {subtitle ? <p className="mt-0.5 truncate text-[11.5px] text-zinc-500">{subtitle}</p> : null}
            </div>
            <div className="flex shrink-0 items-center gap-2">
              {headerActions}
              {onToggleCollapsed ? (
                <button
                  type="button"
                  data-debug-id="workspace-inspector-toggle-btn"
                  onClick={onToggleCollapsed}
                  className="grid h-8 w-8 place-items-center rounded-full border border-white/10 bg-[#141414] text-sm text-zinc-400 hover:text-zinc-100"
                  aria-label="Collapse context inspector"
                  title="Collapse context inspector"
                >
                  ×
                </button>
              ) : null}
            </div>
          </div>
          {visibleTabs.length > 0 ? (
            <div data-debug-id="workspace-inspector-tabs" className="mb-4 flex flex-wrap gap-1 rounded-xl border border-white/[0.06] bg-black/30 p-1">
              {visibleTabs.map((tab) => (
                <button
                  key={tab.id}
                  type="button"
                  data-debug-id={tab.buttonDebugId || `workspace-inspector-tab-${tab.id}`}
                  aria-pressed={activeTab?.id === tab.id}
                  disabled={tab.disabled}
                  onClick={() => onTabChange(tab.id)}
                  className={`flex items-center gap-1 rounded-lg px-3 py-1.5 text-xs font-medium transition ${activeTab?.id === tab.id ? 'bg-white/[0.08] text-zinc-100 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.10)]' : 'text-zinc-400 hover:text-zinc-200'} disabled:cursor-not-allowed disabled:opacity-50`}
                >
                  <span>{tab.label}</span>
                  {tab.badge ? <span className="text-[10px] text-zinc-500">{tab.badge}</span> : null}
                </button>
              ))}
            </div>
          ) : null}
          <div className="min-h-0 flex-1 overflow-hidden">
            {activeTab ? (
              <div data-debug-id={activeTab.panelDebugId || `workspace-inspector-panel-${activeTab.id}`} className="h-full min-h-0 overflow-y-auto">
                {activeTab.content}
              </div>
            ) : (
              <div data-debug-id="workspace-inspector-empty" className="rounded-2xl border border-dashed border-white/10 bg-black/20 p-4 text-sm text-zinc-400">No inspector content available for this context.</div>
            )}
          </div>
        </div>
      )}
    </aside>
  );
}
