# Heimdall UI Task View Audit & Improvement Plan

This document outlines the issues discovered in the Heimdall task view UI during our audit and proposes specific changes to address them.

---

## 1. Issues Identified

### A. Missing Comment Resolution API Support in `user-rpc` (Backend)
- **Problem**: The backend `/user-rpc` endpoint used by user clients (e.g. the React UI) is missing the case to route `task_comment_resolve` actions. While agent clients can call `/tasks/comment-resolve` directly using their agent tokens, user clients cannot invoke it from the UI.
- **Affected File**: `src/daemon/user_rpc.odin`

### B. Missing API Client and Redux Store Support for Resolving Comments (Frontend)
- **Problem**: The API client helper (`daemonApi.ts`) and Redux actions (`taskSlice.ts`) do not implement methods/thunks to invoke the comment-resolve endpoint.
- **Affected Files**:
  - `src/ui/api/daemonApi.ts`
  - `src/ui/store/taskSlice.ts`

### C. Inability to Distinguish/Resolve Comments in Task View
- **Problem**: The comments pane inside the task detail view renders all comments uniformly. It is impossible to see if a comment is resolved or unresolved, and there is no UI element to resolve an unresolved comment.
- **Affected File**: `src/ui/components/TaskBoard.tsx`

### D. Missing Unresolved Comments Indicator on Task Cards
- **Problem**: The Kanban board does not indicate if a task has unresolved comments, which makes it hard to see why a task might be blocked or reverted.
- **Affected File**: `src/ui/components/TaskBoard.tsx`

### E. Manual Text Entry for Status Update
- **Problem**: Updating a task status in the UI requires typing the status string (e.g. `in_progress`, `review_ready`) into a raw text input field, which is highly error-prone.
- **Affected File**: `src/ui/components/TaskBoard.tsx`

---

## 2. Proposed Changes

### Backend Changes

#### 1. Update `src/daemon/user_rpc.odin`
Add a case to handle `task_comment_resolve` actions:
```odin
	case "task_comment_resolve": handle_user_rpc_task_comment_resolve(client, body, user_id)
```
And define the handler:
```odin
handle_user_rpc_task_comment_resolve :: proc(client: net.TCP_Socket, body, user_id: string) {
	result := task_service_comment_resolve(Task_Comment_Resolve_Command{
		task_id                  = extract_json_string(body, "task_id", ""),
		chain_id                 = extract_json_string(body, "chain_id", ""),
		comment_id               = extract_json_string(body, "comment_id", ""),
		author_agent_instance_id = user_id,
	})
	write_task_service_response(client, result)
}
```

---

### Frontend Changes

#### 2. Update `src/ui/api/daemonApi.ts`
Expose the resolve API method:
```typescript
export async function resolveTaskComment({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, commentId }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; commentId: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_comment_resolve', agentPath: '/tasks/comment-resolve', body: { task_id: taskId, chain_id: chainId || '', comment_id: commentId } });
}
```

#### 3. Update `src/ui/store/taskSlice.ts`
Implement the Redux thunk:
```typescript
export const resolveCommentOnSelectedTask = createAsyncThunk<any, { agentToken?: string; commentId: string }, { state: any }>(
  'tasks/resolveComment',
  async ({ agentToken, commentId }, { getState, dispatch }) => {
    const state = getState();
    const session = state.session || {}; // or whatever session store is named
    const taskId = state.tasks.selectedTaskId;
    const chainId = state.tasks.selectedChainId;
    const result = await daemonApi.resolveTaskComment({
      daemonUrl: session.daemonUrl,
      clientInstanceId: session.clientInstanceId,
      clientToken: session.clientToken,
      agentToken,
      taskId,
      chainId,
      commentId,
    });
    if (result.ok) {
      dispatch(fetchSelectedTaskLog(taskId));
      dispatch(fetchTasksForChain(chainId)); // to refresh task status/unresolved counts
    }
    return result;
  }
);
```

#### 4. Update `src/ui/components/TaskBoard.tsx`
- **Dropdown for Status Selection**: Replace the text input for task status with a `<select>` component:
  ```tsx
  <select
    value={statusForm.status}
    onChange={(event) => setStatusForm({ ...statusForm, status: event.target.value })}
    className="framer-input px-3 py-2 text-sm"
  >
    <option value="planning">planning</option>
    <option value="ready">ready</option>
    <option value="working">in_progress</option>
    <option value="review_ready">review_ready</option>
    <option value="approved">approved</option>
    <option value="blocked">blocked</option>
    <option value="cancelled">cancelled</option>
  </select>
  ```
- **Comment Type Checkbox**: Add a checkbox `Add as Unresolved` to the comment form. When submitting a resolved comment, the frontend will post the comment, get the `comment_id`, and then immediately resolve it.
- **Comment Badging & Action**: Distinguish resolved/unresolved comments using color codes and display a "Resolve" button next to unresolved comments.
- **Kanban Board Badges**: Show a warning label on task cards if `task.unresolved_comment_count > 0`.
