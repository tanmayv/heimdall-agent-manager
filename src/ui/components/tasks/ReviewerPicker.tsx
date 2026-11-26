import React from 'react';
import { Checkbox, Text } from '@ui';

/** The literal reviewer that stands for the chain owner (REQ-SCHED-4). */
export const USER_REVIEWER = 'user';

export interface ReviewerPickerProps {
  /** Agent catalogue entries ({agent_id, name, state}). */
  agents: any[];
  /** The task's assignee: it cannot review its own work (reviewer_is_assignee). */
  assignee: string;
  /** Selected reviewer agent ids (never 'user'). */
  reviewers: string[];
  onReviewersChange: (next: string[]) => void;
  userApproval: boolean;
  onUserApprovalChange: (next: boolean) => void;
  /** Shown after "User"; '' while the caller's identity is loading. */
  userLabel?: string;
  agentName: (agentId: string) => string;
  debugPrefix: string;
}

/**
 * Who must approve a task: any listed agent, and optionally the user. Every
 * one of them must approve the current attempt (REQ-SCHED-5).
 */
export function ReviewerPicker({
  agents,
  assignee,
  reviewers,
  onReviewersChange,
  userApproval,
  onUserApprovalChange,
  userLabel = '',
  agentName,
  debugPrefix,
}: ReviewerPickerProps) {
  const toggle = (id: string, on: boolean) =>
    onReviewersChange(on ? Array.from(new Set([...reviewers, id])) : reviewers.filter((r) => r !== id));
  const active = agents.filter((a) => String(a.state || 'active').toLowerCase() === 'active');
  // A reviewer that is no longer in the catalogue stays visible so it can be removed.
  const listed = new Set(active.map((a) => String(a.agent_id || a.agentId || a.id || '')));
  const missing = reviewers.filter((id) => !listed.has(id));
  return (
    <div className="space-y-1.5" data-debug-id={`${debugPrefix}-reviewers`}>
      <Text as="p" role="caption" tone="muted">
        Each reviewer must approve:
      </Text>
      <div className="max-h-48 space-y-1 overflow-y-auto">
        <Checkbox
          data-debug-id={`${debugPrefix}-reviewer-user`}
          checked={userApproval}
          onChange={onUserApprovalChange}
          label={<span>User{userLabel ? <span className="text-muted"> ({userLabel})</span> : null}</span>}
        />
        {[...active.map((a) => String(a.agent_id || a.agentId || a.id || '')), ...missing].filter(Boolean).map((id) => {
          const isAssignee = id === assignee;
          return (
            <Checkbox
              key={id}
              data-debug-id={`${debugPrefix}-reviewer-${id}`}
              checked={reviewers.includes(id)}
              disabled={isAssignee && !reviewers.includes(id)}
              onChange={(on) => toggle(id, on)}
              label={
                <span>
                  {agentName(id)}
                  {isAssignee && <span className="text-faint"> (assignee, can't review its own work)</span>}
                </span>
              }
            />
          );
        })}
      </div>
    </div>
  );
}
