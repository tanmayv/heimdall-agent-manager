import { useMemo } from 'react';

export type ConversationWorkspaceTabProps = {
  projectId: string;
  projectName: string;
  agentInstanceId: string;
  projectAnchors?: Array<{ type: string; value: string; note?: string }>;
  debugPrefix: string;
};

// UI-7: Workspace tab for the conversation right inspector.
// Project-scoped. v1 scope: effective path (from project anchors) + validation
// status only. No VCS branch view, live diff, or changed-files list in v1
// (no backend VCS/diff endpoints — see docs/plans/ui-backend-gap-analysis.md).
export default function ConversationWorkspaceTab({ projectId, projectName, agentInstanceId, projectAnchors = [], debugPrefix }: ConversationWorkspaceTabProps) {
  const workDir = useMemo(() => {
    const anchor = (projectAnchors || []).find((item) => item.type === 'worktree_root' || item.type === 'directory' || item.type === 'vcs_worktree');
    return anchor?.value || '';
  }, [projectAnchors]);

  const vcsAnchors = useMemo(() => (projectAnchors || []).filter((item) => item.type === 'git_branch' || item.type === 'git_remote' || item.type === 'vcs_base_ref' || item.type === 'vcs_branch' || item.type === 'vcs_remote'), [projectAnchors]);

  return (
    <div data-debug-id={`${debugPrefix}-workspace-tab`} className="space-y-3 text-[12.5px] text-zinc-300">
      <div data-debug-id={`${debugPrefix}-workspace-header`} className="rounded-xl border border-white/10 bg-white/[0.03] p-3">
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0">
            <div className="truncate text-sm font-medium text-zinc-100">Workspace</div>
            <div className="mt-0.5 truncate text-[11px] text-zinc-500">Scoped to project <span className="text-zinc-400">{projectName || projectId}</span></div>
          </div>
          <span data-debug-id={`${debugPrefix}-workspace-project-chip`} className="shrink-0 rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-400">project</span>
        </div>
      </div>

      <div data-debug-id={`${debugPrefix}-workspace-effective-path`} className="rounded-xl border border-white/10 bg-white/[0.02] p-3">
        <div className="text-[11px] font-medium uppercase tracking-wide text-zinc-500">Effective path</div>
        {workDir ? (
          <div className="mt-1.5 flex items-center gap-2">
            <code data-debug-id={`${debugPrefix}-workspace-path-value`} className="min-w-0 truncate rounded bg-black/30 px-2 py-1 text-[11.5px] text-zinc-300">{workDir}</code>
            <span data-debug-id={`${debugPrefix}-workspace-path-status`} className="shrink-0 rounded-full border border-emerald-400/30 bg-emerald-400/10 px-2 py-0.5 text-[10.5px] text-emerald-200">resolved</span>
          </div>
        ) : (
          <div data-debug-id={`${debugPrefix}-workspace-path-empty`} className="mt-1.5 text-[11.5px] text-zinc-500">No work directory anchor set for this project.</div>
        )}
      </div>

      {vcsAnchors.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-workspace-vcs`} className="rounded-xl border border-white/10 bg-white/[0.02] p-3">
          <div className="text-[11px] font-medium uppercase tracking-wide text-zinc-500">Project anchors</div>
          <div className="mt-1.5 space-y-1">
            {vcsAnchors.map((anchor, index) => (
              <div key={`${anchor.type}-${index}`} className="flex items-center justify-between gap-2 text-[11.5px]">
                <span className="text-zinc-500">{anchor.type}</span>
                <code className="min-w-0 truncate text-zinc-400">{anchor.value}</code>
              </div>
            ))}
          </div>
        </div>
      ) : null}

      <div data-debug-id={`${debugPrefix}-workspace-scope-note`} className="rounded-xl border border-dashed border-white/10 bg-black/20 p-3 text-[11px] leading-5 text-zinc-500">
        v1 workspace scope: effective path + project anchors only. Branch view, live diff, and changed-files require backend VCS/diff endpoints not yet available.
      </div>
    </div>
  );
}
