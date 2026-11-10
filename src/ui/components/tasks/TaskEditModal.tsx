// origin/main's assignee / reviewers / dependencies dialog behind a props
// seam: the caller supplies the agent choices, the optional review roles and
// the save, so a Bridge-owned chain writes owner commands instead of the Hub
// task update. `details` (title and description) is offered by callers that
// can edit them.

import React, { useEffect, useMemo, useState } from 'react';
import { Badge, Button, Checkbox, Input, Modal, ModalBody, ModalFooter, Select, StatusPill, Text, Textarea } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { TASK_STATE_LABELS, TASK_STATE_TONE, normalizeTaskState } from './taskV2Types';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';

export type TaskEditField = 'assignee' | 'reviewers' | 'deps' | 'details';

/** One agent a ticket can be assigned to or reviewed by. */
export interface TaskEditAgent { agentId: string; name: string }

/** A chain review role (optional layer) with its holders' agent ids. */
export interface TaskEditRole { name: string; description: string; holders: string[] }

/** What a save changes; only the fields of the open editor are set. */
export type TaskEditChange =
  | { field: 'assignee'; assignee: string }
  | { field: 'reviewers'; reviewers: string[]; reviewRoles: string[]; requiresUserApproval: boolean }
  | { field: 'deps'; dependsOn: string[] }
  | { field: 'details'; title: string; description: string };

export interface TaskEditModalProps {
  task: TaskWire;
  field: TaskEditField | null;
  onClose: () => void;
  /** Resolves to '' once saved, else the error to show. */
  onSave: (change: TaskEditChange) => Promise<string>;
  /** All tasks of the chain, for the dependency picker. */
  tasks?: TaskWire[];
  /** Agents for the assignee and reviewer pickers. */
  agents?: TaskEditAgent[];
  /** Absent: no review roles (the chain has none to offer). */
  roles?: TaskEditRole[];
  names?: TaskNames;
}

const TITLES: Record<TaskEditField, string> = {
  assignee: 'Who works on it',
  reviewers: 'Who must approve it',
  deps: 'What it waits for',
  details: 'Title and description',
};

/**
 * Change a task's assignee, required reviews or dependencies (plan REQ-UI-11).
 * Agents are picked by name. Assigning an agent adds it to the chain's fleet,
 * and the agent may start right away, so the dialog says so.
 */
