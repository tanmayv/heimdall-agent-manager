// Body for POST /task-chains/{chain}/tasks/{task}/cancel, mirroring the hub's
// Task_Cancel_Request (src/contracts/task_claims.odin). The hub refuses a cancel
// without both fields: the reason goes into the task's audit history, and the
// request_id makes a retried cancel a no-op instead of a second event.
export const DEFAULT_TASK_CANCEL_REASON = 'Cancelled from the web UI';

export interface TaskCancelBody {
  reason: string;
  request_id: string;
}

export function taskCancelBody(reason?: string): TaskCancelBody {
  return { reason: reason?.trim() || DEFAULT_TASK_CANCEL_REASON, request_id: crypto.randomUUID() };
}
