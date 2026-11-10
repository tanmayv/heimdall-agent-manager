// origin/main's aux Chain overview behind a props seam. On origin/main it read
// the chain, its tasks, artifacts and the project VCS with Hub hooks and ran
// agent start/stop/restart and user reviews as Hub mutations; here the data
// source passes members, tickets (origin/main's wire shape), names and the VCS
// summary, and supplies the actions, so the panel calls no Hub endpoint. For a
// Bridge-owned chain OwnerChainView is that source (ownerChainAdapter).
//
// Left out (no owner-local source): Chain Artifacts (Hub artifacts by chain id,
// with ArtifactViewer). Owner extras passed in as slots: the Add agent control
// (agents header), the chain's recent activity (history.read) and token usage.

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Badge,
  Button,
  Icon,
  IconButton,
  Spinner,
  Textarea,
  StatusDot,
  StatusPill,
  Text,
  type IconName,
  type Tone,
} from '@ui';
import type { TaskWire } from '../../api/taskWire';
import type { VcsChangedFile } from '../../api/endpoints/projectVcs';
import Markdown from '../Markdown';
import { buildRouteHash } from '../../utils/appLocation';
import {
  attentionReason,
  buildMemberCurrentTaskMap,
  isAttentionNeeded,
  isOngoingTask,
  memberTicketText,
  reviewHolders,
} from './chainMemberTickets';
import { normalizeTaskState, TASK_STATE_LABELS } from '../tasks/taskV2Types';
import { EMPTY_TASK_NAMES, participantLabel, type TaskNames } from '../tasks/taskNames';
import { agentRuntimeActions, type ChainOverviewAttention, type ChainOverviewMember } from '../tasks/ownerChainAdapter';
import {
  readChainOverviewCollapsedState,
  writeChainOverviewCollapsedState,
} from '../../utils/clientPersistence';

export type { ChainOverviewMember, ChainOverviewAttention } from '../tasks/ownerChainAdapter';

/** What the overview can do; an action the source cannot do is left out and not offered. */
export interface ChainOverviewActions {
  /** A change is in flight: every control is disabled. */
  busy: boolean;
  start?: (instanceId: string) => Promise<unknown>;
  stop?: (instanceId: string) => Promise<unknown>;
  restart?: (instanceId: string) => Promise<unknown>;
  /** Remove a worker or reviewer from the chain (never the coordinator). */
  remove?: (member: ChainOverviewMember) => Promise<unknown>;
  /** The ticket's description for the review card. */
  loadDescription?: (taskId: string) => Promise<string>;
  /** Your verdict on a ticket in review; resolves false when it was not recorded. */
  review?: (taskId: string, verdict: 'approve' | 'request_changes', comment: string) => Promise<boolean>;
}

/** The project's working tree (origin/main read it with the project VCS hooks). */
export interface ChainOverviewVcs {
  branch?: string;
  files: VcsChangedFile[];
}

export interface ChainOverviewPanelProps {
  members: ChainOverviewMember[];
  /** Members are still being read. */
  membersLoading?: boolean;
  tasks: TaskWire[];
  names?: TaskNames;
  /** The first chain read is running. */
  loading?: boolean;
  actions: ChainOverviewActions;
  /** "Attention needed" rule (default origin/main's: in review and waiting on you). */
  attention?: ChainOverviewAttention;
  /** The conversation's own agent: highlighted, and the collapsed-state key. */
  agentInstanceId?: string;
  /** The agents header's action (Add agent). */
  agentsAction?: React.ReactNode;
  /** Recent chain activity. */
  activitySlot?: React.ReactNode;
  /** Token usage. */
  tokenUsageSlot?: React.ReactNode;
  /** The project VCS summary; null/undefined hides the section. */
  vcs?: ChainOverviewVcs | null;
  onSelectTask?: (taskId: string) => void;
  onOpenFileDiff?: (filePath: string) => void;
  onOpenVcsFiles?: () => void;
  onOpenAgentChat?: (agentInstanceId: string, title?: string) => void;
  onOpenAgentPty?: (agentInstanceId: string, title?: string) => void;
  isMobile?: boolean;
  className?: string;
}

