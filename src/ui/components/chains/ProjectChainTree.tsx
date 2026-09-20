import { useState } from 'react';
import { useListTaskChainsQuery } from '../../api/endpoints/tasks';
import type { ChainListItem } from '../../api/endpoints/tasks';
import CreateChainModal from './CreateChainModal';
import { StatusDot } from '@ui';

type Props = {
  projects: Array<{ projectId: string; projectName: string }>;
  currentPath: string;
  onNavigate: (path: string) => void;
};

function relativeTime(iso: string): string {
  if (!iso) return '';
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return '';
  const diff = Date.now() - ms;
  const secs = Math.floor(diff / 1000);
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

type StatusTone = 'success' | 'neutral' | 'warning' | 'danger';

function chainStatusTone(status: string): StatusTone {
  switch (status) {
    case 'active': return 'success';
    case 'completed': return 'neutral';
    case 'paused': return 'warning';
    case 'cancelled': return 'danger';
    default: return 'neutral';
  }
}

function ChainRow({
  chain,
  currentPath,
  onNavigate,
}: {
  chain: ChainListItem;
  currentPath: string;
  onNavigate: (path: string) => void;
}) {
  const path = chain.coordinatorAgentInstanceId
    ? `/conversations/${encodeURIComponent(chain.coordinatorAgentInstanceId)}`
    : `/chains/${encodeURIComponent(chain.chainId)}`;
  const active = currentPath === path;
  const title = chain.title || 'Untitled chain';
  const tone = chainStatusTone(chain.status);
  const timestamp = relativeTime(chain.updatedAt);

  return (
    <a
      href={`#${path}`}
      onClick={(e) => { e.preventDefault(); onNavigate(path); }}
      className={`flex min-h-8 w-full items-center gap-2 rounded-xl px-2.5 py-1.5 text-[12.5px] transition ${
        active
          ? 'bg-neutral-soft text-primary font-semibold'
          : 'text-muted hover:bg-neutral-soft hover:text-primary'
      }`}
    >
      <StatusDot
        tone={tone}
        pulse={chain.status === 'active'}
        label={chain.status}
        size="sm"
      />
      <span className="min-w-0 flex-1 truncate">{title}</span>
      {timestamp ? <span className="shrink-0 text-[10px] text-faint">{timestamp}</span> : null}
    </a>
  );
}

function ProjectChainGroup({
  projectId,
  projectName,
  currentPath,
  onNavigate,
  onOpenModal,
}: {
  projectId: string;
  projectName: string;
  currentPath: string;
  onNavigate: (path: string) => void;
  onOpenModal: (projectId: string) => void;
}) {
  const [collapsed, setCollapsed] = useState(false);
  const [cursor, setCursor] = useState('');
  const { data, isFetching } = useListTaskChainsQuery({ projectId, limit: 20, cursor });

  const chains = data?.chains ?? [];
  const hasMore = data?.hasMore ?? false;
  const nextCursor = data?.nextCursor ?? '';

  return (
    <div className="mb-2">
      {/* Project header */}
      <div className="flex items-center gap-1 px-2.5 py-1">
        <button
          type="button"
          onClick={() => setCollapsed((v) => !v)}
          className="flex min-w-0 flex-1 items-center gap-1.5 text-left text-[10.5px] font-bold uppercase tracking-[0.14em] text-faint hover:text-primary transition"
        >
          <span className={`shrink-0 transition-transform ${collapsed ? '-rotate-90' : ''}`}>▾</span>
          <span className="min-w-0 truncate">{projectName || 'Unnamed project'}</span>
          {isFetching ? <span className="ml-1 text-[9px] font-normal normal-case tracking-normal">…</span> : null}
        </button>
        <button
          type="button"
          aria-label={`New chain for ${projectName}`}
          onClick={() => onOpenModal(projectId)}
          className="shrink-0 rounded-md p-0.5 text-faint hover:bg-neutral-soft hover:text-primary transition"
        >
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
            <path d="M8 2v12M2 8h12" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>
      </div>

      {/* Chain rows */}
      {!collapsed && (
        <div className="space-y-0.5">
          {chains.map((chain) => (
            <ChainRow
              key={chain.chainId}
              chain={chain}
              currentPath={currentPath}
              onNavigate={onNavigate}
            />
          ))}
          {!isFetching && chains.length === 0 ? (
            <div className="px-2.5 py-1.5 text-[11.5px] text-faint">No chains yet.</div>
          ) : null}
          {hasMore && nextCursor ? (
            <button
              type="button"
              onClick={() => setCursor(nextCursor)}
              className="w-full px-2.5 py-1.5 text-left text-[11.5px] text-accent hover:underline"
            >
              Load more
            </button>
          ) : null}
        </div>
      )}
    </div>
  );
}

export default function ProjectChainTree({ projects, currentPath, onNavigate }: Props) {
  const [modalProjectId, setModalProjectId] = useState<string | null>(null);

  return (
    <section data-debug-id="sidebar-project-chain-tree" className="mt-4">
      <div className="mb-1.5 px-2.5 text-[10.5px] font-bold uppercase tracking-[0.16em] text-faint">
        Chains
      </div>
      {projects.length === 0 ? (
        <div className="px-2.5 py-2 text-[11.5px] text-faint">No projects.</div>
      ) : (
        projects.map((p) => (
          <ProjectChainGroup
            key={p.projectId}
            projectId={p.projectId}
            projectName={p.projectName}
            currentPath={currentPath}
            onNavigate={onNavigate}
            onOpenModal={setModalProjectId}
          />
        ))
      )}
      {modalProjectId ? (
        <CreateChainModal
          projectId={modalProjectId}
          isOpen={Boolean(modalProjectId)}
          onClose={() => setModalProjectId(null)}
          onCreated={(path) => {
            setModalProjectId(null);
            onNavigate(path);
          }}
        />
      ) : null}
    </section>
  );
}
