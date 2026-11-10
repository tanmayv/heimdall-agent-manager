// origin/main's New ticket modal behind a props seam: the data source supplies
// the agent choices and the create action (for a Bridge-owned chain, owner
// commands: task.create, requirements.edit, work.dependency.add), so the modal
// calls no Hub task endpoint. Owner tickets have no review roles (reviewers are
// agent ids plus your approval), no per-ticket bridge pin and no assignee; those
// fields of origin/main are left out.

import React, { useMemo, useState } from 'react';
import { Button, Checkbox, FormField, Icon, IconButton, Input, Modal, ModalBody, ModalFooter, Select, StatusPill, Textarea } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { TASK_STATE_LABELS, TASK_STATE_TONE, normalizeTaskState } from './taskV2Types';
import type { CreateTaskInput } from './ownerChainAdapter';

export type { CreateTaskInput } from './ownerChainAdapter';

/** The brief limits of origin/main's utils/taskBrief (the hub's publish rules). */
export const BRIEF_GOAL_MAX = 2000;
export const BRIEF_ACCEPTANCE_MAX = 20;
export const BRIEF_ACCEPTANCE_ITEM_MAX = 200;

export interface CreateTaskModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
  existingTasks?: Pick<TaskWire, 'task_id' | 'title' | 'state'>[];
  /** Agent choices for reviewers (agent id -> name). */
  agentOptions: { value: string; label: string }[];
  /** Creates the ticket; resolves to an error message, or '' on success. */
  create: (input: CreateTaskInput) => Promise<string>;
}

/** The modal's own validation of what it collected; '' when it can be created. */
export function createTaskInputError(input: CreateTaskInput): string {
  if (!input.title.trim()) return 'Please enter a ticket title.';
  if (input.goal.trim().length > BRIEF_GOAL_MAX) return `The goal exceeds ${BRIEF_GOAL_MAX} characters.`;
  const acceptance = input.acceptance.filter((a) => a.trim());
  if (acceptance.length > BRIEF_ACCEPTANCE_MAX) return `Acceptance criteria are limited to at most ${BRIEF_ACCEPTANCE_MAX} items.`;
  if (acceptance.some((a) => a.trim().length > BRIEF_ACCEPTANCE_ITEM_MAX)) return `An acceptance criterion exceeds ${BRIEF_ACCEPTANCE_ITEM_MAX} characters.`;
  return '';
}

