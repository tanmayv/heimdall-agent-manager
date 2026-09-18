import { useState, useMemo } from 'react';

import { Badge, Button, Icon, IconButton, Input, PageShell, StatusPill } from '@ui';
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
        const inst = act.target_instance_id ? instanceMap.get(act.target_instance_id) : undefined;
        // Fold display name, instance id, and agent id into the filter so any of
        // the three finds the action (mirrors the target picker's search index).
        const instHaystack = [
          inst?.display_name,
          inst?.agent_name,
          act.target_instance_id,
          act.target_agent_id,
          act.target_bridge_id,
          inst?.agent_id,
        ].filter(Boolean).join(' ').toLowerCase();
        const promptMatch = act.prompt_text.toLowerCase().includes(q);
        const instMatch = instHaystack.includes(q);
        const cronMatch = (act.cron_expr || '').toLowerCase().includes(q);
        if (!promptMatch && !instMatch && !cronMatch) continue;
      }

      const inst = act.target_instance_id ? instanceMap.get(act.target_instance_id) : undefined;
      const projectId = inst?.project_id || act.target_project_id;
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
      const inst = action.target_instance_id ? instanceMap.get(action.target_instance_id) : undefined;
      const targetName = inst?.display_name || inst?.agent_name || action.target_instance_id || (action.target_agent_id ? `${action.target_agent_id} (${action.target_bridge_id || 'bridge'})` : 'agent');
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
    <PageShell
      width="full"
      title={
        <span className="inline-flex items-center gap-2.5">
          Actions
          <Badge data-debug-id="actions-total-count" tone="info">
            {totalActionsCount} {totalActionsCount === 1 ? 'action' : 'actions'}
          </Badge>
        </span>
      }
      description="Automated recurring prompts and on-demand tasks executed against your agent instances."
      actions={
        <Button variant="primary" data-debug-id="actions-create-btn" onClick={() => navigateTo('/actions/new')} leading={<Icon name="plus" size={16} />}>
          New Action
        </Button>
      }
    >
      <div data-debug-id="actions-page" className="space-y-6">

      {/* Feedback Banner */}
      {feedback && (
        <div
          data-debug-id="actions-feedback-banner"
          className={`flex items-center justify-between rounded-xl border p-3.5 text-xs font-medium animate-fade-in ${
            feedback.type === 'success'
              ? 'border-success/30 bg-success-soft text-success'
              : 'border-danger/30 bg-danger-soft text-danger'
          }`}
        >
          <div className="flex items-center gap-2">
            <Icon name={feedback.type === 'success' ? 'check' : 'alert'} size={14} />
            <span>{feedback.message}</span>
          </div>
          <IconButton icon="close" label="Dismiss" size="sm" onClick={() => setFeedback(null)} />
        </div>
      )}

      {/* Filter / Search Bar */}
      {totalActionsCount > 0 && (
        <div className="flex items-center gap-3">
          <Input
            type="search"
            data-debug-id="actions-search-input"
            value={searchQuery}
            onChange={setSearchQuery}
            placeholder="Filter actions by prompt, agent, or cron expression..."
            width="full"
            className="flex-1"
            leading={<Icon name="search" size={14} />}
            trailing={
              searchQuery ? (
                <IconButton icon="close" label="Clear search" size="sm" onClick={() => setSearchQuery('')} />
              ) : undefined
            }
          />
        </div>
      )}

      {/* Loading State */}
      {isLoading && (
        <div data-debug-id="actions-loading-state" className="flex items-center justify-center p-12 text-muted text-sm">
          <div className="flex items-center gap-2">
            <Icon name="refresh" size={14} className="animate-spin text-accent" />
            <span>Loading actions and projects...</span>
          </div>
        </div>
      )}

      {/* Error State */}
      {actionsError && !isLoading && (
        <div data-debug-id="actions-error-state" className="rounded-xl border border-danger/30 bg-danger-soft p-5 text-sm text-danger">
          Failed to load actions: {String((actionsError as any)?.error || (actionsError as any)?.message || actionsError)}
        </div>
      )}

      {/* Empty State */}
      {!isLoading && !actionsError && totalActionsCount === 0 && (
        <div
          data-debug-id="actions-empty-state"
          className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-subtle bg-surface/50 p-12 text-center"
        >
          <div className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-neutral-soft text-muted">
            <Icon name="clock" size={24} />
          </div>
          <h3 className="text-base font-semibold text-primary">No Actions Configured</h3>
          <p className="mt-1 max-w-md text-xs leading-relaxed text-muted">
            Actions allow you to schedule recurring prompts or trigger on-demand automation routines for any running agent instance.
          </p>
          <Button variant="primary" data-debug-id="actions-empty-create-btn" className="mt-5" onClick={() => navigateTo('/actions/new')} leading={<Icon name="plus" size={16} />}>
            Create Your First Action
          </Button>
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
                className="rounded-2xl border border-subtle bg-surface overflow-hidden"
              >
                {/* Collapsible Project Section Header */}
                <button
                  type="button"
                  data-debug-id={`actions-project-toggle-${group.id}`}
                  onClick={() => toggleProjectCollapse(group.id)}
                  className="w-full flex items-center justify-between px-4 py-3 bg-neutral-soft/50 hover:bg-neutral-soft border-b border-subtle transition-colors text-left"
                >
                  <div className="flex items-center gap-3">
                    <span className="text-muted">
                      <Icon name={isCollapsed ? 'chevron-right' : 'chevron-down'} size={14} />
                    </span>
                    <div className="flex items-center gap-2">
                      <Icon name="folder" size={15} className="text-accent" />
                      <span className="text-sm font-semibold text-primary">{group.name}</span>
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <span
                      data-debug-id={`actions-project-count-${group.id}`}
                      className="rounded-md bg-surface-raised border border-subtle px-2 py-0.5 text-xs text-muted"
                    >
                      {actionCount} {actionCount === 1 ? 'action' : 'actions'}
                    </span>
                  </div>
                </button>

                {/* Collapsible Project Actions Content */}
                {!isCollapsed && (
                  <div className="p-4 space-y-3">
                    {actionCount === 0 ? (
                      <p className="text-xs text-muted italic py-2">
                        No actions matching filter in this project.
                      </p>
                    ) : (
                      <div className="grid gap-3">
                        {group.actions.map((act) => (
                          <ActionCard
                            key={act.id}
                            action={act}
                            instance={act.target_instance_id ? instanceMap.get(act.target_instance_id) : undefined}
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
    </PageShell>
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

  const isAgentTargeted = !action.target_instance_id && Boolean(action.target_agent_id);
  const targetName = isAgentTargeted
    ? action.target_agent_id
    : (instance?.display_name || instance?.agent_name || action.target_instance_id || 'Unknown target');
  const instanceStatus = instance?.runtime_status || 'idle';

  return (
    <div
      data-debug-id={`action-row-${action.id}`}
      className="rounded-xl border border-subtle bg-surface-raised p-4 transition-colors hover:border-strong space-y-3"
    >
      {/* Top Header: Target Instance + State Badges + Actions Toolbar */}
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-subtle pb-2.5">
        {/* Left: Instance and state badges */}
        <div className="flex flex-wrap items-center gap-2">
          {/* Instance / Target badge */}
          <div
            data-debug-id={`action-instance-badge-${action.id}`}
            className="flex items-center gap-1.5 rounded-lg border border-subtle bg-surface px-2.5 py-1 text-xs text-primary"
          >
            {isAgentTargeted ? (
              <>
                <Icon name="bot" size={12} className="text-accent" />
                <span className="font-semibold text-primary">Agent: {targetName}</span>
                <span className="text-caption text-muted font-mono">({action.target_bridge_id || 'bridge'})</span>
              </>
            ) : (
              <>
                <span
                  className={`h-1.5 w-1.5 rounded-full ${
                    instanceStatus === 'running'
                      ? 'bg-success'
                      : instanceStatus === 'stopped'
                      ? 'bg-faint'
                      : 'bg-warning'
                  }`}
                />
                <span className="font-semibold text-primary">{targetName}</span>
                <span className="text-caption text-muted font-mono">({action.target_instance_id})</span>
              </>
            )}
          </div>

          {/* Action State badge */}
          <StatusPill
            data-debug-id={`action-state-badge-${action.id}`}
            tone={action.state === 'in_flight' ? 'warning' : action.state === 'completed' ? 'neutral' : 'success'}
          >
            {action.state === 'in_flight' ? (
              <>
                <Icon name="zap" size="sm" />
                <span>In Flight</span>
              </>
            ) : action.state === 'completed' ? (
              'Completed'
            ) : (
              'Active'
            )}
          </StatusPill>

          {/* Schedule status badge */}
          <span
            data-debug-id={`action-schedule-badge-${action.id}`}
            className={`flex items-center gap-1 rounded-md px-2 py-0.5 text-caption border ${
              isScheduled
                ? 'border-info/30 bg-info-soft text-info'
                : 'border-subtle bg-surface text-muted'
            }`}
          >
            <Icon name={isScheduled ? 'clock' : 'zap'} size={12} />
            <span>{scheduleDesc}</span>
          </span>

          {/* Timezone badge if scheduled */}
          {isScheduled && action.timezone && (
            <span className="rounded-md border border-subtle bg-surface px-1.5 py-0.5 text-[10px] text-muted">
              {action.timezone}
            </span>
          )}

          {/* Blackout dates badge if any */}
          {blackouts.length > 0 && (
            <span
              className="rounded-md border border-warning/30 bg-warning-soft px-1.5 py-0.5 text-[10px] text-warning"
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
            className="flex items-center gap-1.5 rounded-lg border border-info/30 bg-info-soft hover:bg-info/20 px-3 py-1 text-xs font-semibold text-info transition-colors disabled:opacity-50"
            title="Execute this action immediately against the target instance"
          >
            {isRunning ? (
              <>
                <Icon name="refresh" size={11} className="animate-spin text-info" />
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
          <IconButton icon="pencil" label="Edit action" variant="solid" size="sm" data-debug-id={`action-edit-btn-${action.id}`} onClick={onEdit} />

          {/* Delete Button */}
          <IconButton icon="trash" label="Delete action" variant="danger" size="sm" data-debug-id={`action-delete-btn-${action.id}`} onClick={onDelete} />
        </div>
      </div>

      {/* Prompt Preview */}
      <div>
        <p
          data-debug-id={`action-prompt-text-${action.id}`}
          className={`text-xs text-primary leading-relaxed font-mono whitespace-pre-wrap ${
            expanded ? '' : 'line-clamp-2'
          }`}
        >
          {action.prompt_text}
        </p>
        {action.prompt_text.length > 140 && (
          <button
            type="button"
            onClick={() => setExpanded(!expanded)}
            className="mt-1 text-caption text-accent hover:underline"
          >
            {expanded ? 'Show less' : 'Show full prompt'}
          </button>
        )}
      </div>

      {/* Next Execution Info Footer */}
      {isScheduled && (
        <div className="flex flex-wrap items-center justify-between text-caption text-muted border-t border-subtle pt-2">
          <div className="flex items-center gap-1.5">
            <span>Next run:</span>
            {nextRuns.length > 0 ? (
              <span className="font-mono text-primary">
                {formatInTimeZone(nextRuns[0], action.timezone || 'UTC')}
                <span className="ml-1.5 text-muted">({timeZoneLabel(nextRuns[0], action.timezone || 'UTC')})</span>
              </span>
            ) : action.target_run_at ? (
              <span className="font-mono text-primary">{action.target_run_at}</span>
            ) : (
              <span className="italic text-faint">Pending calculation</span>
            )}
          </div>

          <div className="text-[10px] text-faint font-mono">
            ID: {action.id}
          </div>
        </div>
      )}
    </div>
  );
}
