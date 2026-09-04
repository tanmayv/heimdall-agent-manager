import { useState, useMemo } from 'react';
import Icon from '../Icon';
import { buildRouteHash } from '../../utils/appLocation';
import {
  Action,
  parseBlackoutDates,
  useListActionsQuery,
  useDeleteActionMutation,
  useRunActionMutation,
  useListAllAgentInstancesQuery,
} from '../../api/endpoints/actions';
import { useListProjectsQuery, Project } from '../../api/endpoints/projects';
import DeleteActionModal from './DeleteActionModal';
import { describeCron, calculateNextRuns, formatInTimeZone, timeZoneLabel } from './scheduleUtils';

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

function navigateTo(path: string) {
  window.location.hash = shellHash(path);
}

export default function ActionsPanel() {
  const { data: actionsData, isLoading: actionsLoading, error: actionsError } = useListActionsQuery();
  const { data: instancesData, isLoading: instancesLoading } = useListAllAgentInstancesQuery();
  const { data: projectsData, isLoading: projectsLoading } = useListProjectsQuery();

  const [deleteAction, { isLoading: isDeleting }] = useDeleteActionMutation();
  const [runAction] = useRunActionMutation();

  // Modal state (delete confirmation only; create/edit now live on dedicated pages)
  const [deletingAction, setDeletingAction] = useState<Action | null>(null);

  // Search filter
  const [searchQuery, setSearchQuery] = useState('');

  // Project collapse state: projectId -> isCollapsed
  const [collapsedProjects, setCollapsedProjects] = useState<Record<string, boolean>>({});

  // Run feedback state
  const [runningActionId, setRunningActionId] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null);

  const actions: Action[] = actionsData?.actions || [];
  const instances: any[] = instancesData?.instances || [];
  const projects: Project[] = projectsData?.projects || [];

  // Maps
  const instanceMap = useMemo(() => {
    const map = new Map<string, any>();
    for (const inst of instances) {
      map.set(inst.agent_instance_id, inst);
    }
    return map;
  }, [instances]);

  const projectMap = useMemo(() => {
    const map = new Map<string, Project>();
    for (const p of projects) {
      map.set(p.project_id, p);
    }
    return map;
  }, [projects]);

  // Group actions by project
  const groupedActions = useMemo(() => {
    const groups = new Map<string, { project: Project | null; actions: Action[] }>();

    // Initialize with known projects
    for (const p of projects) {
      groups.set(p.project_id, { project: p, actions: [] });
    }

    // Default/unassigned group
    const UNASSIGNED_KEY = '__unassigned__';
    groups.set(UNASSIGNED_KEY, { project: null, actions: [] });

    // Populate actions
    for (const act of actions) {
      // Filter by search query if any
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase();
        const inst = instanceMap.get(act.target_instance_id);
        // Fold display name, instance id, and agent id into the filter so any of
        // the three finds the action (mirrors the target picker's search index).
        const instHaystack = [
          inst?.display_name,
          inst?.agent_name,
          act.target_instance_id,
          inst?.agent_id,
        ].filter(Boolean).join(' ').toLowerCase();
        const promptMatch = act.prompt_text.toLowerCase().includes(q);
        const instMatch = instHaystack.includes(q);
        const cronMatch = (act.cron_expr || '').toLowerCase().includes(q);
        if (!promptMatch && !instMatch && !cronMatch) continue;
      }

      const inst = instanceMap.get(act.target_instance_id);
      const projectId = inst?.project_id;
      if (projectId && groups.has(projectId)) {
        groups.get(projectId)!.actions.push(act);
      } else {
        groups.get(UNASSIGNED_KEY)!.actions.push(act);
      }
    }

    // Convert to list, filtering out empty projects if searching
    const result: Array<{ id: string; name: string; project: Project | null; actions: Action[] }> = [];
    for (const [key, val] of groups.entries()) {
      if (key === UNASSIGNED_KEY) {
        if (val.actions.length > 0) {
          result.push({
            id: UNASSIGNED_KEY,
            name: 'Unassigned / Global Actions',
            project: null,
            actions: val.actions,
          });
        }
      } else {
        if (val.actions.length > 0 || !searchQuery.trim()) {
          result.push({
            id: key,
            name: val.project?.name || key,
            project: val.project,
            actions: val.actions,
          });
        }
      }
    }

    return result;
  }, [actions, instances, projects, instanceMap, searchQuery]);

  const totalActionsCount = actions.length;

  const toggleProjectCollapse = (projectId: string) => {
    setCollapsedProjects((prev) => ({
      ...prev,
      [projectId]: !prev[projectId],
    }));
  };

  const handleRunNow = async (action: Action) => {
    setRunningActionId(action.id);
    setFeedback(null);
    try {
      await runAction({ id: action.id }).unwrap();
      const inst = instanceMap.get(action.target_instance_id);
      const targetName = inst?.display_name || inst?.agent_name || action.target_instance_id;
      setFeedback({
        type: 'success',
        message: `Action executed! Prompt dispatched to agent "${targetName}".`,
      });
      // Auto-hide feedback after 5s
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      const msg = err?.data?.error?.message || err?.error || err?.message || String(err || 'Execution failed');
      setFeedback({
        type: 'error',
        message: `Failed to execute action: ${msg}`,
      });
    } finally {
      setRunningActionId(null);
    }
  };

  const handleDeleteConfirm = async () => {
    if (!deletingAction) return;
    try {
      await deleteAction({ id: deletingAction.id }).unwrap();
      setDeletingAction(null);
      setFeedback({
        type: 'success',
        message: 'Action deleted successfully.',
      });
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      const msg = err?.data?.error?.message || err?.error || err?.message || String(err || 'Deletion failed');
      setFeedback({
        type: 'error',
        message: `Failed to delete action: ${msg}`,
      });
    }
  };

  const isLoading = actionsLoading || instancesLoading || projectsLoading;

  return (
    <div data-debug-id="actions-page" className="w-full space-y-6 text-left">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between border-b border-white/10 pb-5">
        <div>
          <div className="flex items-center gap-2.5">
            <h1 className="text-2xl font-bold tracking-tight text-white">Actions</h1>
            <span
              data-debug-id="actions-total-count"
              className="rounded-full bg-sky-500/10 border border-sky-500/20 px-2.5 py-0.5 text-xs font-semibold text-sky-400"
            >
              {totalActionsCount} {totalActionsCount === 1 ? 'action' : 'actions'}
            </span>
          </div>
          <p className="mt-1 text-sm text-zinc-400">
            Automated recurring prompts and on-demand tasks executed against your agent instances.
          </p>
        </div>

        <div className="flex items-center gap-3">
          <a
            data-debug-id="actions-create-btn"
            href={shellHash('/actions/new')}
            className="flex items-center gap-2 rounded-xl bg-sky-500 hover:bg-sky-400 px-4 py-2 text-xs font-semibold text-black transition-colors shadow-sm"
          >
            <Icon name="plus" size={16} />
            <span>New Action</span>
          </a>
        </div>
      </div>

      {/* Feedback Banner */}
      {feedback && (
        <div
          data-debug-id="actions-feedback-banner"
          className={`flex items-center justify-between rounded-xl border p-3.5 text-xs font-medium animate-fade-in ${
            feedback.type === 'success'
              ? 'border-emerald-500/40 bg-emerald-950/20 text-emerald-300'
              : 'border-red-500/40 bg-red-950/20 text-red-300'
          }`}
        >
          <div className="flex items-center gap-2">
            <Icon name={feedback.type === 'success' ? 'check' : 'alert'} size={14} />
            <span>{feedback.message}</span>
          </div>
          <button
            type="button"
            aria-label="Dismiss"
            onClick={() => setFeedback(null)}
            className="text-zinc-400 hover:text-white transition-colors"
          >
            <Icon name="close" size={14} />
          </button>
        </div>
      )}

      {/* Filter / Search Bar */}
      {totalActionsCount > 0 && (
        <div className="flex items-center gap-3">
          <div className="relative flex-1">
            <input
              type="text"
              data-debug-id="actions-search-input"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Filter actions by prompt, agent, or cron expression..."
              className="w-full rounded-xl border border-white/10 bg-black/30 px-3.5 py-2 pl-9 text-xs text-zinc-100 placeholder-zinc-500 outline-none focus:border-sky-400"
            />
            <div className="absolute left-3 top-2.5 text-zinc-500">
              <Icon name="search" size={14} />
            </div>
            {searchQuery && (
              <button
                type="button"
                aria-label="Clear search"
                onClick={() => setSearchQuery('')}
                className="absolute right-3 top-2.5 text-zinc-500 hover:text-white"
              >
                <Icon name="close" size={14} />
              </button>
            )}
          </div>
        </div>
      )}

      {/* Loading State */}
      {isLoading && (
        <div data-debug-id="actions-loading-state" className="flex items-center justify-center p-12 text-zinc-400 text-sm">
          <div className="flex items-center gap-2">
            <Icon name="refresh" size={14} className="animate-spin text-sky-400" />
            <span>Loading actions and projects...</span>
          </div>
        </div>
      )}

      {/* Error State */}
      {actionsError && !isLoading && (
        <div data-debug-id="actions-error-state" className="rounded-xl border border-red-500/40 bg-red-950/20 p-5 text-sm text-red-300">
          Failed to load actions: {String((actionsError as any)?.error || (actionsError as any)?.message || actionsError)}
        </div>
      )}

      {/* Empty State */}
      {!isLoading && !actionsError && totalActionsCount === 0 && (
        <div
          data-debug-id="actions-empty-state"
          className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-white/10 bg-white/[0.01] p-12 text-center"
        >
          <div className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-white/5 text-zinc-400">
            <Icon name="clock" size={24} />
          </div>
          <h3 className="text-base font-semibold text-white">No Actions Configured</h3>
          <p className="mt-1 max-w-md text-xs leading-relaxed text-zinc-400">
            Actions allow you to schedule recurring prompts or trigger on-demand automation routines for any running agent instance.
          </p>
          <a
            data-debug-id="actions-empty-create-btn"
            href={shellHash('/actions/new')}
            className="mt-5 flex items-center gap-2 rounded-xl bg-sky-500 hover:bg-sky-400 px-4 py-2 text-xs font-semibold text-black transition-colors"
          >
            <Icon name="plus" size={16} />
            <span>Create Your First Action</span>
          </a>
        </div>
      )}

      {/* Project Grouped View (REQUIRED) */}
      {!isLoading && !actionsError && totalActionsCount > 0 && (
        <div data-debug-id="actions-project-groups" className="space-y-6">
          {groupedActions.map((group) => {
            const isCollapsed = Boolean(collapsedProjects[group.id]);
            const actionCount = group.actions.length;

            return (
              <div
                key={group.id}
                data-debug-id={`actions-project-group-${group.id}`}
                className="rounded-2xl border border-white/10 bg-white/[0.02] overflow-hidden"
              >
                {/* Collapsible Project Section Header */}
                <button
                  type="button"
                  data-debug-id={`actions-project-toggle-${group.id}`}
                  onClick={() => toggleProjectCollapse(group.id)}
                  className="w-full flex items-center justify-between px-4 py-3 bg-white/[0.03] hover:bg-white/[0.05] border-b border-white/10 transition-colors text-left"
                >
                  <div className="flex items-center gap-3">
                    <span className="text-zinc-400">
                      <Icon name={isCollapsed ? 'chevron-right' : 'chevron-down'} size={14} />
                    </span>
                    <div className="flex items-center gap-2">
                      <Icon name="folder" size={15} className="text-sky-400" />
                      <span className="text-sm font-semibold text-white">{group.name}</span>
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <span
                      data-debug-id={`actions-project-count-${group.id}`}
                      className="rounded-md bg-black/40 border border-white/10 px-2 py-0.5 text-xs text-zinc-400"
                    >
                      {actionCount} {actionCount === 1 ? 'action' : 'actions'}
                    </span>
                  </div>
                </button>

                {/* Collapsible Project Actions Content */}
                {!isCollapsed && (
                  <div className="p-4 space-y-3">
                    {actionCount === 0 ? (
                      <p className="text-xs text-zinc-500 italic py-2">
                        No actions matching filter in this project.
                      </p>
                    ) : (
                      <div className="grid gap-3">
                        {group.actions.map((act) => (
                          <ActionCard
                            key={act.id}
                            action={act}
                            instance={instanceMap.get(act.target_instance_id)}
                            isRunning={runningActionId === act.id}
                            onRun={() => handleRunNow(act)}
                            onEdit={() => navigateTo(`/actions/${encodeURIComponent(act.id)}/edit`)}
                            onDelete={() => setDeletingAction(act)}
                          />
                        ))}
                      </div>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Delete confirmation modal (create/edit now live on dedicated pages) */}
      <DeleteActionModal
        isOpen={Boolean(deletingAction)}
        action={deletingAction}
        isDeleting={isDeleting}
        onClose={() => setDeletingAction(null)}
        onConfirm={handleDeleteConfirm}
      />
    </div>
  );
}

// Sub-component: Individual Action Card
function ActionCard({
  action,
  instance,
  isRunning,
  onRun,
  onEdit,
  onDelete,
}: {
  action: Action;
  instance?: any;
  isRunning: boolean;
  onRun: () => void;
  onEdit: () => void;
  onDelete: () => void;
}) {
  const [expanded, setExpanded] = useState(false);

  const isScheduled = Boolean(action.cron_expr && action.cron_expr.trim() !== '');
  const scheduleDesc = isScheduled ? describeCron(action.cron_expr!) : 'On-Demand / Run-Only';

  const blackouts = parseBlackoutDates(action.blackout_dates);

  // Compute next runs if scheduled
  const nextRuns = useMemo(() => {
    if (!isScheduled || !action.cron_expr) return [];
    return calculateNextRuns(
      action.cron_expr,
      action.timezone || 'UTC',
      blackouts,
      1,
      new Date(),
      action.active_from,
      action.active_until
    );
  }, [action.cron_expr, action.timezone, blackouts, action.active_from, action.active_until, isScheduled]);

  const targetName = instance?.display_name || instance?.agent_name || action.target_instance_id;
  const instanceStatus = instance?.runtime_status || 'idle';

  return (
    <div
      data-debug-id={`action-row-${action.id}`}
      className="rounded-xl border border-white/10 bg-black/40 p-4 transition-colors hover:border-white/20 space-y-3"
    >
      {/* Top Header: Target Instance + State Badges + Actions Toolbar */}
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-white/5 pb-2.5">
        {/* Left: Instance and state badges */}
        <div className="flex flex-wrap items-center gap-2">
          {/* Instance badge */}
          <div
            data-debug-id={`action-instance-badge-${action.id}`}
            className="flex items-center gap-1.5 rounded-lg border border-white/10 bg-white/5 px-2.5 py-1 text-xs text-zinc-200"
          >
            <span
              className={`h-1.5 w-1.5 rounded-full ${
                instanceStatus === 'running'
                  ? 'bg-emerald-400'
                  : instanceStatus === 'stopped'
                  ? 'bg-zinc-500'
                  : 'bg-amber-400'
              }`}
            />
            <span className="font-semibold text-white">{targetName}</span>
            <span className="text-[11px] text-zinc-500 font-mono">({action.target_instance_id})</span>
          </div>

          {/* Action State badge */}
          <span
            data-debug-id={`action-state-badge-${action.id}`}
            className={`flex items-center gap-1 rounded-md px-2 py-0.5 text-[11px] font-semibold border ${
              action.state === 'in_flight'
                ? 'border-amber-500/40 bg-amber-950/20 text-amber-300'
                : action.state === 'completed'
                ? 'border-zinc-700 bg-zinc-800 text-zinc-400'
                : 'border-emerald-500/30 bg-emerald-950/20 text-emerald-400'
            }`}
          >
            {action.state === 'in_flight' ? (
              <>
                <Icon name="zap" size={11} />
                <span>In Flight</span>
              </>
            ) : action.state === 'completed' ? (
              <span>Completed</span>
            ) : (
              <span>Active</span>
            )}
          </span>

          {/* Schedule status badge */}
          <span
            data-debug-id={`action-schedule-badge-${action.id}`}
            className={`flex items-center gap-1 rounded-md px-2 py-0.5 text-[11px] border ${
              isScheduled
                ? 'border-sky-500/30 bg-sky-500/10 text-sky-300'
                : 'border-zinc-800 bg-black/40 text-zinc-400'
            }`}
          >
            <Icon name={isScheduled ? 'clock' : 'zap'} size={12} />
            <span>{scheduleDesc}</span>
          </span>

          {/* Timezone badge if scheduled */}
          {isScheduled && action.timezone && (
            <span className="rounded-md border border-white/10 bg-black/30 px-1.5 py-0.5 text-[10px] text-zinc-400">
              {action.timezone}
            </span>
          )}

          {/* Blackout dates badge if any */}
          {blackouts.length > 0 && (
            <span
              className="rounded-md border border-amber-500/20 bg-amber-950/10 px-1.5 py-0.5 text-[10px] text-amber-300/80"
              title={`Blackout dates: ${blackouts.join(', ')}`}
            >
              {blackouts.length} blackout {blackouts.length === 1 ? 'date' : 'dates'}
            </span>
          )}
        </div>

        {/* Right: Actions Toolbar */}
        <div className="flex items-center gap-2">
          {/* Run Now Button */}
          <button
            type="button"
            data-debug-id={`action-run-now-btn-${action.id}`}
            disabled={isRunning}
            onClick={onRun}
            className="flex items-center gap-1.5 rounded-lg border border-sky-500/30 bg-sky-500/10 hover:bg-sky-500/20 px-3 py-1 text-xs font-semibold text-sky-300 transition-colors disabled:opacity-50"
            title="Execute this action immediately against the target instance"
          >
            {isRunning ? (
              <>
                <Icon name="refresh" size={11} className="animate-spin text-sky-400" />
                <span>Running...</span>
              </>
            ) : (
              <>
                <Icon name="play" size={11} />
                <span>Run Now</span>
              </>
            )}
          </button>

          {/* Edit Button */}
          <button
            type="button"
            data-debug-id={`action-edit-btn-${action.id}`}
            onClick={onEdit}
            className="rounded-lg border border-white/10 bg-white/5 hover:bg-white/10 p-1.5 text-zinc-400 hover:text-white transition-colors"
            title="Edit action"
          >
            <Icon name="pencil" size={14} />
          </button>

          {/* Delete Button */}
          <button
            type="button"
            data-debug-id={`action-delete-btn-${action.id}`}
            onClick={onDelete}
            className="rounded-lg border border-white/10 bg-white/5 hover:bg-red-500/20 hover:border-red-500/40 p-1.5 text-zinc-400 hover:text-red-400 transition-colors"
            title="Delete action"
          >
            <Icon name="trash" size={14} />
          </button>
        </div>
      </div>

      {/* Prompt Preview */}
      <div>
        <p
          data-debug-id={`action-prompt-text-${action.id}`}
          className={`text-xs text-zinc-200 leading-relaxed font-mono whitespace-pre-wrap ${
            expanded ? '' : 'line-clamp-2'
          }`}
        >
          {action.prompt_text}
        </p>
        {action.prompt_text.length > 140 && (
          <button
            type="button"
            onClick={() => setExpanded(!expanded)}
            className="mt-1 text-[11px] text-sky-400 hover:underline"
          >
            {expanded ? 'Show less' : 'Show full prompt'}
          </button>
        )}
      </div>

      {/* Next Execution Info Footer */}
      {isScheduled && (
        <div className="flex flex-wrap items-center justify-between text-[11px] text-zinc-500 border-t border-white/5 pt-2">
          <div className="flex items-center gap-1.5">
            <span>Next run:</span>
            {nextRuns.length > 0 ? (
              <span className="font-mono text-zinc-300">
                {formatInTimeZone(nextRuns[0], action.timezone || 'UTC')}
                <span className="ml-1.5 text-zinc-500">({timeZoneLabel(nextRuns[0], action.timezone || 'UTC')})</span>
              </span>
            ) : action.target_run_at ? (
              <span className="font-mono text-zinc-300">{action.target_run_at}</span>
            ) : (
              <span className="italic text-zinc-600">Pending calculation</span>
            )}
          </div>

          <div className="text-[10px] text-zinc-600 font-mono">
            ID: {action.id}
          </div>
        </div>
      )}
    </div>
  );
}
