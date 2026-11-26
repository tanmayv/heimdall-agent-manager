import React, { useMemo, useState } from 'react';
import { Button, Checkbox, FormField, Input, Modal, ModalBody, ModalFooter, Select, StatusPill, Textarea } from '@ui';
import { TASK_STATE_LABELS, TASK_STATE_TONE, normalizeTaskState } from './taskV2Types';
import { useCreateTaskMutation } from '../../api/endpoints/tasks';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { taskBridgeOptions } from '../../utils/taskBridgePin';
import { formatFleetRoleName } from './fleetNames';
import { useAuthUser } from '../auth/AuthUserContext';
import { BRIEF_ACCEPTANCE_ITEM_MAX, BRIEF_ACCEPTANCE_MAX, BRIEF_GOAL_MAX, buildTaskBrief } from '../../utils/taskBrief';
import { ReviewerPicker } from './ReviewerPicker';

export interface CreateTaskModalProps {
  chainId: string;
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
  existingTasks?: any[];
}

export const CreateTaskModal: React.FC<CreateTaskModalProps> = ({
  chainId,
  isOpen,
  onClose,
  onSuccess,
  existingTasks = [],
}) => {
  const [createTask, { isLoading: isCreating }] = useCreateTaskMutation();
  const authUser = useAuthUser();
  const username = String(authUser?.user_id || '').trim();
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const agentIdentities = agentIdentitiesQuery.data?.agents || [];
  // REQ-TB-5: the owner's bridges for the optional per-task bridge pin. Skipped
  // while the modal is closed.
  const bridgesQuery = useListBridgesQuery(undefined, { skip: !isOpen });
  const bridgeOptions = useMemo(
    () => taskBridgeOptions(bridgesQuery.data?.bridges || []),
    [bridgesQuery.data],
  );

  const [title, setTitle] = useState('');
  const [desc, setDesc] = useState('');
  // Tickets (M2): the brief. Validated client-side with the hub's publish
  // rules (utils/taskBrief) so a human-created task is publishable as-is.
  const [goal, setGoal] = useState('');
  const [acceptanceText, setAcceptanceText] = useState('');
  // REQ-TB-5: '' = Inherit (coordinator bridge) — the default create pins nothing.
  const [bridgeId, setBridgeId] = useState('');
  // REQ-SCHED-3: every task names its assignee agent. REQ-AUTO-4: no literal
  // placeholder default — the user picks a real durable identity.
  const [assigneeAgentId, setAssigneeAgentIdRaw] = useState('');
  // REQ-SCHED-4: reviewer agents, plus the user through requires_user_approval.
  const [reviewerAgentIds, setReviewerAgentIds] = useState<string[]>([]);
  const [requiresUserApproval, setRequiresUserApproval] = useState(false);
  // The assignee cannot review its own work (reviewer_is_assignee).
  const setAssigneeAgentId = (id: string) => {
    setAssigneeAgentIdRaw(id);
    setReviewerAgentIds((prev) => prev.filter((r) => r !== id));
  };

  const [dependsOnIds, setDependsOnIds] = useState<string[]>([]);
  const [errorMsg, setErrorMsg] = useState('');

  const agentName = (id: string) => {
    const found = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === id);
    return String(found?.name || found?.display_name || formatFleetRoleName(id, agentIdentities));
  };
  // Active agent identities with clean display names (no raw IDs). The empty
  // placeholder is always first so no actor is ever pre-selected.
  const agentOptions = useMemo(() => {
    return [
      { value: '', label: 'Select an agent…', disabled: true },
      ...agentIdentities
        .filter((a: any) => String(a.state || 'active').toLowerCase() === 'active')
        .map((a: any) => {
          const id = String(a.agent_id || a.agentId || a.id || '');
          return { value: id, label: a.name || a.display_name || formatFleetRoleName(id, agentIdentities) };
        }),
    ];
  }, [agentIdentities]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMsg('');
    const trimmedTitle = title.trim();
    if (!trimmedTitle) {
      setErrorMsg('Please enter a ticket title.');
      return;
    }

    if (!assigneeAgentId) {
      setErrorMsg('Choose the agent that works on this ticket.');
      return;
    }

    const briefBuild = buildTaskBrief({ goal, acceptanceText, assignee: assigneeAgentId });
    // Allow draft creation when brief fields are still being sketched; reject only
    // when provided values exceed hub caps.
    const hardBriefError = briefBuild.errors.find((msg) => msg.includes('exceeds') || msg.includes('at most'));
    if (hardBriefError) {
      setErrorMsg(hardBriefError);
      return;
    }

    try {
      const payload: any = {
        chainId,
        title: trimmedTitle,
        description: desc.trim(),
        // '' is dropped by the createTask serialization (absent = inherit).
        bridgeId,
        requiresUserApproval,
        brief: briefBuild.brief,
        assigneeRef: { type: 'agent_id', agent_id: assigneeAgentId },
      };
      if (reviewerAgentIds.length > 0) {
        payload.reviewerRefs = reviewerAgentIds.map((agent_id) => ({ type: 'agent_id', agent_id }));
      }
      if (dependsOnIds.length > 0) {
        payload.dependsOn = dependsOnIds;
      }

      await createTask(payload).unwrap();
      // Reset form
      setTitle('');
      setDesc('');
      setGoal('');
      setAcceptanceText('');
      setAssigneeAgentIdRaw('');
      setBridgeId('');
      setReviewerAgentIds([]);
      setRequiresUserApproval(false);
      setDependsOnIds([]);
      onSuccess?.();
      onClose();
    } catch (err: any) {
      setErrorMsg(String(err?.data?.error?.message || err?.message || 'Failed to create ticket'));
    }
  };

  // Typed work is never thrown away silently: Esc, the backdrop and the close
  // button all ask first when the form has content (audit finding).
  const dirty = Boolean(title.trim() || desc.trim() || goal.trim() || acceptanceText.trim() || assigneeAgentId || reviewerAgentIds.length || requiresUserApproval);
  const requestClose = (next: boolean) => {
    if (next) return;
    if (dirty && !window.confirm('Discard this new ticket?')) return;
    onClose();
  };

  return (
    <Modal open={isOpen} onOpenChange={requestClose} title="New ticket" size="lg" data-debug-id="create-task-modal">
      <ModalBody>
        <p className="mb-4 text-caption text-muted">A goal, acceptance criteria and an assignee make it publishable as-is.</p>
        <form id="create-task-form" onSubmit={handleSubmit} className="space-y-4 text-xs">
          {/* Title */}
          <FormField label="Title" required>
            <Input
              data-debug-id="create-task-title-input"
              value={title}
              onChange={setTitle}
              placeholder="e.g. Implement user authentication endpoint"
              width="full"
              autoFocus
            />
          </FormField>

          {/* Description */}
          <FormField label="Description (optional)">
            <Textarea
              data-debug-id="create-task-description-input"
              value={desc}
              onChange={setDesc}
              rows={3}
              placeholder="Context for the agent: requirements, files, constraints"
              width="full"
            />
          </FormField>

          {/* Ticket brief — what the hub validates at publish. */}
          <div data-debug-id="create-task-brief" className="space-y-2.5 border-t border-subtle pt-3">
            <div>
              <label className="block font-semibold text-primary">Brief</label>
              <p className="text-[11px] text-muted mt-0.5">
                Required to publish: a goal and at least one acceptance criterion.
              </p>
            </div>

            <FormField label="Goal" required hint={`${goal.trim().length} of ${BRIEF_GOAL_MAX} characters`}>
              <Textarea
                data-debug-id="create-task-goal-input"
                value={goal}
                onChange={setGoal}
                rows={3}
                maxLength={BRIEF_GOAL_MAX}
                placeholder="What outcome should the agent deliver?"
                width="full"
              />
            </FormField>

            <FormField
              label="Acceptance criteria"
              required
              hint={`One per line, 1 to ${BRIEF_ACCEPTANCE_MAX} items, up to ${BRIEF_ACCEPTANCE_ITEM_MAX} characters each`}
            >
              <Textarea
                data-debug-id="create-task-acceptance-input"
                value={acceptanceText}
                onChange={setAcceptanceText}
                rows={3}
                placeholder={'Endpoint returns 201 on success\nUnit tests cover the error path'}
                width="full"
              />
            </FormField>

          </div>

          {/* Bridge (REQ-TB-5) */}
          <div>
            <label className="block font-semibold text-primary mb-1">Bridge</label>
            <Select
              data-debug-id="create-task-bridge-select"
              width="full"
              value={bridgeId}
              onChange={setBridgeId}
              options={bridgeOptions}
            />
            <p className="text-[11px] text-muted mt-1">
              Pin this ticket to a specific bridge, or leave it on the coordinator&apos;s bridge.
            </p>
          </div>

          {/* Assignee (REQ-SCHED-3): required, an agent. */}
          <div className="space-y-2.5 border-t border-subtle pt-3">
            <FormField label="Assignee" required hint="The agent that works on this ticket. It is added to the chain staffing if needed.">
              <Select
                data-debug-id="create-task-assignee-agentid-select"
                width="full"
                value={assigneeAgentId}
                onChange={setAssigneeAgentId}
                options={agentOptions}
              />
            </FormField>
          </div>

          {/* Reviewers (REQ-SCHED-4): agents and/or the user; each must approve. */}
          <div className="space-y-2.5 border-t border-subtle pt-3">
            <label className="font-semibold text-primary">
              Reviewers ({reviewerAgentIds.length + (requiresUserApproval ? 1 : 0)})
            </label>
            <ReviewerPicker
              agents={agentIdentities}
              assignee={assigneeAgentId}
              reviewers={reviewerAgentIds}
              onReviewersChange={setReviewerAgentIds}
              userApproval={requiresUserApproval}
              onUserApprovalChange={setRequiresUserApproval}
              userLabel={username ? `you, @${username}` : ''}
              agentName={agentName}
              debugPrefix="create-task"
            />
            {reviewerAgentIds.length === 0 && !requiresUserApproval ? (
              <p className="text-[11px] text-muted">Without reviewers the ticket is done as soon as it is submitted.</p>
            ) : null}
          </div>

          {/* Depends On Section */}
          {existingTasks.length > 0 && (
            <div className="space-y-2 border-t border-subtle pt-3">
              <label className="block font-semibold text-primary">
                Waits for {dependsOnIds.length > 0 && `(${dependsOnIds.length})`}
              </label>
              <div className="max-h-36 overflow-y-auto space-y-1 rounded border border-subtle bg-surface p-2">
                {existingTasks.map((t) => {
                  const tid = String(t.taskId || t.id);
                  const isSelected = dependsOnIds.includes(tid);
                  return (
                    <label
                      key={tid}
                      data-debug-id={`create-task-depends-on-${tid}`}
                      className={`flex items-center gap-2 rounded px-2 py-1 cursor-pointer text-xs transition-colors ${
                        isSelected ? 'bg-accent/15 border border-accent/30 text-primary' : 'hover:bg-neutral-soft text-muted'
                      }`}
                    >
                      <Checkbox
                        checked={isSelected}
                        onChange={(checked) => {
                          if (checked) {
                            setDependsOnIds((prev) => [...prev, tid]);
                          } else {
                            setDependsOnIds((prev) => prev.filter((id) => id !== tid));
                          }
                        }}
                      />
                      <span className="truncate flex-1 font-medium">{t.title}</span>
                      <StatusPill tone={TASK_STATE_TONE[normalizeTaskState(t.state || t.status)]}>
                        {TASK_STATE_LABELS[normalizeTaskState(t.state || t.status)]}
                      </StatusPill>
                    </label>
                  );
                })}
              </div>
            </div>
          )}

          {errorMsg && (
            <div data-debug-id="create-task-error" className="text-caption text-danger">
              {errorMsg}
            </div>
          )}

        </form>
      </ModalBody>
      <ModalFooter>
        <Button type="button" size="sm" variant="ghost" onClick={() => requestClose(false)}>
          Cancel
        </Button>
        <Button
          type="submit"
          form="create-task-form"
          size="sm"
          variant="primary"
          data-debug-id="create-task-submit-btn"
          disabled={isCreating || !username}
          loading={isCreating}
        >
          Create ticket
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default CreateTaskModal;