// Priority tone helper
function priorityTone(priority: string): Tone {
  const p = String(priority || '').toLowerCase();
  if (p === 'p0') return 'danger';
  if (p === 'p1') return 'warning';
  if (p === 'p2') return 'info';
  return 'neutral';
}

// Status tone helper
function statusTone(status: string): Tone {
  const s = String(status || '').toLowerCase();
  if (s === 'running' || s === 'live' || s === 'validated_good' || s === 'completed' || s === 'done') return 'success';
  if (s === 'in_progress' || s === 'in_validation' || s === 'starting' || s === 'launching' || s === 'stopping') return 'info';
  if (s === 'queued' || s === 'warning' || s === 'in_review') return 'warning';
  if (s === 'stopped' || s === 'failed' || s === 'validated_not_good' || s === 'cancelled') return 'danger';
  return 'neutral';
}

const AGENT_STATUS_LABEL: Record<string, string> = {
  running: 'Running', idle: 'Running', ready: 'Running', launching: 'Starting', starting: 'Starting',
  stopping: 'Stopping', stopped: 'Stopped', failed: 'Failed',
};

/** A member's instance status as a word ('' while unknown). */
export function agentStatusLabel(status: string): string {
  return AGENT_STATUS_LABEL[status] ?? '';
}

/** The running instance holding a task's work lease, if any. */
function workHolder(task: TaskWire): string {
  const lease = (Array.isArray(task?.leases) ? task.leases : []).find((l) => (l?.kind || 'work') === 'work');
  return String(lease?.holder_instance_id || '');
}

/** Acceptance checklist lines ("[ ] …", "- [x] …") in a description. */
export function checklistItems(description: string): { checked: boolean; text: string }[] {
  if (!description) return [];
  return description
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => /^(\[[\sxX]\]|-\s*\[[\sxX]\])/.test(l))
    .map((l) => ({ checked: /\[[xX]\]/.test(l), text: l.replace(/^[-*]?\s*\[[\sxX]\]\s*/, '') }));
}

function SectionToggle({
  id, icon, label, collapsed, onToggle, tone,
}: { id: string; icon: IconName; label: React.ReactNode; collapsed: boolean; onToggle: () => void; tone?: 'warning' }) {
  return (
    <button
      type="button"
      data-debug-id={`chain-overview-section-toggle-${id}`}
      onClick={onToggle}
      aria-expanded={!collapsed}
      className="group flex min-w-0 items-center gap-2 text-left"
    >
      <Icon name={collapsed ? 'chevron-right' : 'chevron-down'} size={14} className={tone ? 'text-warning' : 'text-muted group-hover:text-primary'} />
      <Icon name={icon} size={14} className={tone ? 'text-warning' : 'text-muted'} />
      <Text as="h3" role="overline" tone={tone ?? 'faint'}>{label}</Text>
    </button>
  );
}