export const TaskEditModal: React.FC<TaskEditModalProps> = ({
  task,
  field,
  onClose,
  onSave,
  tasks = [],
  agents = [],
  roles,
  names = EMPTY_TASK_NAMES,
}) => {
  const currentAssignee = String(task.brief?.assignee || '');
  const currentRoles: string[] = Array.isArray(task.brief?.review_roles) ? (task.brief.review_roles as unknown[]).map(String) : [];
  const currentDeps: string[] = task.depends_on || [];
  const currentNamed: string[] = task.brief?.reviewers || [];

  const [assignee, setAssignee] = useState(currentAssignee);
  const [roleDraft, setRoleDraft] = useState<string[]>(currentRoles);
  const [named, setNamed] = useState<string[]>(currentNamed);
  const [userApproval, setUserApproval] = useState(Boolean(task.requires_user_approval));
  const [deps, setDeps] = useState<string[]>(currentDeps);
  const [title, setTitle] = useState(String(task.title || ''));
  const [description, setDescription] = useState(String(task.description || ''));
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  // Reset the draft whenever the dialog opens for a field.
  useEffect(() => {
    setAssignee(currentAssignee);
    setRoleDraft(currentRoles);
    setNamed(currentNamed);
    setUserApproval(Boolean(task.requires_user_approval));
    setDeps(currentDeps);
    setTitle(String(task.title || ''));
    setDescription(String(task.description || ''));
    setError('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [field, task.task_id]);

  // Chain review roles (optional layer) with their holders.
  const roleList = useMemo(() => {
    const byName = new Map((roles || []).map((r) => [r.name, r]));
    for (const r of currentRoles) if (!byName.has(r)) byName.set(r, { name: r, description: '', holders: [] });
    return Array.from(byName.values());
  }, [roles, currentRoles]);

  // Reviewers already named but not in the agent list stay pickable (and removable).
  const reviewerChoices = useMemo(() => {
    const list = [...agents];
    for (const id of currentNamed) if (!list.some((a) => a.agentId === id)) list.push({ agentId: id, name: names.agent(id) });
    return list;
  }, [agents, currentNamed, names]);

  const agentOptions = [
    { value: '', text: 'Any worker in the fleet' },
    ...agents.map((a) => ({ value: a.agentId, text: a.name || names.agent(a.agentId) })),
  ];
  const depCandidates = tasks.filter((t) => t.task_id !== task.task_id);

  const save = async () => {
    if (!field) return;
    let change: TaskEditChange;
    if (field === 'assignee') change = { field, assignee };
    else if (field === 'reviewers') change = { field, reviewers: named, reviewRoles: roleDraft, requiresUserApproval: userApproval };
    else if (field === 'deps') change = { field, dependsOn: deps };
    else {
      if (!title.trim()) { setError('Give the ticket a title.'); return; }
      change = { field, title: title.trim(), description: description.trim() };
    }
    setError('');
    setSaving(true);
    try {
      const failure = await onSave(change);
      if (failure) setError(failure);
      else onClose();
    } finally {
      setSaving(false);
    }
  };

  const toggle = (list: string[], value: string, on: boolean) => (on ? [...list, value] : list.filter((v) => v !== value));

  return (
    <Modal open={Boolean(field)} onOpenChange={(open) => !open && onClose()} title={field ? TITLES[field] : ''} size="sm" data-debug-id="task-edit-modal">
      <ModalBody className="space-y-3 text-body-sm">
        {field !== 'details' && (
          <Text as="p" role="caption" tone="muted">
            {task.title}
          </Text>
        )}

        {field === 'details' && (
          <>
            <label className="flex flex-col gap-1">
              <span className="text-label text-muted">Title</span>
              <Input value={title} onChange={setTitle} width="full" aria-label="Ticket title" data-debug-id="task-edit-title" />
            </label>
            <label className="flex flex-col gap-1">
              <span className="text-label text-muted">Description</span>
              <Textarea value={description} onChange={setDescription} rows={4} width="full" aria-label="Ticket description" data-debug-id="task-edit-description" />
            </label>
          </>
        )}

        {field === 'assignee' && (
          <>
            <Select value={assignee} onChange={setAssignee} options={agentOptions} width="full" aria-label="Assignee" />
            <Text as="p" role="caption" tone="warning">
              Assigning an agent adds it to this chain's fleet. If the ticket is ready, the agent may start right away.
            </Text>
          </>
        )}

        {field === 'reviewers' && (
          <>
            <div className="space-y-1.5">
              <Text as="p" role="caption" tone="muted">
                Reviewers of this ticket (each must approve):
              </Text>
              {reviewerChoices.length === 0 && <Text as="p" role="caption" tone="faint">No agents to choose from.</Text>}
              <div className="max-h-48 space-y-1 overflow-y-auto">
                {reviewerChoices.map((a) => {
                  const isAssignee = a.agentId === currentAssignee;
                  return (
                    <Checkbox
                      key={a.agentId}
                      checked={named.includes(a.agentId)}
                      disabled={isAssignee}
                      onChange={(on) => setNamed((n) => toggle(n, a.agentId, on))}
                      data-debug-id={`task-edit-reviewer-${a.agentId}`}
                      label={
                        <span>
                          {a.name || names.agent(a.agentId)}
                          {isAssignee && <span className="text-faint"> (assignee, can't review its own work)</span>}
                        </span>
                      }
                    />
                  );
                })}
              </div>
            </div>
            <Checkbox checked={userApproval} onChange={setUserApproval} data-debug-id="task-edit-user-approval" label="I approve it too (final review is mine)" />
            {roles && (
              <details className="space-y-1.5">
                <summary className="cursor-pointer text-muted hover:text-primary">
                  Review roles (optional){roleDraft.length ? `: ${roleDraft.join(', ')}` : ''}
                </summary>
                <Text as="p" role="caption" tone="muted">
                  A role asks every agent holding it to review. Useful for templates and coordinators. Manage roles from the
                  chain's Review roles.
                </Text>
                {roleList.map((role) => (
                  <Checkbox
                    key={role.name}
                    checked={roleDraft.includes(role.name)}
                    onChange={(on) => setRoleDraft((r) => toggle(r, role.name, on))}
                    label={
                      <span>
                        {role.name}{' '}
                        <span className={role.holders.length ? 'text-muted' : 'text-warning'}>
                          ({role.holders.length ? role.holders.map(names.agent).join(', ') : 'nobody holds it'})
                        </span>
                        {role.description && <span className="block text-faint">{role.description}</span>}
                      </span>
                    }
                  />
                ))}
              </details>
            )}
          </>
        )}

        {field === 'deps' &&
          (depCandidates.length === 0 ? (
            <Text as="p" role="caption" tone="faint">
              There are no other tickets in this chain.
            </Text>
          ) : (
            <div className="max-h-64 space-y-1 overflow-y-auto">
              {depCandidates.map((t) => {
                const state = normalizeTaskState(t.state);
                return (
                  <div key={t.task_id} className="flex min-w-0 items-center justify-between gap-2">
                    <Checkbox
                      checked={deps.includes(t.task_id)}
                      onChange={(on) => setDeps((d) => toggle(d, t.task_id, on))}
                      data-debug-id={`task-edit-dep-${t.task_id}`}
                      label={<span className="truncate">{t.title}</span>}
                    />
                    <StatusPill tone={TASK_STATE_TONE[state]}>{TASK_STATE_LABELS[state]}</StatusPill>
                  </div>
                );
              })}
            </div>
          ))}

        {error && (
          <Text as="p" role="caption" tone="danger" className="whitespace-pre-line break-words" data-debug-id="task-edit-error">
            {error}
          </Text>
        )}
      </ModalBody>
      <ModalFooter>
        {field === 'assignee' && assignee !== currentAssignee && assignee && <Badge tone="warning">May start now</Badge>}
        <Button size="sm" variant="ghost" onClick={onClose} data-debug-id="task-edit-cancel">
          Cancel
        </Button>
        <Button size="sm" variant="primary" data-debug-id="task-edit-save" loading={saving} onClick={() => void save()}>
          Save
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default TaskEditModal;
