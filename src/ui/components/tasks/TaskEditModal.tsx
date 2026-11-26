import React, { useEffect, useState } from 'react';
import { Badge, Button, Checkbox, Modal, ModalBody, ModalFooter, Select, StatusPill, Text, Textarea } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useUpdateTaskDetailMutation } from '../../api/endpoints/tasks';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { TASK_STATE_LABELS, TASK_STATE_TONE, briefReviewerAgents, normalizeTaskState, taskNeedsUserApproval } from './taskV2Types';
import { ReviewerPicker } from './ReviewerPicker';
import { actionErrorMessage } from './useTaskActions';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';

export type TaskEditField = 'assignee' | 'reviewers' | 'deps' | 'requirements';

export interface TaskEditModalProps {
  chainId: string;
  task: TaskWire;
  field: TaskEditField | null;
  onClose: () => void;
  /** All tasks of the chain, for the dependency picker. */
  tasks?: TaskWire[];
  chainFleets?: any[];
  names?: TaskNames;
}

const TITLES: Record<TaskEditField, string> = {
  requirements: 'Change requirements',
  assignee: 'Who works on it',
  reviewers: 'Who must approve it',
  deps: 'What it waits for',
};

/**
 * Change a task's assignee, required reviews or dependencies (plan REQ-UI-11).
 * Agents are picked by name. Every task has an assignee (REQ-SCHED-3); its
 * reviewers are agents and optionally the user (REQ-SCHED-4). Assigning an
 * agent adds it to the chain's fleet, and the hub may start it right away, so
 * the dialog says so.
 */
