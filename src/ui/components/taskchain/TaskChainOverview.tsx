// origin/main's chain board (TaskChainOverview) behind a props seam. On
// origin/main it read the chain with Hub hooks (useChainTickets, workflow runs,
// publish, fleet and review-role mutations); here the data source passes the
// tickets, names, card actions and the fleet table, and supplies the create
// action, so the board calls no Hub task/chain/workflow endpoint. For a
// Bridge-owned chain OwnerChainView is that source (ownerTaskAdapter +
// ownerChainAdapter).
//
// Left out (no owner-local equivalent): workflow runs (WorkflowPipelineView),
// chain publish (owner chains are published when created), review roles
// (ReviewRolesModal; reviewers are agent ids plus your approval), the Hub fleet
// drawer (FleetManagementDrawer; the owner fleet table edits rows in place),
// the Solo badge and the Hub ticket editors (RequirementsEditorModal /
// TaskEditModal; a card's Edit opens the ticket with its editor).
//
// TODO(TicketView): origin/main opened the ticket in place here (TicketView)
// when the host has no aux pane. Until the owner TicketView lands the host
// renders the ticket itself and onOpenTicket is always required.

import React, { useState } from 'react';
import { Alert, Badge, IconButton, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { TicketBoard } from '../tasks/TicketBoard';
import type { BoardTicketActions, TaskEditField, TicketOpenFocus } from '../tasks/BoardTicketCard';
import { replacementLinks, ticketTabTitle, keyFor } from '../tasks/ticketModel';
import { EMPTY_TASK_NAMES, type TaskNames } from '../tasks/taskNames';
import { CreateTaskModal, type CreateTaskInput } from '../tasks/CreateTaskModal';
import { TaskBoardSkeleton } from '../tasks/TaskBoardSkeleton';

/** Creating a ticket from the board: the agent choices and the create action. */
export interface TaskChainCreateActions {
  agentOptions: { value: string; label: string }[];
  /** Resolves to an error message, or '' once the ticket exists. */
  create: (input: CreateTaskInput) => Promise<string>;
  /** Run-Bridge choices for a new ticket; the first ('') is the default. */
  bridgeOptions?: { value: string; text: string }[];
}

export interface TaskChainOverviewProps {
  chainId: string;
  /** The chain title (title bar). */
  title?: string;
  /** Tickets in board order, in origin/main's wire shape. */
  tasks: TaskWire[];
  keys: Map<string, string>;
  names?: TaskNames;
  /** The first read is still running (skeleton). */
  loading?: boolean;
  /** The chain could not be read. */
  error?: string;
  chainKind?: string;
  isMobile?: boolean;
  hideTitleBar?: boolean;
  onClose?: () => void;
  /** The fleet table (TicketBoard's fleet slot). */
  fleetSlot?: React.ReactNode;
  /** The card actions on one ticket. */
  actionsFor: (task: TaskWire) => BoardTicketActions;
  /** Card edit fields the source supports (default: all). */
  editFields?: readonly TaskEditField[];
  /** Opens a ticket (an aux ticket tab, or the host's ticket view). */
  onOpenTicket: (taskId: string, title: string, focus?: TicketOpenFocus) => void;
  /** A card's Edit menu. */
  onEditTicket: (taskId: string, field: TaskEditField) => void;
  /** New ticket; without it the board offers no New ticket. */
  create?: TaskChainCreateActions;
}

/**
 * Replacement links (gap G2): a replacement is recorded as a comment and the
 * last comment's preview is the only place the board sees it.
 */
export function replacedByMap(tasks: readonly TaskWire[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const t of tasks) {
    const link = replacementLinks(String(t.comment_summary?.last_comment_preview || '')).replacedBy;
    if (link) out[t.task_id] = link;
  }
  return out;
}

export const TaskChainOverview: React.FC<TaskChainOverviewProps> = ({
  chainId,
  title = '',
  tasks,
  keys,
  names = EMPTY_TASK_NAMES,
  loading = false,
  error = '',
  chainKind = '',
  isMobile = false,
  hideTitleBar = false,
  onClose,
  fleetSlot,
  actionsFor,
  editFields,
  onOpenTicket,
  onEditTicket,
  create,
}) => {
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);

  const openTicket = React.useCallback(
    (taskId: string, focus?: TicketOpenFocus) => {
      const t = tasks.find((x) => x.task_id === taskId);
      onOpenTicket(taskId, ticketTabTitle(keyFor(keys, taskId), t?.title || ''), focus);
    },
    [onOpenTicket, tasks, keys],
  );

  const replacedBy = React.useMemo(() => replacedByMap(tasks), [tasks]);

  if (loading && !tasks.length) {
    return (
      <div data-debug-id="taskchain-loading" className="h-full overflow-hidden bg-canvas">
        <TaskBoardSkeleton />
      </div>
    );
  }

  if (error && !tasks.length) {
    return (
      <div data-debug-id="taskchain-error" className="m-4">
        <Alert tone="danger">Failed to load task chain: {error}</Alert>
      </div>
    );
  }

  return (
    <div data-debug-id="taskchain-overview-container" className="flex w-full min-w-0 flex-col bg-canvas">
      {!hideTitleBar && (
        <header className="flex shrink-0 items-center justify-between gap-2 border-b border-subtle bg-surface px-4 py-3">
          <div className="flex min-w-0 items-center gap-2">
            <Text as="h2" role="title" truncate>
              {title || 'Untitled chain'}
            </Text>
            <Badge tone="neutral">Mixed work</Badge>
          </div>
          {onClose && <IconButton icon="close" label="Close task chain" data-debug-id="taskchain-close-btn" variant="ghost" size="sm" onClick={onClose} />}
        </header>
      )}

      <div className="min-h-0 flex-1">
        <TicketBoard
          chainId={chainId}
          tasks={tasks}
          keys={keys}
          names={names}
          fleetSlot={fleetSlot}
          actionsFor={actionsFor}
          editFields={editFields}
          chainKind={chainKind}
          replacedBy={replacedBy}
          isMobile={isMobile}
          onOpenTicket={openTicket}
          onEditTicket={onEditTicket}
          onNewTask={create ? () => setShowNewTaskModal(true) : undefined}
        />
      </div>

      {create && showNewTaskModal && (
        <CreateTaskModal
          isOpen={showNewTaskModal}
          existingTasks={tasks}
          agentOptions={create.agentOptions}
          create={create.create}
          bridgeOptions={create.bridgeOptions}
          onClose={() => setShowNewTaskModal(false)}
        />
      )}
    </div>
  );
};

export default TaskChainOverview;