// The review card of an attention ticket: its description (or acceptance
// checklist) and your verdict.
function AttentionTaskReviewCard({
  task,
  actions,
  onVoteSuccess,
}: {
  task: TaskWire;
  actions: ChainOverviewActions;
  onVoteSuccess?: () => void;
}) {
  const taskId = task.task_id;
  const [description, setDescription] = useState<string | null>(actions.loadDescription ? null : String(task.description || ''));
  const [voteComment, setVoteComment] = useState('');
  const [voteError, setVoteError] = useState('');
  const [isVoting, setIsVoting] = useState(false);
  const { loadDescription } = actions;

  useEffect(() => {
    if (!loadDescription) return undefined;
    let active = true;
    loadDescription(taskId)
      .then((d) => { if (active) setDescription(d); })
      .catch(() => { if (active) setDescription(String(task.description || '')); });
    return () => { active = false; };
  }, [loadDescription, taskId]); // eslint-disable-line react-hooks/exhaustive-deps

  const acceptance = task.brief?.acceptance ?? [];
  const checklist = useMemo(() => checklistItems(description ?? ''), [description]);
  const reviewable = normalizeTaskState(task.state) === 'in_review' && Boolean(actions.review);

  const handleVote = async (verdict: 'approve' | 'request_changes') => {
    if (!actions.review) return;
    setVoteError('');
    setIsVoting(true);
    try {
      if (await actions.review(taskId, verdict, voteComment.trim())) onVoteSuccess?.();
      else setVoteError('Review action failed. Please try again.');
    } catch (err: any) {
      setVoteError(err?.message || 'Review action failed. Please try again.');
    } finally {
      setIsVoting(false);
    }
  };

  return (
    <div
      data-debug-id={`chain-overview-attention-review-${taskId}`}
      className="mt-3 space-y-3 rounded-[var(--radius-lg)] border border-subtle bg-surface p-3"
    >
      <div className="flex items-center justify-between gap-2">
        <Text as="span" role="label">{reviewable ? 'Your review' : 'Ticket'}</Text>
        <Text as="code" role="code-sm" tone="muted">{taskId}</Text>
      </div>

      {description === null ? (
        <div className="flex items-center gap-2 py-2 text-xs text-muted">
          <Spinner size="sm" />
          <span>Loading ticket details…</span>
        </div>
      ) : acceptance.length > 0 || checklist.length > 0 ? (
        <div className="space-y-2 rounded-[var(--radius-sm)] bg-surface-raised p-3">
          <Text as="span" role="overline" tone="faint">Acceptance criteria</Text>
          <ul className="space-y-1 text-xs">
            {(checklist.length ? checklist : acceptance.map((text) => ({ checked: false, text }))).map((item, idx) => (
              <li key={idx} className="flex items-start gap-2">
                <span className={item.checked ? 'text-success' : 'text-muted'}>
                  <Icon name={item.checked ? 'check' : 'alert'} size={14} />
                </span>
                <span className={item.checked ? 'text-muted line-through' : 'text-primary'}>{item.text}</span>
              </li>
            ))}
          </ul>
        </div>
      ) : description ? (
        <div className="max-h-48 overflow-y-auto rounded-[var(--radius-sm)] bg-surface-raised p-2 text-xs">
          <Markdown source={description} compact copyAll={false} />
        </div>
      ) : (
        <Text as="p" role="caption" tone="muted">No description provided for this ticket.</Text>
      )}

      {reviewable && (
        <>
          <Textarea
            aria-label="Review feedback"
            data-debug-id={`chain-overview-vote-comment-${taskId}`}
            value={voteComment}
            onChange={setVoteComment}
            placeholder="Add comments or required fixes before voting…"
            rows={2}
            size="sm"
            width="full"
          />
          {voteError && <Text as="p" role="caption" tone="danger">{voteError}</Text>}
          <div className="flex items-center gap-2 pt-1">
            <Button
              type="button"
              tone="success"
              size="sm"
              disabled={isVoting || actions.busy}
              data-debug-id={`chain-overview-vote-lgtm-${taskId}`}
              onClick={() => void handleVote('approve')}
              className="flex-1"
            >
              {isVoting ? <Spinner size="sm" /> : <Icon name="check" size={14} />}
              <span>Approve</span>
            </Button>
            <Button
              type="button"
              tone="danger"
              size="sm"
              disabled={isVoting || actions.busy || !voteComment.trim()}
              data-debug-id={`chain-overview-vote-ngtm-${taskId}`}
              onClick={() => void handleVote('request_changes')}
              className="flex-1"
            >
              {isVoting ? <Spinner size="sm" /> : <Icon name="close" size={14} />}
              <span>Request changes</span>
            </Button>
          </div>
        </>
      )}
    </div>
  );
}