export const CreateTaskModal: React.FC<CreateTaskModalProps> = ({
  isOpen,
  onClose,
  onSuccess,
  existingTasks = [],
  agentOptions,
  create,
}) => {
  const [isCreating, setIsCreating] = useState(false);
  const [title, setTitle] = useState('');
  const [desc, setDesc] = useState('');
  const [goal, setGoal] = useState('');
  const [acceptanceText, setAcceptanceText] = useState('');
  const [reviewers, setReviewers] = useState<string[]>([]);
  const [reviewerAgentId, setReviewerAgentId] = useState('');
  const [requiresUserApproval, setRequiresUserApproval] = useState(false);
  const [dependsOnIds, setDependsOnIds] = useState<string[]>([]);
  const [errorMsg, setErrorMsg] = useState('');

  const options = useMemo(() => [{ value: '', label: 'Select agent…' }, ...agentOptions], [agentOptions]);
  const agentLabel = (id: string) => agentOptions.find((o) => o.value === id)?.label || id;

  const handleAddReviewer = () => {
    if (!reviewerAgentId || reviewers.includes(reviewerAgentId)) return;
    setReviewers((prev) => [...prev, reviewerAgentId]);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMsg('');
    const input: CreateTaskInput = {
      title, description: desc, goal, acceptance: acceptanceText.split(/\r?\n/), reviewers, requiresUserApproval, dependsOn: dependsOnIds,
    };
    const invalid = createTaskInputError(input);
    if (invalid) { setErrorMsg(invalid); return; }
    setIsCreating(true);
    try {
      const failed = await create(input);
      if (failed) { setErrorMsg(failed); return; }
      setTitle(''); setDesc(''); setGoal(''); setAcceptanceText('');
      setReviewers([]); setReviewerAgentId(''); setRequiresUserApproval(false); setDependsOnIds([]);
      onSuccess?.();
      onClose();
    } finally {
      setIsCreating(false);
    }
  };

  // Typed work is never thrown away silently: Esc, the backdrop and the close
  // button all ask first when the form has content.
  const dirty = Boolean(title.trim() || desc.trim() || goal.trim() || acceptanceText.trim());
  const requestClose = (next: boolean) => {
    if (next) return;
    if (dirty && !window.confirm('Discard this new ticket?')) return;
    onClose();
  };

  return (
    <Modal open={isOpen} onOpenChange={requestClose} title="New ticket" size="lg" data-debug-id="create-task-modal">
      <ModalBody>
        <p className="mb-4 text-caption text-muted">A goal and acceptance criteria tell the worker when it is done.</p>
        <form id="create-task-form" onSubmit={handleSubmit} className="space-y-4 text-xs">
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

          <div data-debug-id="create-task-brief" className="space-y-2.5 border-t border-subtle pt-3">
            <div>
              <label className="block font-semibold text-primary">Brief</label>
              <p className="mt-0.5 text-caption text-muted">Saved as the ticket's requirements.</p>
            </div>

            <FormField label="Goal" hint={`${goal.trim().length} of ${BRIEF_GOAL_MAX} characters`}>
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
              hint={`One per line, up to ${BRIEF_ACCEPTANCE_MAX} items of ${BRIEF_ACCEPTANCE_ITEM_MAX} characters each`}
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

          <div className="space-y-2.5 border-t border-subtle pt-3">
            <label className="font-semibold text-primary">Reviewers ({reviewers.length})</label>

            <Checkbox
              data-debug-id="create-task-require-user-approval-checkbox"
              checked={requiresUserApproval}
              onChange={setRequiresUserApproval}
              label="Needs your approval before it is done"
            />

            {reviewers.length > 0 && (
              <div className="flex flex-wrap gap-1.5 rounded-[var(--radius-md)] border border-subtle bg-surface p-2">
                {reviewers.map((id, idx) => (
                  <span
                    key={id}
                    data-debug-id={`create-task-reviewer-chip-${idx}`}
                    className="inline-flex items-center gap-1.5 rounded-pill border border-subtle bg-surface-raised px-2.5 py-0.5 text-xs text-primary"
                  >
                    <Icon name="check" size={14} className="text-muted" />
                    <span>{agentLabel(id)}</span>
                    <IconButton
                      icon="close"
                      label="Remove reviewer"
                      variant="ghost"
                      size="sm"
                      onClick={() => setReviewers((prev) => prev.filter((r) => r !== id))}
                    />
                  </span>
                ))}
              </div>
            )}

            <div className="flex items-center gap-2">
              <Select
                data-debug-id="create-task-reviewer-agentid-select"
                aria-label="Reviewer agent"
                width="full"
                value={reviewerAgentId}
                onChange={setReviewerAgentId}
                options={options}
              />
              <Button
                type="button"
                size="sm"
                variant="secondary"
                data-debug-id="create-task-add-reviewer-btn"
                onClick={handleAddReviewer}
                className="shrink-0"
              >
                Add reviewer
              </Button>
            </div>
          </div>

          {existingTasks.length > 0 && (
            <div className="space-y-2 border-t border-subtle pt-3">
              <label className="block font-semibold text-primary">
                Waits for {dependsOnIds.length > 0 && `(${dependsOnIds.length})`}
              </label>
              <div className="max-h-36 space-y-1 overflow-y-auto rounded-[var(--radius-md)] border border-subtle bg-surface p-2">
                {existingTasks.map((t) => {
                  const tid = t.task_id;
                  const isSelected = dependsOnIds.includes(tid);
                  const state = normalizeTaskState(t.state);
                  return (
                    <label
                      key={tid}
                      data-debug-id={`create-task-depends-on-${tid}`}
                      className={`flex cursor-pointer items-center gap-2 rounded-[var(--radius-sm)] px-2 py-1 text-xs transition-colors ${
                        isSelected ? 'bg-neutral-soft text-primary' : 'text-muted hover:bg-neutral-soft'
                      }`}
                    >
                      <Checkbox
                        checked={isSelected}
                        onChange={(checked) => setDependsOnIds((prev) => (checked ? [...prev, tid] : prev.filter((id) => id !== tid)))}
                      />
                      <span className="flex-1 truncate font-medium">{t.title || tid}</span>
                      <StatusPill tone={TASK_STATE_TONE[state]}>{TASK_STATE_LABELS[state]}</StatusPill>
                    </label>
                  );
                })}
              </div>
            </div>
          )}

          {errorMsg && (
            <div data-debug-id="create-task-error" role="alert" className="text-caption text-danger">
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
          disabled={isCreating}
          loading={isCreating}
        >
          Create ticket
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default CreateTaskModal;