export const TaskEditModal: React.FC<TaskEditModalProps> = ({
  chainId,
  task,
  field,
  onClose,
  tasks = [],
  chainFleets = [],
  names = EMPTY_TASK_NAMES,
}) => {
  const [updateTask, updateState] = useUpdateTaskDetailMutation();
  // Mounted once per TaskCard while closed: only an open assignee/reviewer picker needs
  // the identity catalogue.
  const { data: identitiesData } = useListAgentIdentitiesQuery(undefined, { skip: field !== 'assignee' && field !== 'reviewers' });
  const agents: any[] = identitiesData?.agents || [];

  const currentAssignee = String(task.brief?.assignee || '');
  const currentDeps: string[] = task.depends_on || [];

  const [assignee, setAssignee] = useState(currentAssignee);
  const currentNamed: string[] = briefReviewerAgents(task);
  const [named, setNamed] = useState<string[]>(currentNamed);
  const [userApproval, setUserApproval] = useState(taskNeedsUserApproval(task));
  const [deps, setDeps] = useState<string[]>(currentDeps);
  const [error, setError] = useState('');
  const [goal, setGoal] = useState('');
  const [acceptance, setAcceptance] = useState('');
  const [reason, setReason] = useState('');
  const [requirementRevision, setRequirementRevision] = useState(0);
  const [original, setOriginal] = useState({ goal: '', acceptance: '' });

  // Reset the draft whenever the dialog opens for a field.
  useEffect(() => {
    setAssignee(currentAssignee);
    setNamed(currentNamed);
    setUserApproval(taskNeedsUserApproval(task));
    setDeps(currentDeps);
    setError('');
    const goal = String(task.brief?.goal || '');
    const acceptance = (task.brief?.acceptance || []).join('\n');
    setGoal(goal); setAcceptance(acceptance); setOriginal({ goal, acceptance });
    setReason(''); setRequirementRevision(task.requirements?.revision || 0);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [field, task.task_id]);

  const agentName = (id: string) => {
    const found = agents.find((a) => String(a.agent_id || a.agentId) === id);
    return String(found?.name || found?.display_name || names.agent(id));
  };
  // Assignee is required (REQ-SCHED-3): no "any worker" choice. A listed
  // reviewer cannot become the assignee (reviewer_is_assignee).
  const agentOptions = [
    { value: '', text: 'Choose an agent…', disabled: true },
    ...agents
      .filter((a) => String(a.state || 'active').toLowerCase() === 'active' || String(a.agent_id || a.agentId) === currentAssignee)
      .map((a) => {
        const id = String(a.agent_id || a.agentId);
        const reviewer = currentNamed.includes(id);
        return { value: id, text: `${agentName(id)}${reviewer ? ' (reviewer of this ticket)' : ''}`, disabled: reviewer };
      }),
  ];
  const depCandidates = tasks.filter((t) => t.task_id !== task.task_id);

  const save = async () => {
    if (!field) return;
    setError('');
    const args: any = { chainId, taskId: task.task_id };
    if (field === 'assignee') {
      if (!assignee) { setError('Choose the agent that works on this ticket.'); return; }
      args.assigneeRef = { type: 'agent_id', agent_id: assignee };
    }
    if (field === 'reviewers') {
      // Replaces the task's reviewer agents (an empty list clears them); the
      // user is listed through requires_user_approval.
      args.reviewerRefs = named.map((agent_id) => ({ type: 'agent_id', agent_id }));
      args.requiresUserApproval = userApproval;
    }
    if (field === 'deps') args.dependsOn = deps;
    if (field === 'requirements') {
      const items = acceptance.split('\n').map(item => item.trim()).filter(Boolean);
      if (!goal.trim() || !items.length || !reason.trim()) { setError('Provide a goal, acceptance criteria and a reason for the change.'); return; }
      if (new TextEncoder().encode(goal).length > 2000 || items.length > 20 || items.some(item => new TextEncoder().encode(item).length > 200)) { setError('Use a goal up to 2,000 bytes and up to 20 acceptance criteria of 200 bytes each.'); return; }
      if (goal === original.goal && acceptance === original.acceptance) { setError('Change the goal or acceptance criteria first.'); return; }
      args.brief = { ...(goal !== original.goal ? { goal } : {}), ...(acceptance !== original.acceptance ? { acceptance: items } : {}) };
      args.expectedRequirementsRevision = requirementRevision;
      args.requirementsReason = reason.trim();
    }
    try {
      await updateTask(args).unwrap();
      onClose();
    } catch (err) {
      setError(actionErrorMessage(err));
    }
  };

  const toggle = (list: string[], value: string, on: boolean) => (on ? [...list, value] : list.filter((v) => v !== value));
  const assigneeMissing = field === 'assignee' && !assignee;

  return (
    <Modal open={Boolean(field)} onOpenChange={(open) => !open && onClose()} title={field ? TITLES[field] : ''} size="sm">
      <ModalBody className="space-y-3 text-xs">
        <Text as="p" role="caption" tone="muted">
          {task.title}
        </Text>

        {field === 'assignee' && (
          <>
            <Select value={assignee} onChange={setAssignee} options={agentOptions} width="full" aria-label="Assignee" />
            <Text as="p" role="caption" tone="warning">
              Assigning an agent adds it to this chain's fleet. If the ticket is ready, the agent may start right away.
            </Text>
          </>
        )}
        {field === 'requirements' && (
          <div className="space-y-3" data-debug-id="task-requirements-editor">
            <Text as="p" role="caption" tone="muted">Working agents will be notified. A change during review requires rework and fresh approvals.</Text>
            <label className="block">Goal<Textarea aria-label="Task goal" data-debug-id="task-requirements-goal" value={goal} onChange={setGoal} rows={3} width="full" /></label>
            <label className="block">Acceptance criteria, one per line<Textarea aria-label="Acceptance criteria" data-debug-id="task-requirements-acceptance" value={acceptance} onChange={setAcceptance} rows={5} width="full" /></label>
            <label className="block">Reason for the change<Textarea aria-label="Reason for the change" data-debug-id="task-requirements-reason" value={reason} onChange={setReason} rows={2} width="full" /></label>
            {requirementRevision === 0 && <Text tone="warning">Reload the task before editing its requirements.</Text>}
            {(goal.startsWith('vault:v2:') || acceptance.includes('vault:v2:')) && <Text tone="warning">Unlock the vault to edit these requirements.</Text>}
          </div>
        )}

        {field === 'reviewers' && (
          <ReviewerPicker
            agents={agents}
            assignee={currentAssignee}
            reviewers={named}
            onReviewersChange={setNamed}
            userApproval={userApproval}
            onUserApprovalChange={setUserApproval}
            userLabel="you approve it too"
            agentName={agentName}
            debugPrefix="task-edit"
          />
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
                      label={<span className="truncate">{t.title}</span>}
                    />
                    <StatusPill tone={TASK_STATE_TONE[state]}>{TASK_STATE_LABELS[state]}</StatusPill>
                  </div>
                );
              })}
            </div>
          ))}

        {error && (
          <Text as="p" role="caption" tone="danger" className="whitespace-pre-line break-words">
            {error}
          </Text>
        )}
      </ModalBody>
      <ModalFooter>
        {field === 'assignee' && assignee !== currentAssignee && assignee && <Badge tone="warning">May start now</Badge>}
        <Button size="sm" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button size="sm" variant="primary" data-debug-id="task-requirements-save" disabled={assigneeMissing || (field === 'requirements' && (!requirementRevision || goal.startsWith('vault:v2:') || acceptance.includes('vault:v2:')))} loading={updateState.isLoading} onClick={save}>
          Save
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default TaskEditModal;