export default function ChainOverviewPanel({
  members,
  membersLoading = false,
  tasks,
  names = EMPTY_TASK_NAMES,
  loading = false,
  actions,
  attention,
  agentInstanceId,
  agentsAction,
  activitySlot,
  tokenUsageSlot,
  vcs,
  onSelectTask,
  onOpenFileDiff,
  onOpenVcsFiles,
  onOpenAgentChat,
  onOpenAgentPty,
  className = 'flex h-full min-h-0 flex-col overflow-y-auto',
}: ChainOverviewPanelProps) {
  // Collapsed sections state with client persistence (default open)
  const [collapsedSections, setCollapsedSections] = useState<Record<string, boolean>>(() =>
    readChainOverviewCollapsedState(agentInstanceId)
  );

  useEffect(() => {
    setCollapsedSections(readChainOverviewCollapsedState(agentInstanceId));
  }, [agentInstanceId]);

  const toggleSection = useCallback(
    (sectionKey: string) => {
      setCollapsedSections((prev) => {
        const next = { ...prev, [sectionKey]: !prev[sectionKey] };
        writeChainOverviewCollapsedState(next, agentInstanceId);
        return next;
      });
    },
    [agentInstanceId]
  );

  const isCollapsed = useCallback((key: string) => Boolean(collapsedSections[key]), [collapsedSections]);
  const [expandedAttentionTaskId, setExpandedAttentionTaskId] = useState<string | null>(null);

  const vcsFiles: VcsChangedFile[] = vcs?.files ?? [];
  const vcsModifiedCount = vcsFiles.filter((f) => f.status === 'modified').length;
  const vcsStagedCount = vcsFiles.filter((f) => f.staged).length;
  const vcsUntrackedCount = vcsFiles.filter((f) => f.status === 'untracked').length;

  const ongoingTasks = useMemo(() => tasks.filter(isOngoingTask), [tasks]);
  const attentionNeeded = attention?.needed ?? isAttentionNeeded;
  const reasonOf = attention?.reason ?? attentionReason;
  const attentionTasks = useMemo(() => tasks.filter(attentionNeeded), [tasks, attentionNeeded]);

  // What each member is on: the task it holds a work or review lease for.
  const memberCurrentTaskMap = useMemo(() => buildMemberCurrentTaskMap(tasks), [tasks]);

  const holderLabel = (instanceId: string) => names.instance(instanceId) || members.find((m) => m.instanceId === instanceId)?.name || instanceId;
  const reviewerLabel = (task: TaskWire): string => {
    const holder = reviewHolders(task)[0];
    if (holder) return holderLabel(holder);
    const first = task.brief?.reviewers?.[0];
    if (first) return participantLabel(names, first);
    return task.requires_user_approval ? 'You' : 'None';
  };

  // Open the agent's chat (the aux host opens a sub-agent tab) or navigate to it.
  const handleNavigateToAgent = useCallback(
    (targetInstanceId: string, displayName?: string) => {
      if (!targetInstanceId) return;
      if (onOpenAgentChat) {
        onOpenAgentChat(targetInstanceId, displayName);
        return;
      }
      window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(targetInstanceId)}`, '');
    },
    [onOpenAgentChat]
  );

  const runAgent = (action: 'start' | 'stop' | 'restart', instanceId: string, e: React.MouseEvent) => {
    e.stopPropagation();
    void actions[action]?.(instanceId);
  };

  const taskMeta = (task: TaskWire) => (
    <div className="mt-1 flex items-center justify-between gap-2 text-caption text-muted">
      <span className="max-w-36 truncate">
        Worker: <strong className="font-normal text-primary">{workHolder(task) ? holderLabel(workHolder(task)) : 'Unassigned'}</strong>
      </span>
      <span className="max-w-36 truncate">
        Reviewer: <strong className="font-normal text-primary">{reviewerLabel(task)}</strong>
      </span>
    </div>
  );

  return (
    <div data-debug-id="chain-overview-panel" className={`${className} space-y-6 bg-surface p-4 text-left text-primary`}>
      {loading && (
        <div role="status" className="flex items-center justify-center gap-2 py-8 text-xs text-muted">
          <Spinner size="sm" /> Loading chain overview…
        </div>
      )}

      {/* Chain agents */}
      <section data-debug-id="chain-overview-section-agents" className="space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <SectionToggle id="agents" icon="bot" label={`Chain agents (${members.length})`} collapsed={isCollapsed('agents')} onToggle={() => toggleSection('agents')} />
          {agentsAction}
        </div>

        {!isCollapsed('agents') && (
          membersLoading && members.length === 0 ? (
            <Text as="p" role="caption" tone="muted" aria-live="polite">Loading agents…</Text>
          ) : members.length === 0 ? (
            <Text as="p" role="caption" tone="muted" data-debug-id="chain-overview-no-agents">No agents yet. Start the coordinator; it adds workers and reviewers to the fleet.</Text>
          ) : (
            <div className="flex flex-col gap-0.5">
              {members.map((member) => {
                const instId = member.instanceId;
                const name = member.name || instId;
                const status = member.status;
                const label = member.enabled ? agentStatusLabel(status) : 'Removed';
                const runtime = member.enabled ? agentRuntimeActions(status).filter((a) => Boolean(actions[a])) : [];
                const currentTask = memberCurrentTaskMap.get(instId);
                const isSelected = Boolean(agentInstanceId && instId === agentInstanceId);

                return (
                  <div
                    key={instId}
                    role="button"
                    tabIndex={0}
                    data-debug-id={`chain-overview-agent-row-${instId}`}
                    aria-current={isSelected ? 'true' : undefined}
                    title={`Open ${name} chat`}
                    onClick={() => handleNavigateToAgent(instId, name)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        handleNavigateToAgent(instId, name);
                      }
                    }}
                    className={`group flex min-h-8 min-w-0 cursor-pointer items-center gap-2 rounded-[var(--radius-md)] px-2 text-xs transition-colors hover:bg-neutral-soft ${
                      isSelected ? 'bg-neutral-soft' : ''
                    } ${member.enabled ? '' : 'opacity-60'}`}
                  >
                    <StatusDot tone={member.enabled ? statusTone(status) : 'neutral'} label={label || 'Status unknown'} size="sm" />
                    <span className={`max-w-[45%] shrink-0 truncate ${isSelected ? 'font-semibold' : 'font-medium'} text-primary`} title={instId}>
                      {name}
                    </span>
                    {member.role && <Badge tone={member.role === 'coordinator' ? 'info' : 'neutral'}>{member.role}</Badge>}
                    {label && (
                      <span className="shrink-0 text-caption text-muted" data-debug-id={`chain-overview-agent-status-${instId}`}>{label}</span>
                    )}
                    <span
                      className="min-w-0 flex-1 truncate text-caption text-muted"
                      data-debug-id={`chain-overview-agent-ticket-${instId}`}
                      title={memberTicketText(currentTask)}
                    >
                      {currentTask ? (
                        <>
                          {currentTask.kind === 'review' && <span className="text-info">Reviewing: </span>}
                          <span className="truncate">{currentTask.task.title || currentTask.task.task_id}</span>
                          {currentTask.reviewRole && <span className="text-faint"> ({currentTask.reviewRole})</span>}
                        </>
                      ) : (
                        <span className="text-faint">No ticket</span>
                      )}
                    </span>

                    <div className="flex shrink-0 items-center gap-0.5" onClick={(e) => e.stopPropagation()}>
                      {onOpenAgentPty && (
                        <IconButton
                          data-debug-id={`chain-overview-open-pty-${instId}`}
                          icon="terminal"
                          label="Open live terminal"
                          size="sm"
                          variant="ghost"
                          onClick={(e) => { e.stopPropagation(); onOpenAgentPty(instId, name); }}
                        />
                      )}
                      {runtime.map((action) => (
                        <IconButton
                          key={action}
                          data-debug-id={`chain-overview-${action}-agent-${instId}`}
                          icon={action === 'start' ? 'play' : action === 'stop' ? 'stop' : 'refresh'}
                          label={`${action === 'start' ? 'Start' : action === 'stop' ? 'Stop' : 'Restart'} ${name}`}
                          size="sm"
                          variant={action === 'stop' ? 'danger' : 'ghost'}
                          disabled={actions.busy}
                          onClick={(e) => runAgent(action, instId, e)}
                        />
                      ))}
                      {actions.remove && member.enabled && member.role !== 'coordinator' && member.agentId && (
                        <IconButton
                          data-debug-id={`chain-overview-remove-agent-${instId}`}
                          icon="trash"
                          label={`Remove ${name} from the chain`}
                          size="sm"
                          variant="ghost"
                          disabled={actions.busy}
                          onClick={(e) => { e.stopPropagation(); void actions.remove?.(member); }}
                        />
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )
        )}
      </section>

      {/* Attention needed (placed high for urgent visibility) */}
      {attentionTasks.length > 0 && (
        <section data-debug-id="chain-overview-section-attention" className="space-y-3">
          <SectionToggle id="attention" icon="alert" tone="warning" label={`Attention needed (${attentionTasks.length})`} collapsed={isCollapsed('attention')} onToggle={() => toggleSection('attention')} />

          {!isCollapsed('attention') && (
            <div className="grid gap-2">
              {attentionTasks.map((task) => {
                const taskId = task.task_id;
                const isExpanded = expandedAttentionTaskId === taskId;
                const state = normalizeTaskState(task.state);
                return (
                  <div
                    key={taskId}
                    data-debug-id={`chain-overview-attention-task-${taskId}`}
                    className="rounded-[var(--radius-lg)] border border-subtle bg-warning-soft p-3"
                  >
                    <div className="flex items-start justify-between gap-2">
                      <button
                        type="button"
                        data-debug-id={`chain-overview-attention-open-${taskId}`}
                        onClick={() => onSelectTask?.(taskId)}
                        className="min-w-0 flex-1 text-left"
                      >
                        <div className="flex flex-wrap items-center gap-2">
                          <Badge tone={priorityTone(task.priority)}>{(task.priority || 'p2').toUpperCase()}</Badge>
                          <StatusPill tone={statusTone(state)}>{TASK_STATE_LABELS[state]}</StatusPill>
                          <span className="truncate text-caption font-medium text-warning">{reasonOf(task)}</span>
                        </div>
                        <Text as="h4" role="label" className="mt-1 line-clamp-2">{task.title || taskId}</Text>
                        {taskMeta(task)}
                      </button>
                      <IconButton
                        icon={isExpanded ? 'chevron-down' : 'chevron-right'}
                        label={isExpanded ? 'Hide review panel' : 'Show review panel'}
                        size="sm"
                        variant="ghost"
                        data-debug-id={`chain-overview-attention-toggle-${taskId}`}
                        onClick={() => setExpandedAttentionTaskId((prev) => (prev === taskId ? null : taskId))}
                      />
                    </div>

                    {isExpanded && (
                      <AttentionTaskReviewCard task={task} actions={actions} onVoteSuccess={() => setExpandedAttentionTaskId(null)} />
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </section>
      )}

      {/* Ongoing tasks */}
      <section data-debug-id="chain-overview-section-ongoing-tasks" className="space-y-3">
        <div className="flex items-center justify-between gap-2">
          <SectionToggle id="ongoingTasks" icon="tasks" label={`Ongoing tasks (${ongoingTasks.length})`} collapsed={isCollapsed('ongoingTasks')} onToggle={() => toggleSection('ongoingTasks')} />
          {onSelectTask && tasks.length > 0 && (
            <button
              type="button"
              data-debug-id="chain-overview-all-tasks"
              onClick={() => onSelectTask('')}
              className="text-caption font-medium text-accent hover:underline"
            >
              All tasks ({tasks.length})
            </button>
          )}
        </div>

        {!isCollapsed('ongoingTasks') && (
          ongoingTasks.length === 0 ? (
            <Text as="p" role="caption" tone="muted">No tickets in progress or in review.</Text>
          ) : (
            <div className="grid gap-2">
              {ongoingTasks.map((task) => {
                const taskId = task.task_id;
                const state = normalizeTaskState(task.state);
                return (
                  <button
                    type="button"
                    key={taskId}
                    data-debug-id={`chain-overview-ongoing-task-${taskId}`}
                    onClick={() => onSelectTask?.(taskId)}
                    className="rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-3 text-left transition-colors hover:bg-neutral-soft"
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex items-center gap-2">
                        <Badge tone={priorityTone(task.priority)}>{(task.priority || 'p2').toUpperCase()}</Badge>
                        <StatusPill tone={statusTone(state)}>{TASK_STATE_LABELS[state]}</StatusPill>
                      </div>
                      <Text as="code" role="code-sm" tone="muted" truncate>{taskId}</Text>
                    </div>
                    <Text as="h4" role="label" className="mt-1 line-clamp-1">{task.title || taskId}</Text>
                    {taskMeta(task)}
                  </button>
                );
              })}
            </div>
          )
        )}
      </section>

      {activitySlot && (
        <section data-debug-id="chain-overview-section-activity" className="space-y-3">
          <SectionToggle id="activity" icon="layers" label="Activity" collapsed={isCollapsed('activity')} onToggle={() => toggleSection('activity')} />
          {!isCollapsed('activity') && activitySlot}
        </section>
      )}

      {tokenUsageSlot && (
        <section data-debug-id="chain-overview-section-token-usage" className="space-y-3">
          <SectionToggle id="tokenUsage" icon="spark" label="Token usage" collapsed={isCollapsed('tokenUsage')} onToggle={() => toggleSection('tokenUsage')} />
          {!isCollapsed('tokenUsage') && tokenUsageSlot}
        </section>
      )}

      {/* VCS changes */}
      {vcs ? (
        <section data-debug-id="chain-overview-section-vcs" className="space-y-3">
          <div className="flex items-center justify-between gap-2">
            <SectionToggle id="vcs" icon="layers" label="VCS changes" collapsed={isCollapsed('vcs')} onToggle={() => toggleSection('vcs')} />
            {onOpenVcsFiles && (
              <button
                type="button"
                data-debug-id="chain-overview-vcs-all-changes-btn"
                onClick={onOpenVcsFiles}
                className="text-caption font-medium text-accent hover:underline"
              >
                All changes
              </button>
            )}
          </div>

          {!isCollapsed('vcs') && (
            <div className="space-y-2 rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-3">
              <div className="flex flex-wrap items-center gap-2 text-xs">
                <Badge tone="warning">{vcsModifiedCount} Modified</Badge>
                <Badge tone="success">{vcsStagedCount} Staged</Badge>
                <Badge tone="neutral">{vcsUntrackedCount} Untracked</Badge>
                {vcs.branch && (
                  <Text as="code" role="code-sm" tone="muted" truncate className="ml-auto max-w-32">{vcs.branch}</Text>
                )}
              </div>

              {vcsFiles.length === 0 ? (
                <Text as="p" role="caption" tone="muted" className="pt-1">Working tree is clean.</Text>
              ) : (
                <div className="max-h-48 space-y-1 overflow-y-auto pt-1">
                  {vcsFiles.slice(0, 10).map((file) => {
                    const statusChar =
                      file.status === 'modified' ? 'M'
                      : file.status === 'added' ? 'A'
                      : file.status === 'deleted' ? 'D'
                      : file.status === 'renamed' ? 'R'
                      : 'U';
                    const statusColor =
                      file.status === 'modified' ? 'text-warning bg-warning-soft'
                      : file.status === 'added' ? 'text-success bg-success-soft'
                      : file.status === 'deleted' ? 'text-danger bg-danger-soft'
                      : 'text-muted bg-neutral-soft';
                    return (
                      <button
                        type="button"
                        key={file.path}
                        data-debug-id={`chain-overview-vcs-file-${file.path}`}
                        onClick={() => onOpenFileDiff?.(file.path)}
                        className="flex w-full items-center justify-between gap-2 rounded-[var(--radius-sm)] px-2 py-1 text-left text-xs transition-colors hover:bg-neutral-soft"
                      >
                        <span className="flex min-w-0 items-center gap-2">
                          <span className={`grid h-4 w-4 place-items-center rounded-[var(--radius-sm)] text-caption font-semibold ${statusColor}`}>{statusChar}</span>
                          <span className="truncate font-mono text-caption text-primary" title={file.path}>{file.path}</span>
                        </span>
                        {(file.additions > 0 || file.deletions > 0) && (
                          <span className="shrink-0 font-mono text-caption">
                            {file.additions > 0 && <span className="text-success">+{file.additions} </span>}
                            {file.deletions > 0 && <span className="text-danger">-{file.deletions}</span>}
                          </span>
                        )}
                      </button>
                    );
                  })}
                  {vcsFiles.length > 10 && (
                    <div className="pt-1 text-center">
                      <button type="button" onClick={onOpenVcsFiles} className="text-caption text-accent hover:underline">
                        + {vcsFiles.length - 10} more files
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>
          )}
        </section>
      ) : null}
    </div>
  );
}
