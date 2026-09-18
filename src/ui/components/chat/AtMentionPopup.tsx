import { useEffect, useMemo, useRef } from 'react';

// @-mention autocomplete popup for the conversation composer. Renders above the
// textarea (absolute bottom-full) and lists agent instances, projects, and task
// chains grouped by type. Selection inserts @<id> at the caret (handled by the
// parent). Mobile-friendly: rows are min-h-[44px] touch targets and taps select.
export type MentionEntity = {
  type: 'agent' | 'project' | 'chain';
  id: string;
  label: string;
  sublabel?: string;
};

type Props = {
  query: string;
  entities: MentionEntity[];
  activeIndex: number;
  onSelect: (entity: MentionEntity) => void;
  onClose: () => void;
};

const GROUP_ORDER: Array<{ type: MentionEntity['type']; header: string }> = [
  { type: 'agent', header: 'Agents' },
  { type: 'project', header: 'Projects' },
  { type: 'chain', header: 'Chains' },
];

const BADGE_LABEL: Record<MentionEntity['type'], string> = {
  agent: 'agent',
  project: 'project',
  chain: 'chain',
};

export default function AtMentionPopup({ query: _query, entities, activeIndex, onSelect, onClose }: Props) {
  const rootRef = useRef<HTMLDivElement>(null);

  // Close when the user clicks/taps outside the popup. The composer textarea keeps
  // focus, so a pointerdown elsewhere means the user is leaving the mention flow.
  useEffect(() => {
    function handlePointerDown(event: MouseEvent | TouchEvent) {
      if (rootRef.current && !rootRef.current.contains(event.target as Node)) {
        onClose();
      }
    }
    document.addEventListener('mousedown', handlePointerDown);
    document.addEventListener('touchstart', handlePointerDown);
    return () => {
      document.removeEventListener('mousedown', handlePointerDown);
      document.removeEventListener('touchstart', handlePointerDown);
    };
  }, [onClose]);

  // Preserve the parent's global activeIndex while rendering grouped sections: map
  // each entity to its flat index so highlight + click line up with arrow-key nav.
  const groups = useMemo(() => {
    return GROUP_ORDER.map(({ type, header }) => ({
      header,
      items: entities
        .map((entity, index) => ({ entity, index }))
        .filter(({ entity }) => entity.type === type),
    })).filter((group) => group.items.length > 0);
  }, [entities]);

  return (
    <div
      ref={rootRef}
      data-debug-id="conversation-mention-popup"
      className="absolute bottom-full left-0 right-0 z-50 mb-2 max-h-[40vh] overflow-y-auto rounded-2xl border border-white/10 bg-[#1c1c1f] p-1 shadow-2xl shadow-black/40"
      role="listbox"
    >
      {entities.length === 0 ? (
        <div data-debug-id="conversation-mention-empty" className="px-3 py-2.5 text-[13px] text-zinc-500">
          No matches
        </div>
      ) : (
        groups.map((group) => (
          <div key={group.header}>
            <div className="px-3 pt-2 pb-0.5 text-[11px] font-semibold uppercase tracking-wide text-zinc-500">
              {group.header}
            </div>
            {group.items.map(({ entity, index }) => {
              const isActive = index === activeIndex;
              return (
                <button
                  key={`${entity.type}-${entity.id}`}
                  type="button"
                  role="option"
                  aria-selected={isActive}
                  data-debug-id={`conversation-mention-item-${entity.id}`}
                  // pointerdown (not click) so selection fires before the textarea's
                  // blur/outside-click handling steals it on mobile.
                  onMouseDown={(e) => { e.preventDefault(); onSelect(entity); }}
                  onTouchStart={(e) => { e.preventDefault(); onSelect(entity); }}
                  className={`flex min-h-[44px] w-full items-center gap-2 rounded-xl px-3 py-2 text-left ${isActive ? 'bg-white/10' : 'hover:bg-white/5'}`}
                >
                  <span className="flex min-w-0 flex-col">
                    <span className="min-w-0 truncate text-[13px] font-semibold text-zinc-100">{entity.label || entity.id}</span>
                    {entity.sublabel ? (
                      <span className="min-w-0 truncate text-[11px] text-zinc-500">{entity.sublabel}</span>
                    ) : null}
                  </span>
                  <span className="ml-auto shrink-0 rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] uppercase tracking-wide text-zinc-400">
                    {BADGE_LABEL[entity.type]}
                  </span>
                </button>
              );
            })}
          </div>
        ))
      )}
    </div>
  );
}
