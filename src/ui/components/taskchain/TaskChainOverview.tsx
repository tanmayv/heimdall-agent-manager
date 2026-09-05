import React, { useEffect, useRef, useState } from 'react';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import { TaskCommentsThread } from './TaskCommentsThread';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import Markdown from '../Markdown';
import Icon from '../Icon';
import {
  appendArtifactLinks,
  artifactIdFromLink,
  artifactIdsFromText,
  artifactKindForFile,
  artifactLinkFromResponse,
  artifactMimeForFile,
  artifactUploadName,
  clipboardFilesFromEvent,
} from '../../utils/artifactUpload';
import {
  useFetchTaskChainDetailQuery,
  useCreateTaskMutation,
  useUpdateTaskDetailMutation,
  useSetTaskStatusMutation,
  useCancelTaskDetailMutation,
  useAddTaskCommentMutation,
  useVoteTaskMutation,
  useNudgeTaskMutation,
  useAddChainMemberMutation,
  useRemoveChainMemberMutation,
  useReconcileTaskChainMutation,
} from '../../api/endpoints/tasks';
import { useDispatch } from 'react-redux';
import {
  upsertAgentInCaches,
  useCreateAgentInstanceInChainMutation,
  useFetchAgentInstanceQuery,
  useFetchAgentIdentityQuery,
  useListAgentIdentitiesQuery,
  useListAgentInstancesQuery,
} from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import {
  bridgeLabel,
  launchProvidersFor,
  launchTiersFor,
  launchableBridgeRows,
} from '../../utils/bridgeLaunchOptions';

interface TaskChainOverviewProps {
  chainId: string;
  onClose?: () => void;
  isMobile?: boolean;
}

// Resolves and displays durable agent name for an instance in a select option
export function AgentInstanceOption({
  value,
  instanceId,
  defaultAgentName,
  runtimeStatus,
  disabled,
  suffix = '',
}: {
  value: string;
  instanceId: string;
  defaultAgentName?: string;
  runtimeStatus?: string;
  disabled?: boolean;
  suffix?: string;
}) {
  const trimmed = String(instanceId || '').trim();
  const { data } = useFetchAgentInstanceQuery({ instanceId: trimmed }, { skip: !trimmed || Boolean(defaultAgentName) });
  const inst = data?.instance || null;
  const agentId = String(inst?.agent_id || inst?.agentId || '');

  const { data: agentData } = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId || Boolean(defaultAgentName) });
  const agentName = defaultAgentName || inst?.display_name || inst?.displayName || agentData?.agent?.name || agentData?.agent?.display_name || agentData?.agent?.agent_id || agentId || trimmed;

  const label = agentName !== trimmed
    ? `${agentName} (${trimmed})${suffix}${runtimeStatus ? ` · ${runtimeStatus}` : ''}`
    : `${trimmed}${suffix}${runtimeStatus ? ` · ${runtimeStatus}` : ''}`;

  return (
    <option value={value} disabled={disabled}>
      {label}
    </option>
  );
}

export function MemberInstanceOption({
  value,
  role,
  instanceId,
  disabled,
}: {
  value: string;
  role: string;
  instanceId: string;
  disabled?: boolean;
}) {
  const trimmed = String(instanceId || '').trim();
  const { data } = useFetchAgentInstanceQuery({ instanceId: trimmed }, { skip: !trimmed });
  const inst = data?.instance || null;
  const agentId = String(inst?.agent_id || inst?.agentId || '');

  const { data: agentData } = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const agentName = inst?.display_name || inst?.displayName || agentData?.agent?.name || agentData?.agent?.display_name || agentData?.agent?.agent_id || agentId || trimmed;

  const label = agentName !== trimmed
    ? `${role}: ${agentName} (${trimmed})`
    : `${role}: ${trimmed}`;

  return (
    <option value={value} disabled={disabled}>
      {label}
    </option>
  );
}

type CommentAttachmentStatus = 'uploading' | 'uploaded' | 'error';

type CommentAttachment = {
  localId: string;
  id: string;
  link: string;
  name: string;
  file: File;
  status: CommentAttachmentStatus;
  error: string;
};

export const TaskChainOverview: React.FC<TaskChainOverviewProps> = ({
  chainId,
  onClose,
  isMobile,
}) => {
  const { data, isLoading, error, refetch } = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId }
  );

  const [createTask] = useCreateTaskMutation();
  const [updateTask] = useUpdateTaskDetailMutation();
  const [setStatus] = useSetTaskStatusMutation();
  const [cancelTask] = useCancelTaskDetailMutation();
  const [addComment] = useAddTaskCommentMutation();
  const [createArtifact] = useCreateArtifactMutation();
  const [voteTask] = useVoteTaskMutation();
  const [nudgeTask] = useNudgeTaskMutation();
  const [addMember] = useAddChainMemberMutation();
  const [removeMember] = useRemoveChainMemberMutation();
  const [createInstanceInChain, { isLoading: addingAgent }] = useCreateAgentInstanceInChainMutation();
  const [reconcileChain, reconcileState] = useReconcileTaskChainMutation();
  const [reconcileMsg, setReconcileMsg] = useState('');
  const dispatch = useDispatch();

  // Data sources for the Add-Agent popup's dependent selects.
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });

  // Local state
  // H12: chain description collapsed by default so the chain view is scannable.
  const [descExpanded, setDescExpanded] = useState(false);
  const [completedTasksExpanded, setCompletedTasksExpanded] = useState(false);
  const [cancelledTasksExpanded, setCancelledTasksExpanded] = useState(false);
  const [expandedTaskIds, setExpandedTaskIds] = useState<Record<string, boolean>>({});
  const [commentInputs, setCommentInputs] = useState<Record<string, string>>({});
  const [commentAttachments, setCommentAttachments] = useState<Record<string, CommentAttachment[]>>({});
  const [statusMenuOpenTaskId, setStatusMenuOpenTaskId] = useState<string | null>(null);
  // H12: single quick-actions menu open at a time (mirrors statusMenuOpenTaskId).
  const [actionsMenuOpenTaskId, setActionsMenuOpenTaskId] = useState<string | null>(null);
  const actionsMenuRef = useRef<HTMLDivElement | null>(null);

  // H12: close the quick-actions menu on outside-click (one-open-at-a-time).
  useEffect(() => {
    if (!actionsMenuOpenTaskId) return;
    const onDocClick = (e: MouseEvent) => {
      if (actionsMenuRef.current && !actionsMenuRef.current.contains(e.target as Node)) {
        setActionsMenuOpenTaskId(null);
        setStatusMenuOpenTaskId(null);
      }
    };
    document.addEventListener('mousedown', onDocClick);
    return () => document.removeEventListener('mousedown', onDocClick);
  }, [actionsMenuOpenTaskId]);

  // Modal state
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);
  const [newTaskTitle, setNewTaskTitle] = useState('');
  const [newTaskDesc, setNewTaskDesc] = useState('');
  const [newTaskAssigneeMode, setNewTaskAssigneeMode] = useState<'unassigned' | 'member' | 'existing' | 'user'>('unassigned');
  const [newTaskAssigneeMemberInstanceId, setNewTaskAssigneeMemberInstanceId] = useState('');
  const [newTaskAssigneeAgentId, setNewTaskAssigneeAgentId] = useState('');
  const [newTaskAssigneeInstanceId, setNewTaskAssigneeInstanceId] = useState('');
  const [newTaskAssigneeUserId, setNewTaskAssigneeUserId] = useState('');
  const [newTaskStagedReviewerRefs, setNewTaskStagedReviewerRefs] = useState<any[]>([]);
  const [newTaskAddReviewerMode, setNewTaskAddReviewerMode] = useState<'member' | 'existing' | 'user'>('member');
  const [newTaskAddReviewerMemberInstanceId, setNewTaskAddReviewerMemberInstanceId] = useState('');
  const [newTaskAddReviewerAgentId, setNewTaskAddReviewerAgentId] = useState('');
  const [newTaskAddReviewerInstanceId, setNewTaskAddReviewerInstanceId] = useState('');
  const [newTaskAddReviewerUserId, setNewTaskAddReviewerUserId] = useState('');
  const [newTaskDependsOnIds, setNewTaskDependsOnIds] = useState<string[]>([]);
  const [newTaskError, setNewTaskError] = useState('');
  const [creatingTask, setCreatingTask] = useState(false);
  const [showAddMemberModal, setShowAddMemberModal] = useState(false);
  const [newMemberRole, setNewMemberRole] = useState('worker');
  // H14: two modes — add an EXISTING agent instance (default; the user's mental
  // model of 'add a member'), or LAUNCH a new instance. The existing path uses
  // addChainMember (cookieMutation) directly and avoids the session-token launch
  // transport that silently no-ops in the cookie-authenticated shell.
  const [addMode, setAddMode] = useState<'existing' | 'launch'>('existing');
  const [addExistingInstanceId, setAddExistingInstanceId] = useState('');
  const [addingExisting, setAddingExisting] = useState(false);
  // Add-Agent popup selection state (identity -> bridge -> provider -> tier).
  const [addAgentId, setAddAgentId] = useState('');
  const [addBridgeId, setAddBridgeId] = useState('');
  const [addProvider, setAddProvider] = useState('');
  const [addTier, setAddTier] = useState('');
  const [addAgentError, setAddAgentError] = useState('');

  // Edit Assignee Modal State
  const [editingAssigneeTask, setEditingAssigneeTask] = useState<any | null>(null);
  const [editAssigneeMode, setEditAssigneeMode] = useState<'member' | 'existing' | 'user' | 'unassigned'>('member');
  const [editAssigneeMemberInstanceId, setEditAssigneeMemberInstanceId] = useState('');
  const [editAssigneeAgentId, setEditAssigneeAgentId] = useState('');
  const [editAssigneeInstanceId, setEditAssigneeInstanceId] = useState('');
  const [editAssigneeUserId, setEditAssigneeUserId] = useState('');
  const [savingAssignee, setSavingAssignee] = useState(false);
  const [assigneeError, setAssigneeError] = useState('');

  // Edit Reviewers Modal State
  const [editingReviewersTask, setEditingReviewersTask] = useState<any | null>(null);
  const [stagedReviewerRefs, setStagedReviewerRefs] = useState<any[]>([]);
  const [addReviewerMode, setAddReviewerMode] = useState<'member' | 'existing' | 'user'>('member');
  const [addReviewerMemberInstanceId, setAddReviewerMemberInstanceId] = useState('');
  const [addReviewerAgentId, setAddReviewerAgentId] = useState('');
  const [addReviewerInstanceId, setAddReviewerInstanceId] = useState('');
  const [addReviewerUserId, setAddReviewerUserId] = useState('');
  const [savingReviewers, setSavingReviewers] = useState(false);
  const [reviewersError, setReviewersError] = useState('');

  // Edit Dependencies Modal State
  const [editingDependenciesTask, setEditingDependenciesTask] = useState<any | null>(null);
  const [stagedDependsOnIds, setStagedDependsOnIds] = useState<string[]>([]);
  const [savingDependencies, setSavingDependencies] = useState(false);
  const [dependenciesError, setDependenciesError] = useState('');

  const chain = data?.chain;
  const tasks: any[] = chain?.tasks || [];
  const members: any[] = chain?.members || [];

  // Separate active, completed, and cancelled tasks.
  // Completed/cancelled tasks are sorted chronologically by completion time (updated_at / created_at).
  const isTaskCompleted = (t: any) => t.status === 'completed' || t.status === 'validated_good';
  const isTaskCancelled = (t: any) => t.status === 'cancelled';
  const activeTasks = tasks.filter((t: any) => !isTaskCompleted(t) && !isTaskCancelled(t));
  const completedTasks = tasks
    .filter((t: any) => isTaskCompleted(t))
    .sort((a: any, b: any) => {
      const timeA = new Date(a.updated_at || a.updatedAt || a.created_at || a.createdAt || 0).getTime();
      const timeB = new Date(b.updated_at || b.updatedAt || b.created_at || b.createdAt || 0).getTime();
      return timeA - timeB;
    });
  const cancelledTasks = tasks
    .filter((t: any) => isTaskCancelled(t))
    .sort((a: any, b: any) => {
      const timeA = new Date(a.updated_at || a.updatedAt || a.created_at || a.createdAt || 0).getTime();
      const timeB = new Date(b.updated_at || b.updatedAt || b.created_at || b.createdAt || 0).getTime();
      return timeA - timeB;
    });

  // Add-Agent popup dependent option lists (identity -> bridge -> provider -> tier).
  const agentIdentities: any[] = agentIdentitiesQuery.data?.agents || [];
  const addBridgeRows = launchableBridgeRows(bridgesQuery.data?.bridges || []);
  const selectedAddBridge = addBridgeRows.find((row) => row.bridgeId === addBridgeId)?.bridge;
  const selectedAddAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === addAgentId);
  const selectedAssigneeAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === editAssigneeAgentId);
  const selectedReviewerAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === addReviewerAgentId);
  const selectedNewTaskAssigneeAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === newTaskAssigneeAgentId);
  const selectedNewTaskReviewerAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === newTaskAddReviewerAgentId);
  // H14: existing instances of the chosen identity (cookieJsonFetch — works in the
  // shell). Only offered in 'existing' mode; skip the fetch otherwise.
  const existingInstancesQuery = useListAgentInstancesQuery(
    { agentId: addAgentId },
    { skip: !addAgentId || addMode !== 'existing' },
  );
  const existingInstances: any[] = existingInstancesQuery.data?.instances || [];
  const assigneeInstancesQuery = useListAgentInstancesQuery(
    { agentId: editAssigneeAgentId },
    { skip: !editAssigneeAgentId || editAssigneeMode !== 'existing' },
  );
  const assigneeExistingInstances: any[] = assigneeInstancesQuery.data?.instances || [];
  const reviewerInstancesQuery = useListAgentInstancesQuery(
    { agentId: addReviewerAgentId },
    { skip: !addReviewerAgentId || addReviewerMode !== 'existing' },
  );
  const reviewerExistingInstances: any[] = reviewerInstancesQuery.data?.instances || [];
  const newTaskAssigneeInstancesQuery = useListAgentInstancesQuery(
    { agentId: newTaskAssigneeAgentId },
    { skip: !newTaskAssigneeAgentId || newTaskAssigneeMode !== 'existing' },
  );
  const newTaskAssigneeExistingInstances: any[] = newTaskAssigneeInstancesQuery.data?.instances || [];
  const newTaskReviewerInstancesQuery = useListAgentInstancesQuery(
    { agentId: newTaskAddReviewerAgentId },
    { skip: !newTaskAddReviewerAgentId || newTaskAddReviewerMode !== 'existing' },
  );
  const newTaskReviewerExistingInstances: any[] = newTaskReviewerInstancesQuery.data?.instances || [];
  const memberInstanceIds = new Set(members.map((m: any) => String(m.agentInstanceId || m.agent_instance_id || '')));
  const addProviderOptions = selectedAddBridge ? launchProvidersFor(selectedAddBridge) : [];
  const addTierOptions = selectedAddBridge ? launchTiersFor(selectedAddBridge, addProvider, selectedAddAgent) : [];

  // Compute progress buckets
  const progressBuckets = {
    todo: tasks.filter((t) => t.status === 'assigned' || t.status === 'pending').length,
    in_progress: tasks.filter((t) => t.status === 'in_progress').length,
    in_validation: tasks.filter((t) => t.status === 'in_validation').length,
    validated_good: tasks.filter((t) => t.status === 'validated_good' || t.status === 'completed').length,
    blocked: tasks.filter((t) => t.blocked).length,
  };

  const toggleTaskExpanded = (id: string) => {
    setExpandedTaskIds((prev) => ({ ...prev, [id]: !prev[id] }));
  };

  const handleAddNewTaskStagedReviewer = () => {
    let ref: any = null;
    if (newTaskAddReviewerMode === 'member') {
      if (!newTaskAddReviewerMemberInstanceId) return;
      ref = { type: 'agent_instance', agent_instance_id: newTaskAddReviewerMemberInstanceId };
    } else if (newTaskAddReviewerMode === 'existing') {
      if (!newTaskAddReviewerInstanceId) return;
      ref = { type: 'agent_instance', agent_instance_id: newTaskAddReviewerInstanceId };
    } else if (newTaskAddReviewerMode === 'user') {
      const uid = newTaskAddReviewerUserId.trim();
      if (!uid) return;
      ref = { type: 'user', user_id: uid };
    }
    if (!ref) return;
    const exists = newTaskStagedReviewerRefs.some((r) =>
      r.type === ref.type && (
        (ref.agent_instance_id && r.agent_instance_id === ref.agent_instance_id) ||
        (ref.user_id && r.user_id === ref.user_id)
      )
    );
    if (!exists) {
      setNewTaskStagedReviewerRefs((prev) => [...prev, ref]);
    }
    setNewTaskAddReviewerMemberInstanceId('');
    setNewTaskAddReviewerInstanceId('');
    setNewTaskAddReviewerUserId('');
  };

  const handleRemoveNewTaskStagedReviewer = (index: number) => {
    setNewTaskStagedReviewerRefs((prev) => prev.filter((_, i) => i !== index));
  };

  const resetNewTaskForm = () => {
    setNewTaskTitle('');
    setNewTaskDesc('');
    setNewTaskAssigneeMode('unassigned');
    setNewTaskAssigneeMemberInstanceId('');
    setNewTaskAssigneeAgentId('');
    setNewTaskAssigneeInstanceId('');
    setNewTaskAssigneeUserId('');
    setNewTaskStagedReviewerRefs([]);
    setNewTaskAddReviewerMode('member');
    setNewTaskAddReviewerMemberInstanceId('');
    setNewTaskAddReviewerAgentId('');
    setNewTaskAddReviewerInstanceId('');
    setNewTaskAddReviewerUserId('');
    setNewTaskDependsOnIds([]);
    setNewTaskError('');
    setCreatingTask(false);
  };

  const handleCreateTask = async (e: React.FormEvent) => {
    e.preventDefault();
    setNewTaskError('');
    if (!newTaskTitle.trim()) return;

    let assigneeRef: any = undefined;
    if (newTaskAssigneeMode === 'member') {
      if (!newTaskAssigneeMemberInstanceId) {
        setNewTaskError('Please select a chain member or change assignee mode.');
        return;
      }
      assigneeRef = { type: 'agent_instance', agent_instance_id: newTaskAssigneeMemberInstanceId };
    } else if (newTaskAssigneeMode === 'existing') {
      if (!newTaskAssigneeInstanceId) {
        setNewTaskError('Please select an existing agent instance or change assignee mode.');
        return;
      }
      assigneeRef = { type: 'agent_instance', agent_instance_id: newTaskAssigneeInstanceId };
    } else if (newTaskAssigneeMode === 'user') {
      const uid = newTaskAssigneeUserId.trim();
      if (!uid) {
        setNewTaskError('Please enter a user ID.');
        return;
      }
      assigneeRef = { type: 'user', user_id: uid };
    }

    setCreatingTask(true);
    try {
      const payload: any = {
        chainId,
        title: newTaskTitle.trim(),
        description: newTaskDesc.trim(),
      };
      if (assigneeRef !== undefined) {
        payload.assigneeRef = assigneeRef;
      }
      if (newTaskStagedReviewerRefs.length > 0) {
        payload.reviewerRefs = newTaskStagedReviewerRefs;
      }
      if (newTaskDependsOnIds.length > 0) {
        payload.dependsOn = newTaskDependsOnIds;
      }

      await createTask(payload).unwrap();
      resetNewTaskForm();
      setShowNewTaskModal(false);
      refetch();
    } catch (err: any) {
      console.error('Failed to create task:', err);
      setNewTaskError(String(err?.data?.message || err?.message || 'Failed to create task'));
    } finally {
      setCreatingTask(false);
    }
  };

  // Add-Agent popup: LAUNCH a new instance of the chosen agent-id on the chosen
  // bridge/provider/tier bound to THIS chain, then add it as a member with the
  // selected role. bridge_id/chain_id/provider/tier are honored by the hub's
  // POST /api/v1/agent-instances handler (instance_input_from_body), so this is a
  // pure UI plumb through createAgentInstanceInChain.
  // H14: add an EXISTING agent instance as a member via addChainMember directly
  // (cookieMutation) — no launch, no session token. This is the reliable path in
  // the cookie-authenticated shell and matches the user's 'add a member' model.
  const handleAddExistingMember = async () => {
    setAddAgentError('');
    if (!addExistingInstanceId) { setAddAgentError('Choose an existing agent instance to add.'); return; }
    setAddingExisting(true);
    try {
      const res: any = await addMember({ chainId, agentInstanceId: addExistingInstanceId, role: newMemberRole });
      // RTK Query returns { data } on success or { error } on failure; surface it.
      if (res?.error) {
        setAddAgentError(String(res.error?.error || res.error?.message || 'Failed to add member.'));
        return;
      }
      setShowAddMemberModal(false);
      setAddAgentId(''); setAddExistingInstanceId('');
      refetch();
    } catch (err: any) {
      setAddAgentError(String(err?.message || err || 'Failed to add member.'));
    } finally {
      setAddingExisting(false);
    }
  };

  const handleAddMember = async (e: React.FormEvent) => {
    e.preventDefault();
    setAddAgentError('');
    // H14: route to the reliable existing-instance path when in that mode.
    if (addMode === 'existing') { await handleAddExistingMember(); return; }
    if (!addAgentId) { setAddAgentError('Choose an agent identity to launch.'); return; }
    if (addProvider && !addProviderOptions.includes(addProvider)) { setAddAgentError('Selected provider is not supported by the chosen bridge.'); return; }
    if (addTier && !addTierOptions.includes(addTier)) { setAddAgentError('Selected tier is not supported by the chosen bridge/provider.'); return; }
    try {
      const result: any = await createInstanceInChain({
        agentId: addAgentId,
        chainId,
        ...(addBridgeId ? { bridgeId: addBridgeId } : {}),
        ...(addProvider ? { providerProfile: addProvider } : {}),
        ...(addTier ? { modelTier: addTier } : {}),
      }).unwrap();
      // H14: the launch mutation RESOLVES { ok:false } (it does not reject) when the
      // shell has no session token. Do NOT swallow that — surface it instead of a
      // silent no-op.
      // The cookie path (POST /agent-instances) returns the instance object
      // FLAT (agent_instance_id at top level); the older token path nested it under
      // agent_instance/agent. Accept both shapes.
      const newInstance = result?.agent_instance || result?.agentInstance || result?.agent
        || ((result?.agent_instance_id || result?.agentInstanceId) ? result : undefined);
      const newInstanceId = String(newInstance?.agent_instance_id || newInstance?.agentInstanceId || '');
      if (result?.ok === false || !newInstanceId) {
        setAddAgentError(String(result?.message || 'Could not launch a new instance in this app session. Use “Add existing instance” instead.'));
        return;
      }
      upsertAgentInCaches(dispatch, newInstance);
      // Ensure the new instance is a chain member with the chosen role (create may
      // not attach the role). Skip if it already landed as a member.
      const alreadyMember = members.some((m: any) => String(m.agentInstanceId || m.agent_instance_id || '') === newInstanceId);
      if (!alreadyMember) {
        const memberRes: any = await addMember({ chainId, agentInstanceId: newInstanceId, role: newMemberRole });
        if (memberRes?.error) {
          setAddAgentError(String(memberRes.error?.error || memberRes.error?.message || 'Instance launched but adding it as a member failed.'));
          refetch();
          return;
        }
      }
      setShowAddMemberModal(false);
      setAddAgentId(''); setAddBridgeId(''); setAddProvider(''); setAddTier('');
      refetch();
    } catch (err: any) {
      setAddAgentError(String(err?.message || err || 'Failed to launch and add agent'));
    }
  };

  const handleRemoveMember = async (agentInstanceId: string) => {
    try {
      await removeMember({ chainId, agentInstanceId }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to remove member:', err);
    }
  };

  const openEditAssigneeModal = (task: any) => {
    setEditingAssigneeTask(task);
    setAssigneeError('');
    if (task.assigneeRef?.agent_instance_id) {
      const instId = task.assigneeRef.agent_instance_id;
      const isMember = members.some((m: any) => (m.agentInstanceId || m.agent_instance_id) === instId);
      if (isMember) {
        setEditAssigneeMode('member');
        setEditAssigneeMemberInstanceId(instId);
      } else {
        setEditAssigneeMode('existing');
        setEditAssigneeInstanceId(instId);
      }
    } else if (task.assigneeRef?.user_id) {
      setEditAssigneeMode('user');
      setEditAssigneeUserId(task.assigneeRef.user_id);
    } else {
      setEditAssigneeMode(members.length > 0 ? 'member' : 'unassigned');
      setEditAssigneeMemberInstanceId(members[0]?.agentInstanceId || members[0]?.agent_instance_id || '');
    }
  };

  const handleSaveAssignee = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingAssigneeTask) return;
    setSavingAssignee(true);
    setAssigneeError('');
    try {
      let assigneeRef: any = null;
      if (editAssigneeMode === 'member') {
        if (!editAssigneeMemberInstanceId) throw new Error('Please select a chain member.');
        assigneeRef = { type: 'agent_instance', agent_instance_id: editAssigneeMemberInstanceId };
      } else if (editAssigneeMode === 'existing') {
        if (!editAssigneeInstanceId) throw new Error('Please select an agent instance.');
        assigneeRef = { type: 'agent_instance', agent_instance_id: editAssigneeInstanceId };
      } else if (editAssigneeMode === 'user') {
        if (!editAssigneeUserId.trim()) throw new Error('Please enter a user ID.');
        assigneeRef = { type: 'user', user_id: editAssigneeUserId.trim() };
      } else if (editAssigneeMode === 'unassigned') {
        assigneeRef = null;
      }
      await updateTask({
        chainId,
        taskId: editingAssigneeTask.taskId,
        assigneeRef,
      }).unwrap();
      setEditingAssigneeTask(null);
      await refetch();
    } catch (err: any) {
      setAssigneeError(String(err?.data?.error?.message || err?.message || 'Failed to update assignee'));
    } finally {
      setSavingAssignee(false);
    }
  };

  const openEditReviewersModal = (task: any) => {
    setEditingReviewersTask(task);
    setStagedReviewerRefs(task.reviewerRefs ? [...task.reviewerRefs] : []);
    setReviewersError('');
    setAddReviewerMode('member');
    setAddReviewerMemberInstanceId(members[0]?.agentInstanceId || members[0]?.agent_instance_id || '');
    setAddReviewerAgentId('');
    setAddReviewerInstanceId('');
    setAddReviewerUserId('');
  };

  const handleAddStagedReviewer = () => {
    setReviewersError('');
    let refToAdd: any = null;
    if (addReviewerMode === 'member') {
      if (!addReviewerMemberInstanceId) {
        setReviewersError('Select a chain member to add as reviewer.');
        return;
      }
      refToAdd = { type: 'agent_instance', agent_instance_id: addReviewerMemberInstanceId };
    } else if (addReviewerMode === 'existing') {
      if (!addReviewerInstanceId) {
        setReviewersError('Select an agent instance to add as reviewer.');
        return;
      }
      refToAdd = { type: 'agent_instance', agent_instance_id: addReviewerInstanceId };
    } else if (addReviewerMode === 'user') {
      if (!addReviewerUserId.trim()) {
        setReviewersError('Enter a user ID to add as reviewer.');
        return;
      }
      refToAdd = { type: 'user', user_id: addReviewerUserId.trim() };
    }
    if (refToAdd) {
      const exists = stagedReviewerRefs.some((r) =>
        (r.agent_instance_id && r.agent_instance_id === refToAdd.agent_instance_id) ||
        (r.user_id && r.user_id === refToAdd.user_id)
      );
      if (exists) {
        setReviewersError('This reviewer is already added.');
        return;
      }
      setStagedReviewerRefs([...stagedReviewerRefs, refToAdd]);
    }
  };

  const handleRemoveStagedReviewer = (index: number) => {
    setStagedReviewerRefs(stagedReviewerRefs.filter((_, i) => i !== index));
  };

  const handleSaveReviewers = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingReviewersTask) return;
    setSavingReviewers(true);
    setReviewersError('');
    try {
      await updateTask({
        chainId,
        taskId: editingReviewersTask.taskId,
        reviewerRefs: stagedReviewerRefs,
      }).unwrap();
      setEditingReviewersTask(null);
      await refetch();
    } catch (err: any) {
      setReviewersError(String(err?.data?.error?.message || err?.message || 'Failed to update reviewers'));
    } finally {
      setSavingReviewers(false);
    }
  };

  const openEditDependenciesModal = (task: any) => {
    setEditingDependenciesTask(task);
    setStagedDependsOnIds(task.dependsOn ? [...task.dependsOn] : []);
    setDependenciesError('');
  };

  const handleSaveDependencies = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingDependenciesTask) return;
    setSavingDependencies(true);
    setDependenciesError('');
    try {
      await updateTask({
        chainId,
        taskId: editingDependenciesTask.taskId,
        dependsOn: stagedDependsOnIds,
      }).unwrap();
      setEditingDependenciesTask(null);
      await refetch();
    } catch (err: any) {
      setDependenciesError(String(err?.data?.error?.message || err?.data?.message || err?.message || 'Failed to update dependencies'));
    } finally {
      setSavingDependencies(false);
    }
  };

  const updateCommentAttachments = (taskId: string, updater: (items: CommentAttachment[]) => CommentAttachment[]) => {
    setCommentAttachments((prev) => ({
      ...prev,
      [taskId]: updater(prev[taskId] || []),
    }));
  };

  const uploadCommentAttachment = async (taskId: string, file: File, existingLocalId = '') => {
    const localId = existingLocalId || `task_att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = artifactUploadName(file, 'task-comment-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    updateCommentAttachments(taskId, (items) => [
      ...items.filter((item) => item.localId !== localId),
      {
        localId,
        id: '',
        link: '',
        name,
        file,
        status: tooLarge ? 'error' : 'uploading',
        error: tooLarge ? `File is too large. Maximum upload size is ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.` : '',
      },
    ]);
    if (tooLarge) return;
    try {
      const res = await createArtifact({
        file,
        name,
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        originKind: 'task_comment',
        originRef: `${chainId}:${taskId}`,
      }).unwrap();
      const link = artifactLinkFromResponse(res);
      const id = artifactIdFromLink(link);
      if (!id) throw new Error('Upload failed: Hub did not return an artifact id.');
      updateCommentAttachments(taskId, (items) => items.map((item) => (
        item.localId === localId ? { ...item, id, link, status: 'uploaded', error: '' } : item
      )));
    } catch (err: any) {
      const message = String(err?.data?.message || err?.message || err || 'Upload failed');
      updateCommentAttachments(taskId, (items) => items.map((item) => (
        item.localId === localId ? { ...item, status: 'error', error: message } : item
      )));
    }
  };

  const handleCommentPaste = (event: React.ClipboardEvent<HTMLInputElement>, taskId: string) => {
    const files = clipboardFilesFromEvent(event);
    if (files.length === 0) return;
    event.preventDefault();
    files.forEach((file) => void uploadCommentAttachment(taskId, file));
  };

  const handleAddComment = async (taskId: string) => {
    const text = commentInputs[taskId]?.trim() || '';
    const attachments = commentAttachments[taskId] || [];
    if (attachments.some((item) => item.status === 'uploading' || item.status === 'error')) return;
    const body = appendArtifactLinks(text, attachments.filter((item) => item.status === 'uploaded' && item.link).map((item) => item.link)).trim();
    if (!body) return;
    try {
      await addComment({ chainId, taskId, body }).unwrap();
      setCommentInputs((prev) => ({ ...prev, [taskId]: '' }));
      setCommentAttachments((prev) => ({ ...prev, [taskId]: [] }));
      refetch();
    } catch (err) {
      console.error('Failed to add comment:', err);
    }
  };

  const handleVote = async (taskId: string, result: 'lgtm' | 'ngtm') => {
    try {
      await voteTask({ chainId, taskId, result }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to vote:', err);
    }
  };

  const handleStatusChange = async (taskId: string, status: string) => {
    try {
      await setStatus({ chainId, taskId, status, body: '' }).unwrap();
      setStatusMenuOpenTaskId(null);
      refetch();
    } catch (err) {
      console.error('Failed to update status:', err);
    }
  };

  const handleCancelTask = async (taskId: string) => {
    try {
      await cancelTask({ chainId, taskId }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to cancel task:', err);
    }
  };

  const handleNudge = async (taskId: string) => {
    try {
      await nudgeTask({ chainId, taskId, message: 'Nudge: please check task status' }).unwrap();
    } catch (err) {
      console.error('Failed to nudge:', err);
    }
  };

  const renderTaskCard = (task: any) => {
    const taskId = task.taskId || task.id;
    const isExpanded = Boolean(expandedTaskIds[taskId]);
    const taskCommentAttachments = commentAttachments[taskId] || [];
    const taskCommentUploading = taskCommentAttachments.some((item) => item.status === 'uploading');
    const taskCommentFailed = taskCommentAttachments.some((item) => item.status === 'error');
    const taskCommentReady = taskCommentAttachments.filter((item) => item.status === 'uploaded' && item.link);
    const taskCommentCanSend = !taskCommentUploading && !taskCommentFailed && (Boolean((commentInputs[taskId] || '').trim()) || taskCommentReady.length > 0);

    return (
      <div
        key={taskId}
        data-debug-id={`taskchain-task-row-${taskId}`}
        className="rounded-lg border border-white/10 bg-[#111111] p-3 text-xs"
      >
        {/* Main Card Header */}
        <div className="flex items-start justify-between gap-2">
          <div className="flex items-start gap-2">
            <button
              type="button"
              data-debug-id={`taskchain-task-expand-btn-${taskId}`}
              onClick={() => toggleTaskExpanded(taskId)}
              className="mt-0.5 text-zinc-400 hover:text-white"
            >
              {isExpanded ? '▾' : '▸'}
            </button>
            <div>
              <div
                data-debug-id={`taskchain-task-title-${taskId}`}
                className="font-semibold text-white"
              >
                {task.title}
              </div>
              <div className="mt-1 flex flex-wrap items-center gap-3 text-[11px] text-zinc-400">
                <span data-debug-id={`taskchain-task-assignee-${taskId}`} className="inline-flex items-center gap-1">
                  {task.assigneeRef ? (
                    <>
                      assignee: {task.assigneeRef.agent_instance_id
                        ? <InstanceIdLink instanceId={task.assigneeRef.agent_instance_id} />
                        : <span className="text-zinc-300">{task.assigneeRef.user_id}</span>}
                    </>
                  ) : (
                    <span>assignee: <span className="text-zinc-500">unassigned</span></span>
                  )}
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-edit-assignee-btn-${taskId}`}
                    title="Change assignee"
                    onClick={(e) => { e.stopPropagation(); openEditAssigneeModal(task); }}
                    className="ml-0.5 text-zinc-400 hover:text-white"
                  >
                    <Icon name="pencil" size={11} />
                  </button>
                </span>

                <span data-debug-id={`taskchain-task-reviewers-${taskId}`} className="inline-flex items-center gap-1">
                  reviewers: {task.reviewerRefs && task.reviewerRefs.length > 0 ? (
                    <span>
                      {task.reviewerRefs.map((r: any, ri: number) => (
                        <React.Fragment key={r.agent_instance_id || r.user_id || ri}>
                          {ri > 0 ? ', ' : ''}
                          {r.agent_instance_id
                            ? <InstanceIdLink instanceId={r.agent_instance_id} />
                            : <span className="text-zinc-300">{r.user_id}</span>}
                        </React.Fragment>
                      ))}
                    </span>
                  ) : (
                    <span className="text-zinc-500">none</span>
                  )}
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-edit-reviewers-btn-${taskId}`}
                    title="Edit reviewers"
                    onClick={(e) => { e.stopPropagation(); openEditReviewersModal(task); }}
                    className="ml-0.5 text-zinc-400 hover:text-white"
                  >
                    <Icon name="pencil" size={11} />
                  </button>
                </span>

                <span data-debug-id={`taskchain-task-depends-on-${taskId}`} className="inline-flex items-center gap-1">
                  <span>depends on: <span className={task.dependsOn && task.dependsOn.length > 0 ? 'text-zinc-200' : 'text-zinc-500'}>{task.dependsOn ? task.dependsOn.length : 0}</span></span>
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-edit-dependencies-btn-${taskId}`}
                    title="Edit dependencies"
                    onClick={(e) => { e.stopPropagation(); openEditDependenciesModal(task); }}
                    className="ml-0.5 text-zinc-400 hover:text-white"
                  >
                    <Icon name="pencil" size={11} />
                  </button>
                </span>
              </div>
            </div>
          </div>

          {/* H12: compact right side — status/blocked badges + a single
              quick-actions MENU button (actionable without expanding). */}
          <div className="flex items-center gap-2">
            {task.blocked && (
              <span
                data-debug-id={`taskchain-task-blocked-${taskId}`}
                className="rounded bg-amber-900/50 px-2 py-0.5 font-semibold text-amber-300"
              >
                ⛔ blocked
              </span>
            )}
            <span
              data-debug-id={`taskchain-task-status-${taskId}`}
              className="rounded bg-zinc-800 px-2 py-0.5 font-mono uppercase text-zinc-300"
            >
              {task.status}
            </span>
            <div
              className="relative inline-block text-left"
              ref={actionsMenuOpenTaskId === taskId ? actionsMenuRef : undefined}
            >
              <button
                type="button"
                data-debug-id={`taskchain-task-actions-menu-btn-${taskId}`}
                aria-haspopup="menu"
                aria-expanded={actionsMenuOpenTaskId === taskId}
                title="Quick actions"
                onClick={() => {
                  setActionsMenuOpenTaskId(actionsMenuOpenTaskId === taskId ? null : taskId);
                  setStatusMenuOpenTaskId(null);
                }}
                className="rounded bg-zinc-800 px-2 py-0.5 text-[13px] font-semibold text-zinc-300 hover:bg-zinc-700"
              >
                ⋯
              </button>
              {actionsMenuOpenTaskId === taskId && (
                <div
                  data-debug-id={`taskchain-task-actions-menu-${taskId}`}
                  className="absolute right-0 z-30 mt-1 w-40 rounded border border-white/10 bg-[#181818] p-1 shadow-lg"
                >
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-nudge-btn-${taskId}`}
                    onClick={() => { setActionsMenuOpenTaskId(null); void handleNudge(taskId); }}
                    className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-zinc-300 hover:bg-white/10"
                  >
                    Nudge
                  </button>
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-lgtm-btn-${taskId}`}
                    onClick={() => { setActionsMenuOpenTaskId(null); void handleVote(taskId, 'lgtm'); }}
                    className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-emerald-400 hover:bg-emerald-900/40"
                  >
                    LGTM
                  </button>
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-ngtm-btn-${taskId}`}
                    onClick={() => { setActionsMenuOpenTaskId(null); void handleVote(taskId, 'ngtm'); }}
                    className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-red-400 hover:bg-red-900/40"
                  >
                    NGTM
                  </button>
                  {/* Status submenu (kept inline; one status list at a time). */}
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-status-menu-btn-${taskId}`}
                    onClick={() => setStatusMenuOpenTaskId(statusMenuOpenTaskId === taskId ? null : taskId)}
                    className="block w-full rounded px-3 py-1.5 text-left text-[11px] font-semibold text-zinc-300 hover:bg-white/10"
                  >
                    Status ▾
                  </button>
                  {statusMenuOpenTaskId === taskId && (
                    <div className="ml-2 border-l border-white/10 pl-1">
                      {['in_progress', 'in_validation', 'paused', 'completed'].map((st) => (
                        <button
                          key={st}
                          type="button"
                          data-debug-id={`taskchain-task-status-${st}-btn-${taskId}`}
                          onClick={() => { setActionsMenuOpenTaskId(null); setStatusMenuOpenTaskId(null); void handleStatusChange(taskId, st); }}
                          className="block w-full rounded px-3 py-1.5 text-left text-[11px] text-zinc-300 hover:bg-white/10"
                        >
                          {st}
                        </button>
                      ))}
                    </div>
                  )}
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-cancel-btn-${taskId}`}
                    onClick={() => { setActionsMenuOpenTaskId(null); void handleCancelTask(taskId); }}
                    className="mt-0.5 block w-full rounded border-t border-white/10 px-3 py-1.5 text-left text-[11px] font-semibold text-zinc-400 hover:bg-red-900/50 hover:text-red-300"
                  >
                    Cancel
                  </button>
                </div>
              )}
            </div>
          </div>
        </div>

        {/* Expanded Card Details (Description, Dependencies & Comments) */}
        {isExpanded && (
          <div className="mt-3 border-t border-white/5 pt-3 space-y-3">
            {/* H12: full description shows ONLY when expanded. */}
            {task.description && (
              <div
                data-debug-id={`taskchain-task-description-${taskId}`}
                className="text-[11.5px] leading-5 text-zinc-300"
              >
                <Markdown source={task.description} compact copyAll={false} />
              </div>
            )}
            {/* Dependencies in expanded view */}
            <div data-debug-id={`taskchain-task-dependencies-section-${taskId}`} className="rounded border border-white/5 bg-zinc-900/40 p-2 text-[11px]">
              <div className="flex items-center justify-between">
                <span className="font-semibold text-zinc-400">
                  Blocked on ({task.dependsOn ? task.dependsOn.length : 0}):
                </span>
                <button
                  type="button"
                  data-debug-id={`taskchain-task-manage-dependencies-btn-${taskId}`}
                  onClick={() => openEditDependenciesModal(task)}
                  className="rounded bg-zinc-800 px-2 py-0.5 text-sky-400 hover:bg-zinc-700 hover:text-sky-300"
                >
                  Manage dependencies
                </button>
              </div>
              {task.dependsOn && task.dependsOn.length > 0 ? (
                <div data-debug-id={`taskchain-task-dependencies-list-${taskId}`} className="mt-1.5 space-y-1">
                  {task.dependsOn.map((depId: string) => {
                    const depTask = tasks.find((t: any) => String(t.taskId || t.id) === String(depId));
                    return (
                      <div
                        key={depId}
                        data-debug-id={`taskchain-task-dependency-item-${taskId}-${depId}`}
                        className="flex items-center justify-between rounded bg-zinc-950/60 px-2 py-1"
                      >
                        <div className="flex items-center gap-2 min-w-0">
                          <span className="font-mono text-zinc-400 text-[10px]">{depId}</span>
                          <span className="truncate font-medium text-zinc-200">
                            {depTask ? depTask.title : depId}
                          </span>
                        </div>
                        {depTask ? (
                          <span className="shrink-0 rounded bg-zinc-800 px-1.5 py-0.5 text-[10px] uppercase font-mono text-zinc-300">
                            {depTask.status}
                          </span>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              ) : (
                <p className="mt-1 text-[11px] text-zinc-500 italic">No dependencies configured.</p>
              )}
            </div>

            {/* Comments Thread — bodies lazy-loaded on expand; list ships only a summary. */}
            <TaskCommentsThread
              chainId={chainId}
              taskId={taskId}
              summary={task.commentSummary}
              enabled={isExpanded}
            />
            <div className="space-y-2">
              {/* Comment Composer */}
              <div className="space-y-2 pt-1">
                {taskCommentAttachments.length > 0 ? (
                  <div data-debug-id={`taskchain-task-comment-attachment-tray-${taskId}`} className="space-y-1 rounded border border-white/10 bg-black/20 p-2">
                    {taskCommentAttachments.map((attachment) => (
                      <div key={attachment.localId} data-debug-id={`taskchain-task-comment-attachment-${taskId}-${attachment.localId}`} className="rounded bg-zinc-950/60 px-2 py-1.5">
                        <div className="flex min-w-0 items-center gap-2">
                          <span className={attachment.status === 'uploaded' ? 'text-emerald-300' : attachment.status === 'error' ? 'text-red-300' : 'text-sky-300'}>{attachment.status === 'uploading' ? '⇧' : attachment.status === 'uploaded' ? '✓' : '!'}</span>
                          <span className="min-w-0 flex-1 truncate" title={attachment.name}>{attachment.name}</span>
                          <span className={attachment.status === 'uploaded' ? 'text-emerald-300' : attachment.status === 'error' ? 'text-red-300' : 'text-sky-300'}>{attachment.status === 'uploading' ? 'Uploading…' : attachment.status === 'uploaded' ? 'Uploaded' : 'Failed'}</span>
                          {attachment.status === 'error' ? (
                            <button type="button" data-debug-id={`taskchain-task-comment-attachment-retry-${taskId}-${attachment.localId}`} onClick={() => void uploadCommentAttachment(taskId, attachment.file, attachment.localId)} className="rounded border border-white/10 px-2 py-0.5 text-zinc-300 hover:bg-white/10">
                              Retry
                            </button>
                          ) : null}
                          <button type="button" data-debug-id={`taskchain-task-comment-attachment-remove-${taskId}-${attachment.localId}`} onClick={() => updateCommentAttachments(taskId, (items) => items.filter((item) => item.localId !== attachment.localId))} className="rounded border border-white/10 px-2 py-0.5 text-zinc-400 hover:bg-white/10">
                            Remove
                          </button>
                        </div>
                        {attachment.status === 'uploading' ? <div data-debug-id={`taskchain-task-comment-attachment-progress-${taskId}-${attachment.localId}`} className="mt-1 h-1 overflow-hidden rounded-full bg-white/10"><div className="h-full w-1/2 animate-pulse rounded-full bg-sky-300" /></div> : null}
                        {attachment.error ? <div data-debug-id={`taskchain-task-comment-attachment-error-${taskId}-${attachment.localId}`} className="mt-1 text-red-300">{attachment.error}</div> : null}
                      </div>
                    ))}
                    {taskCommentUploading ? <div data-debug-id={`taskchain-task-comment-uploading-hint-${taskId}`} className="text-[11px] text-zinc-500">You can keep typing. Send unlocks when uploads finish.</div> : null}
                    {taskCommentFailed ? <div data-debug-id={`taskchain-task-comment-failed-hint-${taskId}`} className="text-[11px] text-red-300">Retry or remove failed uploads before sending.</div> : null}
                  </div>
                ) : null}
                <div className="flex min-w-0 gap-2">
                  <label data-debug-id={`taskchain-task-comment-attach-btn-${taskId}`} className="grid h-8 w-8 shrink-0 cursor-pointer place-items-center rounded border border-white/10 bg-zinc-900 text-sm font-semibold text-zinc-400 hover:border-sky-500 hover:text-white" title="Upload attachment">
                    <input
                      type="file"
                      multiple
                      data-debug-id={`taskchain-task-comment-attach-input-${taskId}`}
                      className="hidden"
                      onChange={(e) => {
                        const files = Array.from(e.target.files || []) as File[];
                        e.target.value = '';
                        files.forEach((file) => void uploadCommentAttachment(taskId, file));
                      }}
                    />
                    ＋
                  </label>
                  <input
                    type="text"
                    data-debug-id={`taskchain-task-comment-input-${taskId}`}
                    placeholder="Write a comment, paste an image/file, or attach one..."
                    value={commentInputs[taskId] || ''}
                    onChange={(e) => setCommentInputs({ ...commentInputs, [taskId]: e.target.value })}
                    onPaste={(e) => handleCommentPaste(e, taskId)}
                    className="min-w-0 flex-1 rounded border border-white/10 bg-zinc-900 px-2 py-1 text-base text-white placeholder-zinc-500 focus:border-sky-500 focus:outline-none sm:text-sm"
                  />
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-comment-submit-btn-${taskId}`}
                    disabled={!taskCommentCanSend}
                    onClick={() => handleAddComment(taskId)}
                    title={taskCommentUploading ? 'Wait for uploads to finish before sending' : taskCommentFailed ? 'Retry or remove failed uploads before sending' : 'Send comment'}
                    className="rounded bg-sky-600 px-3 py-1 font-semibold text-white hover:bg-sky-500 disabled:cursor-not-allowed disabled:bg-zinc-700 disabled:text-zinc-400"
                  >
                    {taskCommentUploading ? 'Uploading…' : 'Send'}
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    );
  };

  if (!chainId) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-zinc-400">
        No task chain ID provided.
      </div>
    );
  }

  if (isLoading) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-zinc-400">
        Loading Task Chain overview...
      </div>
    );
  }

  if (error || !chain) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-red-400">
        Failed to load Task Chain details.
      </div>
    );
  }

  return (
    <div
      data-debug-id="taskchain-overview"
      className="flex h-full w-full flex-col overflow-y-auto bg-[#090909] text-white"
    >
      {/* Mobile Back Header (Requirement 10) */}
      {isMobile && onClose && (
        <div
          data-debug-id="taskchain-overview-back-btn-container"
          className="sticky top-0 z-30 flex items-center justify-between border-b border-white/10 bg-[#0c0c0c] px-4 py-3 sm:hidden"
        >
          <button
            type="button"
            data-debug-id="taskchain-overview-back-btn"
            onClick={onClose}
            className="flex items-center gap-2 text-sm font-semibold text-sky-400 hover:text-sky-300"
          >
            ← Back to Chat
          </button>
          <span className="text-xs font-bold uppercase tracking-wider text-zinc-400">Task Chain</span>
        </div>
      )}

      {/* Header Info */}
      <div className="border-b border-white/10 p-4 sm:p-6">
        <div className="flex items-center justify-between">
          <h2
            data-debug-id="taskchain-overview-title"
            className="text-lg font-bold text-white sm:text-xl"
          >
            {chain.title || 'Untitled Chain'}
          </h2>
          <span
            data-debug-id="taskchain-overview-status"
            className={`rounded-full px-3 py-1 text-xs font-semibold uppercase tracking-wider ${
              chain.status === 'completed'
                ? 'bg-emerald-500/20 text-emerald-400'
                : chain.status === 'cancelled'
                ? 'bg-red-500/20 text-red-400'
                : 'bg-sky-500/20 text-sky-400'
            }`}
          >
            {chain.status}
          </span>
        </div>

        {/* Collapsible Description */}
        {chain.description && (
          <div className="mt-2">
            <button
              type="button"
              data-debug-id="taskchain-overview-description-toggle-btn"
              onClick={() => setDescExpanded(!descExpanded)}
              className="flex items-center gap-1 text-xs font-semibold text-zinc-400 hover:text-zinc-200"
            >
              <span>{descExpanded ? '▾' : '▸'}</span> description
            </button>
            {descExpanded && (
              <div
                data-debug-id="taskchain-overview-description"
                className="mt-1 text-sm text-zinc-300"
              >
                <Markdown source={chain.description} compact copyAll={false} />
              </div>
            )}
          </div>
        )}

        {/* Progress Summary Pill Counters */}
        <div
          data-debug-id="taskchain-overview-progress"
          className="mt-4 flex flex-wrap gap-2 text-xs"
        >
          <span
            data-debug-id="taskchain-overview-progress-todo"
            className="rounded bg-zinc-800 px-2 py-1 text-zinc-300"
          >
            todo {progressBuckets.todo}
          </span>
          <span
            data-debug-id="taskchain-overview-progress-in_progress"
            className="rounded bg-sky-900/50 px-2 py-1 text-sky-300"
          >
            doing {progressBuckets.in_progress}
          </span>
          <span
            data-debug-id="taskchain-overview-progress-in_validation"
            className="rounded bg-purple-900/50 px-2 py-1 text-purple-300"
          >
            review {progressBuckets.in_validation}
          </span>
          <span
            data-debug-id="taskchain-overview-progress-validated_good"
            className="rounded bg-emerald-900/50 px-2 py-1 text-emerald-300"
          >
            done {progressBuckets.validated_good}
          </span>
          {progressBuckets.blocked > 0 && (
            <span
              data-debug-id="taskchain-overview-progress-blocked"
              className="rounded bg-amber-900/50 px-2 py-1 text-amber-300"
            >
              blocked {progressBuckets.blocked}
            </span>
          )}
        </div>

        {/* Members Strip */}
        <div
          data-debug-id="taskchain-overview-members"
          className="mt-4 flex flex-wrap items-center gap-3 border-t border-white/5 pt-3 text-xs"
        >
          <span className="font-semibold text-zinc-400">Members:</span>
          {members.map((m: any) => (
            <div
              key={m.agentInstanceId || m.agent_instance_id}
              data-debug-id={`taskchain-overview-member-${m.agentInstanceId || m.agent_instance_id}`}
              className="flex items-center gap-1 rounded bg-zinc-800 px-2 py-0.5"
            >
              <span className="h-1.5 w-1.5 rounded-full bg-emerald-400"></span>
              <span className="font-mono text-zinc-300">
                {m.role}: <InstanceIdLink instanceId={m.agentInstanceId || m.agent_instance_id} />
              </span>
              <button
                type="button"
                data-debug-id={`taskchain-overview-member-remove-btn-${m.agentInstanceId || m.agent_instance_id}`}
                onClick={() => handleRemoveMember(m.agentInstanceId || m.agent_instance_id)}
                className="ml-1 text-zinc-500 hover:text-red-400"
                title="Remove member"
              >
                ×
              </button>
            </div>
          ))}
          <button
            type="button"
            data-debug-id="taskchain-overview-add-member-btn"
            onClick={() => setShowAddMemberModal(true)}
            className="rounded bg-white/10 px-2 py-0.5 font-semibold text-zinc-300 hover:bg-white/20"
          >
            + Add member
          </button>
        </div>
      </div>

      {/* Task List Header */}
      <div className="flex items-center justify-between px-4 py-3 sm:px-6">
        <h3 className="text-sm font-bold uppercase tracking-wider text-zinc-400">
          Tasks ({tasks.length})
        </h3>
        <button
          type="button"
          data-debug-id="taskchain-new-task-btn"
          onClick={() => setShowNewTaskModal(true)}
          className="rounded bg-sky-600 px-3 py-1 text-xs font-semibold text-white hover:bg-sky-500"
        >
          + New task
        </button>
      </div>

      {/* Tasks List */}
      <div className="flex-1 space-y-3 px-4 pb-6 sm:px-6">
        {tasks.length === 0 ? (
          <div className="rounded-lg border border-dashed border-white/10 p-6 text-center text-xs text-zinc-500">
            No tasks in this chain yet. Click "+ New task" to get started.
          </div>
        ) : (
          <>
            {/* Active Tasks */}
            {activeTasks.length === 0 && completedTasks.length > 0 ? (
              <div className="rounded-lg border border-dashed border-white/10 p-4 text-center text-xs text-zinc-500">
                All tasks in this chain are completed.
              </div>
            ) : (
              activeTasks.map((task: any) => renderTaskCard(task))
            )}

            {/* Collapsible Completed Tasks Section */}
            {completedTasks.length > 0 && (
              <div
                data-debug-id="taskchain-overview-completed-section"
                className="mt-6 border-t border-white/10 pt-4"
              >
                <button
                  type="button"
                  data-debug-id="taskchain-overview-completed-toggle-btn"
                  onClick={() => setCompletedTasksExpanded(!completedTasksExpanded)}
                  className="flex w-full items-center justify-between rounded-lg bg-[#111111] px-3 py-2 text-xs font-semibold text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200"
                >
                  <div className="flex items-center gap-2">
                    <span>{completedTasksExpanded ? '▾' : '▸'}</span>
                    <span>Completed Tasks</span>
                    <span
                      data-debug-id="taskchain-overview-completed-count"
                      className="rounded bg-emerald-900/40 px-1.5 py-0.5 text-[10px] text-emerald-400"
                    >
                      {completedTasks.length}
                    </span>
                  </div>
                  <span className="text-[11px] font-normal text-zinc-500">
                    {completedTasksExpanded ? 'Click to collapse' : 'Click to expand'}
                  </span>
                </button>

                {completedTasksExpanded && (
                  <div
                    data-debug-id="taskchain-overview-completed-list"
                    className="mt-3 space-y-3"
                  >
                    {completedTasks.map((task: any) => renderTaskCard(task))}
                  </div>
                )}
              </div>
            )}
            
            {/* Collapsible Cancelled Tasks Section */}
            {cancelledTasks.length > 0 && (
              <div
                data-debug-id="taskchain-overview-cancelled-section"
                className="mt-6 border-t border-white/10 pt-4"
              >
                <button
                  type="button"
                  data-debug-id="taskchain-overview-cancelled-toggle-btn"
                  onClick={() => setCancelledTasksExpanded(!cancelledTasksExpanded)}
                  className="flex w-full items-center justify-between rounded-lg bg-[#111111] px-3 py-2 text-xs font-semibold text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200"
                >
                  <div className="flex items-center gap-2">
                    <span>{cancelledTasksExpanded ? '▾' : '▸'}</span>
                    <span>Cancelled Tasks</span>
                    <span
                      data-debug-id="taskchain-overview-cancelled-count"
                      className="rounded bg-zinc-800 px-1.5 py-0.5 text-[10px] text-zinc-400"
                    >
                      {cancelledTasks.length}
                    </span>
                  </div>
                  <span className="text-[11px] font-normal text-zinc-500">
                    {cancelledTasksExpanded ? 'Click to collapse' : 'Click to expand'}
                  </span>
                </button>

                {cancelledTasksExpanded && (
                  <div
                    data-debug-id="taskchain-overview-cancelled-list"
                    className="mt-3 space-y-3"
                  >
                    {cancelledTasks.map((task: any) => renderTaskCard(task))}
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>

      {/* Reconcile (self-heal) — below the task chain. Coordinator/owner only;
          promotes actionable tasks, sets current-tasks, nudges idle agents. */}
      <div
        data-debug-id="taskchain-overview-reconcile-bar"
        className="flex items-center justify-between gap-3 border-t border-white/10 px-4 py-3 sm:px-6"
      >
        <div className="min-w-0 text-[11px] text-zinc-500">
          {reconcileMsg ? (
            <span data-debug-id="taskchain-overview-reconcile-status">{reconcileMsg}</span>
          ) : (
            <span>Self-heal: re-plan the chain (promote tasks, set current-tasks, nudge idle agents).</span>
          )}
        </div>
        <button
          type="button"
          data-debug-id="taskchain-overview-reconcile-btn"
          disabled={reconcileState.isLoading || !chainId}
          onClick={async () => {
            setReconcileMsg('');
            try {
              const res: any = await reconcileChain({ chainId }).unwrap();
              const promoted = Number(res?.promoted ?? res?.data?.promoted ?? 0);
              setReconcileMsg(`Reconciled — ${promoted} task${promoted === 1 ? '' : 's'} promoted.`);
              refetch();
            } catch (e: any) {
              setReconcileMsg(String(e?.error || e?.message || 'Reconcile failed'));
            }
          }}
          className="shrink-0 rounded bg-amber-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-amber-500 disabled:opacity-50"
        >
          {reconcileState.isLoading ? 'Reconciling…' : '↻ Reconcile chain'}
        </button>
      </div>

      {/* New Task Modal */}
      {showNewTaskModal && (
        <div
          data-debug-id="taskchain-new-task-modal"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
        >
          <form
            onSubmit={handleCreateTask}
            className="w-full max-w-lg max-h-[90vh] overflow-y-auto rounded-lg border border-white/10 bg-[#141414] p-5 text-xs text-white"
          >
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-bold text-white">Create New Task</h3>
              <button
                type="button"
                onClick={() => { resetNewTaskForm(); setShowNewTaskModal(false); }}
                className="text-zinc-400 hover:text-white"
              >
                ✕
              </button>
            </div>

            <div className="mt-4 space-y-4">
              <div>
                <label className="block text-zinc-400">Title</label>
                <input
                  type="text"
                  data-debug-id="taskchain-new-task-title-input"
                  required
                  value={newTaskTitle}
                  onChange={(e) => setNewTaskTitle(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white placeholder-zinc-500 focus:outline-none focus:border-sky-500"
                  placeholder="Task title..."
                />
              </div>

              <div>
                <label className="block text-zinc-400">Description</label>
                <textarea
                  data-debug-id="taskchain-new-task-desc-input"
                  value={newTaskDesc}
                  onChange={(e) => setNewTaskDesc(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white placeholder-zinc-500 focus:outline-none focus:border-sky-500"
                  placeholder="Task description (optional)..."
                  rows={2}
                />
              </div>

              {/* Assignee Section */}
              <div className="rounded border border-white/10 bg-white/[0.02] p-3">
                <label className="block font-semibold text-zinc-300 mb-2">Initial Assignee</label>
                <div data-debug-id="taskchain-new-task-assignee-mode" className="flex gap-1 rounded bg-zinc-900 p-1 mb-3">
                  <button
                    type="button"
                    data-debug-id="taskchain-new-task-assignee-mode-unassigned"
                    onClick={() => setNewTaskAssigneeMode('unassigned')}
                    className={`rounded px-2 py-1 font-semibold ${newTaskAssigneeMode === 'unassigned' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                  >
                    Unassigned
                  </button>
                  <button
                    type="button"
                    data-debug-id="taskchain-new-task-assignee-mode-member"
                    onClick={() => setNewTaskAssigneeMode('member')}
                    className={`rounded px-2 py-1 font-semibold ${newTaskAssigneeMode === 'member' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                  >
                    Chain member
                  </button>
                  <button
                    type="button"
                    data-debug-id="taskchain-new-task-assignee-mode-existing"
                    onClick={() => setNewTaskAssigneeMode('existing')}
                    className={`rounded px-2 py-1 font-semibold ${newTaskAssigneeMode === 'existing' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                  >
                    Other instance
                  </button>
                  <button
                    type="button"
                    data-debug-id="taskchain-new-task-assignee-mode-user"
                    onClick={() => setNewTaskAssigneeMode('user')}
                    className={`rounded px-2 py-1 font-semibold ${newTaskAssigneeMode === 'user' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                  >
                    User
                  </button>
                </div>

                {newTaskAssigneeMode === 'member' && (
                  <div>
                    <select
                      data-debug-id="taskchain-new-task-assignee-member-select"
                      value={newTaskAssigneeMemberInstanceId}
                      onChange={(e) => setNewTaskAssigneeMemberInstanceId(e.target.value)}
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                    >
                      <option value="">Select member…</option>
                      {members.map((m: any) => {
                        const id = String(m.agentInstanceId || m.agent_instance_id || '');
                        return <MemberInstanceOption key={id} value={id} role={m.role} instanceId={id} />;
                      })}
                    </select>
                    {members.length === 0 && (
                      <p className="mt-1 text-[11px] text-amber-300/80">No members in this task chain.</p>
                    )}
                  </div>
                )}

                {newTaskAssigneeMode === 'existing' && (
                  <div className="space-y-2">
                    <select
                      data-debug-id="taskchain-new-task-assignee-agentid-select"
                      value={newTaskAssigneeAgentId}
                      onChange={(e) => { setNewTaskAssigneeAgentId(e.target.value); setNewTaskAssigneeInstanceId(''); }}
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                    >
                      <option value="">Choose agent…</option>
                      {agentIdentities.map((a: any) => {
                        const id = String(a.agent_id || a.agentId || a.id || '');
                        return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                      })}
                    </select>
                    <select
                      data-debug-id="taskchain-new-task-assignee-existing-instance-select"
                      value={newTaskAssigneeInstanceId}
                      onChange={(e) => setNewTaskAssigneeInstanceId(e.target.value)}
                      disabled={!newTaskAssigneeAgentId || newTaskAssigneeInstancesQuery.isFetching}
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                    >
                      <option value="">{!newTaskAssigneeAgentId ? 'Choose an agent first…' : newTaskAssigneeInstancesQuery.isFetching ? 'Loading instances…' : 'Choose an instance…'}</option>
                      {newTaskAssigneeExistingInstances.map((inst: any) => {
                        const iid = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
                        return (
                          <AgentInstanceOption
                            key={iid}
                            value={iid}
                            instanceId={iid}
                            defaultAgentName={selectedNewTaskAssigneeAgent?.name || selectedNewTaskAssigneeAgent?.display_name || selectedNewTaskAssigneeAgent?.agent_id}
                            runtimeStatus={inst.runtime_status}
                          />
                        );
                      })}
                    </select>
                  </div>
                )}

                {newTaskAssigneeMode === 'user' && (
                  <div>
                    <input
                      data-debug-id="taskchain-new-task-assignee-userid-input"
                      type="text"
                      value={newTaskAssigneeUserId}
                      onChange={(e) => setNewTaskAssigneeUserId(e.target.value)}
                      placeholder="e.g. user"
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                    />
                  </div>
                )}
              </div>

              {/* Reviewers Section */}
              <div className="rounded border border-white/10 bg-white/[0.02] p-3">
                <label className="block font-semibold text-zinc-300 mb-1">Reviewers ({newTaskStagedReviewerRefs.length})</label>
                {newTaskStagedReviewerRefs.length > 0 && (
                  <div data-debug-id="taskchain-new-task-reviewers-list" className="mb-2 flex flex-wrap gap-1.5 rounded border border-white/10 bg-zinc-900/50 p-2">
                    {newTaskStagedReviewerRefs.map((r, idx) => (
                      <span
                        key={r.agent_instance_id || r.user_id || idx}
                        data-debug-id={`taskchain-new-task-reviewer-chip-${idx}`}
                        className="inline-flex items-center gap-1.5 rounded bg-zinc-800 px-2 py-1 text-xs text-zinc-200"
                      >
                        {r.agent_instance_id ? <InstanceIdLink instanceId={r.agent_instance_id} /> : <span>{r.user_id}</span>}
                        <button
                          type="button"
                          data-debug-id={`taskchain-new-task-reviewer-remove-btn-${idx}`}
                          onClick={() => handleRemoveNewTaskStagedReviewer(idx)}
                          className="text-zinc-400 hover:text-red-400"
                          title="Remove reviewer"
                        >
                          ×
                        </button>
                      </span>
                    ))}
                  </div>
                )}

                <div className="mt-2 border-t border-white/10 pt-2 space-y-2">
                  <span className="text-[11px] text-zinc-400">Add a reviewer:</span>
                  <div data-debug-id="taskchain-new-task-add-reviewer-mode" className="flex gap-1 rounded bg-zinc-900 p-1">
                    <button
                      type="button"
                      data-debug-id="taskchain-new-task-add-reviewer-mode-member"
                      onClick={() => setNewTaskAddReviewerMode('member')}
                      className={`rounded px-2 py-1 font-semibold ${newTaskAddReviewerMode === 'member' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                    >
                      Member
                    </button>
                    <button
                      type="button"
                      data-debug-id="taskchain-new-task-add-reviewer-mode-existing"
                      onClick={() => setNewTaskAddReviewerMode('existing')}
                      className={`rounded px-2 py-1 font-semibold ${newTaskAddReviewerMode === 'existing' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                    >
                      Other
                    </button>
                    <button
                      type="button"
                      data-debug-id="taskchain-new-task-add-reviewer-mode-user"
                      onClick={() => setNewTaskAddReviewerMode('user')}
                      className={`rounded px-2 py-1 font-semibold ${newTaskAddReviewerMode === 'user' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                    >
                      User
                    </button>
                  </div>

                  {newTaskAddReviewerMode === 'member' && (
                    <div>
                      <select
                        data-debug-id="taskchain-new-task-add-reviewer-member-select"
                        value={newTaskAddReviewerMemberInstanceId}
                        onChange={(e) => setNewTaskAddReviewerMemberInstanceId(e.target.value)}
                        className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                      >
                        <option value="">Select member…</option>
                        {members.map((m: any) => {
                          const id = String(m.agentInstanceId || m.agent_instance_id || '');
                          return <MemberInstanceOption key={id} value={id} role={m.role} instanceId={id} />;
                        })}
                      </select>
                    </div>
                  )}

                  {newTaskAddReviewerMode === 'existing' && (
                    <div className="space-y-2">
                      <select
                        data-debug-id="taskchain-new-task-add-reviewer-agentid-select"
                        value={newTaskAddReviewerAgentId}
                        onChange={(e) => { setNewTaskAddReviewerAgentId(e.target.value); setNewTaskAddReviewerInstanceId(''); }}
                        className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                      >
                        <option value="">Choose agent…</option>
                        {agentIdentities.map((a: any) => {
                          const id = String(a.agent_id || a.agentId || a.id || '');
                          return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                        })}
                      </select>
                      <select
                        data-debug-id="taskchain-new-task-add-reviewer-existing-instance-select"
                        value={newTaskAddReviewerInstanceId}
                        onChange={(e) => setNewTaskAddReviewerInstanceId(e.target.value)}
                        disabled={!newTaskAddReviewerAgentId || newTaskReviewerInstancesQuery.isFetching}
                        className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                      >
                        <option value="">{!newTaskAddReviewerAgentId ? 'Choose an agent first…' : newTaskReviewerInstancesQuery.isFetching ? 'Loading instances…' : 'Choose an instance…'}</option>
                        {newTaskReviewerExistingInstances.map((inst: any) => {
                          const iid = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
                          return (
                            <AgentInstanceOption
                              key={iid}
                              value={iid}
                              instanceId={iid}
                              defaultAgentName={selectedNewTaskReviewerAgent?.name || selectedNewTaskReviewerAgent?.display_name || selectedNewTaskReviewerAgent?.agent_id}
                              runtimeStatus={inst.runtime_status}
                            />
                          );
                        })}
                      </select>
                    </div>
                  )}

                  {newTaskAddReviewerMode === 'user' && (
                    <div>
                      <input
                        data-debug-id="taskchain-new-task-add-reviewer-userid-input"
                        type="text"
                        value={newTaskAddReviewerUserId}
                        onChange={(e) => setNewTaskAddReviewerUserId(e.target.value)}
                        placeholder="e.g. user"
                        className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                      />
                    </div>
                  )}

                  <div className="flex justify-end">
                    <button
                      type="button"
                      data-debug-id="taskchain-new-task-add-reviewer-btn"
                      onClick={handleAddNewTaskStagedReviewer}
                      className="rounded bg-zinc-800 px-3 py-1 font-semibold text-sky-400 hover:bg-zinc-700"
                    >
                      + Add reviewer
                    </button>
                  </div>
                </div>
              </div>

              {/* Blocked-On (Depends-On) Section */}
              <div className="rounded border border-white/10 bg-white/[0.02] p-3">
                <label className="block font-semibold text-zinc-300 mb-1">
                  Blocked On (Depends On) {newTaskDependsOnIds.length > 0 && `(${newTaskDependsOnIds.length})`}
                </label>
                <p className="text-[11px] text-zinc-500 mb-2">Select existing tasks that must complete before this task can begin.</p>
                {tasks.length === 0 ? (
                  <p className="text-[11px] text-zinc-500 italic">No existing tasks in this chain yet.</p>
                ) : (
                  <div
                    data-debug-id="taskchain-new-task-depends-on-list"
                    className="max-h-40 overflow-y-auto space-y-1.5 rounded border border-white/10 bg-zinc-900/50 p-2"
                  >
                    {tasks.map((t: any) => {
                      const tid = String(t.taskId || t.id);
                      const isSelected = newTaskDependsOnIds.includes(tid);
                      return (
                        <label
                          key={tid}
                          data-debug-id={`taskchain-new-task-depends-on-option-${tid}`}
                          className={`flex items-center gap-2 rounded px-2 py-1.5 cursor-pointer text-xs select-none transition-colors ${
                            isSelected ? 'bg-sky-950/60 border border-sky-500/30 text-white' : 'hover:bg-white/5 text-zinc-300'
                          }`}
                        >
                          <input
                            type="checkbox"
                            checked={isSelected}
                            onChange={(e) => {
                              if (e.target.checked) {
                                setNewTaskDependsOnIds((prev) => [...prev, tid]);
                              } else {
                                setNewTaskDependsOnIds((prev) => prev.filter((id) => id !== tid));
                              }
                            }}
                            className="rounded border-zinc-700 bg-zinc-900 text-sky-500 focus:ring-0 focus:ring-offset-0"
                          />
                          <span className="font-mono text-zinc-400 text-[11px]">{tid}</span>
                          <span className="truncate flex-1 font-medium">{t.title}</span>
                          <span className="text-[10px] text-zinc-500 uppercase">{t.status}</span>
                        </label>
                      );
                    })}
                  </div>
                )}
              </div>

              {newTaskError && (
                <p data-debug-id="taskchain-new-task-error" className="text-[11px] text-red-300">{newTaskError}</p>
              )}
            </div>

            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => { resetNewTaskForm(); setShowNewTaskModal(false); }}
                className="rounded bg-zinc-800 px-3 py-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-debug-id="taskchain-new-task-submit-btn"
                disabled={creatingTask}
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500 disabled:opacity-50"
              >
                {creatingTask ? 'Creating…' : 'Create Task'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Add Agent to Chain popup: launch a new instance (identity + bridge +
          provider + tier) and add it to this chain with the chosen role. */}
      {showAddMemberModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <form
            onSubmit={handleAddMember}
            className="w-full max-w-md rounded-lg border border-white/10 bg-[#141414] p-5 text-xs text-white"
          >
            <h3 className="text-sm font-bold text-white">Add Member to Task Chain</h3>
            <p className="mt-1 text-[11px] text-zinc-500">Add an existing agent instance to this chain, or launch a new one.</p>
            {/* H14: mode toggle — existing instance (reliable) vs launch new. */}
            <div data-debug-id="taskchain-add-member-mode" className="mt-3 inline-flex rounded border border-white/10 p-0.5 text-[11px]">
              <button
                type="button"
                data-debug-id="taskchain-add-member-mode-existing"
                onClick={() => { setAddMode('existing'); setAddAgentError(''); }}
                className={`rounded px-2 py-1 font-semibold ${addMode === 'existing' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
              >
                Add existing instance
              </button>
              <button
                type="button"
                data-debug-id="taskchain-add-member-mode-launch"
                onClick={() => { setAddMode('launch'); setAddAgentError(''); }}
                className={`rounded px-2 py-1 font-semibold ${addMode === 'launch' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
              >
                Launch new
              </button>
            </div>
            <div className="mt-4 space-y-3">
              <div>
                <label className="block text-zinc-400">Agent identity</label>
                <select
                  data-debug-id="taskchain-add-agent-agentid-select"
                  required
                  value={addAgentId}
                  onChange={(e) => { setAddAgentId(e.target.value); setAddExistingInstanceId(''); }}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                >
                  <option value="">Choose agent…</option>
                  {agentIdentities.map((a: any) => {
                    const id = String(a.agent_id || a.agentId || a.id || '');
                    return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                  })}
                </select>
              </div>
              {/* H14: existing-instance picker (only in 'existing' mode). */}
              {addMode === 'existing' && (
                <div>
                  <label className="block text-zinc-400">Existing instance</label>
                  <select
                    data-debug-id="taskchain-add-member-existing-instance-select"
                    value={addExistingInstanceId}
                    onChange={(e) => setAddExistingInstanceId(e.target.value)}
                    disabled={!addAgentId || existingInstancesQuery.isFetching}
                    className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                  >
                    <option value="">{!addAgentId ? 'Choose an agent first…' : existingInstancesQuery.isFetching ? 'Loading instances…' : 'Choose an instance…'}</option>
                    {existingInstances.map((inst: any) => {
                      const iid = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
                      const already = memberInstanceIds.has(iid);
                      return (
                        <AgentInstanceOption
                          key={iid}
                          value={iid}
                          instanceId={iid}
                          defaultAgentName={selectedAddAgent?.name || selectedAddAgent?.display_name || selectedAddAgent?.agent_id}
                          disabled={already}
                          suffix={already ? ' (already a member)' : ''}
                          runtimeStatus={inst.runtime_status}
                        />
                      );
                    })}
                  </select>
                  {addAgentId && !existingInstancesQuery.isFetching && existingInstances.length === 0 && (
                    <p className="mt-1 text-[11px] text-amber-300/80">No existing instances for this agent. Switch to “Launch new” to create one.</p>
                  )}
                </div>
              )}
              {addMode === 'launch' && (
              <>
              <div>
                <label className="block text-zinc-400">Bridge</label>
                <select
                  data-debug-id="taskchain-add-agent-bridge-select"
                  value={addBridgeId}
                  onChange={(e) => { setAddBridgeId(e.target.value); setAddProvider(''); setAddTier(''); }}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                >
                  <option value="">Choose bridge…</option>
                  {addBridgeRows.map((row) => <option key={row.bridgeId} value={row.bridgeId}>{bridgeLabel(row.bridge)}</option>)}
                </select>
                {addBridgeRows.length === 0 && <p className="mt-1 text-[11px] text-amber-300/80">No online bridge with provider capabilities is available.</p>}
              </div>
              <div>
                <label className="block text-zinc-400">Provider</label>
                <select
                  data-debug-id="taskchain-add-agent-provider-select"
                  value={addProvider}
                  onChange={(e) => { setAddProvider(e.target.value); setAddTier(''); }}
                  disabled={!selectedAddBridge}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                >
                  <option value="">Use bridge default provider</option>
                  {addProviderOptions.map((p) => <option key={p} value={p}>{p}</option>)}
                </select>
              </div>
              <div>
                <label className="block text-zinc-400">Tier</label>
                <select
                  data-debug-id="taskchain-add-agent-tier-select"
                  value={addTier}
                  onChange={(e) => setAddTier(e.target.value)}
                  disabled={!selectedAddBridge}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                >
                  <option value="">Use bridge default tier</option>
                  {addTierOptions.map((tier) => <option key={tier} value={tier}>{tier}</option>)}
                </select>
              </div>
              </>
              )}
              <div>
                <label className="block text-zinc-400">Role</label>
                <select
                  data-debug-id="taskchain-add-agent-role-select"
                  value={newMemberRole}
                  onChange={(e) => setNewMemberRole(e.target.value)}
                  className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                >
                  <option value="worker">worker</option>
                  <option value="reviewer">reviewer</option>
                  <option value="coordinator">coordinator</option>
                </select>
              </div>
              {addAgentError && <p data-debug-id="taskchain-add-agent-error" className="text-[11px] text-red-300">{addAgentError}</p>}
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setShowAddMemberModal(false)}
                className="rounded bg-zinc-800 px-3 py-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-add-agent-submit"
                type="submit"
                disabled={addMode === 'existing'
                  ? (addingExisting || !addExistingInstanceId)
                  : (addingAgent || !addAgentId)}
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500 disabled:opacity-50"
              >
                {addMode === 'existing'
                  ? (addingExisting ? 'Adding…' : 'Add member')
                  : (addingAgent ? 'Launching…' : 'Launch & Add')}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Edit Assignee Modal */}
      {editingAssigneeTask && (
        <div
          data-debug-id="taskchain-edit-assignee-modal"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
        >
          <form
            onSubmit={handleSaveAssignee}
            data-debug-id="taskchain-edit-assignee-form"
            className="w-full max-w-md rounded-xl border border-white/10 bg-[#121212] p-5 shadow-2xl"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-white">Change Assignee</h3>
              <button
                type="button"
                onClick={() => setEditingAssigneeTask(null)}
                className="text-zinc-500 hover:text-white"
              >
                ✕
              </button>
            </div>
            <p className="mt-1 text-xs text-zinc-400">
              Task: <span className="text-zinc-200">{editingAssigneeTask.title}</span>
            </p>

            <div className="mt-3 flex gap-2 border-b border-white/10 pb-2 text-xs">
              <button
                type="button"
                data-debug-id="taskchain-edit-assignee-mode-member"
                onClick={() => setEditAssigneeMode('member')}
                className={`rounded px-2 py-1 font-semibold ${editAssigneeMode === 'member' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
              >
                Chain member
              </button>
              <button
                type="button"
                data-debug-id="taskchain-edit-assignee-mode-existing"
                onClick={() => setEditAssigneeMode('existing')}
                className={`rounded px-2 py-1 font-semibold ${editAssigneeMode === 'existing' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
              >
                Other instance
              </button>
              <button
                type="button"
                data-debug-id="taskchain-edit-assignee-mode-user"
                onClick={() => setEditAssigneeMode('user')}
                className={`rounded px-2 py-1 font-semibold ${editAssigneeMode === 'user' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
              >
                User
              </button>
              <button
                type="button"
                data-debug-id="taskchain-edit-assignee-mode-unassigned"
                onClick={() => setEditAssigneeMode('unassigned')}
                className={`rounded px-2 py-1 font-semibold ${editAssigneeMode === 'unassigned' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
              >
                Unassigned
              </button>
            </div>

            <div className="mt-4 space-y-3 text-xs">
              {editAssigneeMode === 'member' && (
                <div>
                  <label className="block text-zinc-400">Choose chain member</label>
                  <select
                    data-debug-id="taskchain-edit-assignee-member-select"
                    value={editAssigneeMemberInstanceId}
                    onChange={(e) => setEditAssigneeMemberInstanceId(e.target.value)}
                    className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                  >
                    <option value="">Select member…</option>
                    {members.map((m: any) => {
                      const id = String(m.agentInstanceId || m.agent_instance_id || '');
                      return <MemberInstanceOption key={id} value={id} role={m.role} instanceId={id} />;
                    })}
                  </select>
                  {members.length === 0 && (
                    <p className="mt-1 text-[11px] text-amber-300/80">No members in this task chain.</p>
                  )}
                </div>
              )}

              {editAssigneeMode === 'existing' && (
                <>
                  <div>
                    <label className="block text-zinc-400">Agent identity</label>
                    <select
                      data-debug-id="taskchain-edit-assignee-agentid-select"
                      value={editAssigneeAgentId}
                      onChange={(e) => { setEditAssigneeAgentId(e.target.value); setEditAssigneeInstanceId(''); }}
                      className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                    >
                      <option value="">Choose agent…</option>
                      {agentIdentities.map((a: any) => {
                        const id = String(a.agent_id || a.agentId || a.id || '');
                        return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                      })}
                    </select>
                  </div>
                  <div>
                    <label className="block text-zinc-400">Existing instance</label>
                    <select
                      data-debug-id="taskchain-edit-assignee-existing-instance-select"
                      value={editAssigneeInstanceId}
                      onChange={(e) => setEditAssigneeInstanceId(e.target.value)}
                      disabled={!editAssigneeAgentId || assigneeInstancesQuery.isFetching}
                      className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                    >
                      <option value="">{!editAssigneeAgentId ? 'Choose an agent first…' : assigneeInstancesQuery.isFetching ? 'Loading instances…' : 'Choose an instance…'}</option>
                      {assigneeExistingInstances.map((inst: any) => {
                        const iid = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
                        return (
                          <AgentInstanceOption
                            key={iid}
                            value={iid}
                            instanceId={iid}
                            defaultAgentName={selectedAssigneeAgent?.name || selectedAssigneeAgent?.display_name || selectedAssigneeAgent?.agent_id}
                            runtimeStatus={inst.runtime_status}
                          />
                        );
                      })}
                    </select>
                  </div>
                </>
              )}

              {editAssigneeMode === 'user' && (
                <div>
                  <label className="block text-zinc-400">User ID</label>
                  <input
                    data-debug-id="taskchain-edit-assignee-userid-input"
                    type="text"
                    value={editAssigneeUserId}
                    onChange={(e) => setEditAssigneeUserId(e.target.value)}
                    placeholder="e.g. user"
                    className="mt-1 w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                  />
                </div>
              )}

              {editAssigneeMode === 'unassigned' && (
                <p className="text-zinc-400">The task will have no assignee.</p>
              )}

              {assigneeError && <p data-debug-id="taskchain-edit-assignee-error" className="text-[11px] text-red-300">{assigneeError}</p>}
            </div>

            <div className="mt-5 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setEditingAssigneeTask(null)}
                className="rounded bg-zinc-800 px-3 py-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-edit-assignee-submit"
                type="submit"
                disabled={savingAssignee}
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500 disabled:opacity-50"
              >
                {savingAssignee ? 'Saving…' : 'Save Assignee'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Edit Reviewers Modal */}
      {editingReviewersTask && (
        <div
          data-debug-id="taskchain-edit-reviewers-modal"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
        >
          <form
            onSubmit={handleSaveReviewers}
            data-debug-id="taskchain-edit-reviewers-form"
            className="w-full max-w-lg rounded-xl border border-white/10 bg-[#121212] p-5 shadow-2xl"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-white">Edit Reviewers</h3>
              <button
                type="button"
                onClick={() => setEditingReviewersTask(null)}
                className="text-zinc-500 hover:text-white"
              >
                ✕
              </button>
            </div>
            <p className="mt-1 text-xs text-zinc-400">
              Task: <span className="text-zinc-200">{editingReviewersTask.title}</span>
            </p>

            {/* Current Reviewers List */}
            <div className="mt-3">
              <label className="block text-xs font-semibold text-zinc-400">Current Reviewers ({stagedReviewerRefs.length})</label>
              <div data-debug-id="taskchain-edit-reviewers-list" className="mt-1.5 flex flex-wrap gap-2 min-h-[36px] rounded border border-white/10 bg-zinc-900/50 p-2">
                {stagedReviewerRefs.map((r: any, idx: number) => (
                  <span
                    key={r.agent_instance_id || r.user_id || idx}
                    data-debug-id={`taskchain-edit-reviewer-chip-${idx}`}
                    className="inline-flex items-center gap-1.5 rounded bg-zinc-800 px-2 py-1 text-xs text-zinc-200"
                  >
                    {r.agent_instance_id ? <InstanceIdLink instanceId={r.agent_instance_id} /> : <span>{r.user_id}</span>}
                    <button
                      type="button"
                      data-debug-id={`taskchain-edit-reviewer-remove-btn-${idx}`}
                      onClick={() => handleRemoveStagedReviewer(idx)}
                      className="text-zinc-400 hover:text-red-400"
                      title="Remove reviewer"
                    >
                      ×
                    </button>
                  </span>
                ))}
                {stagedReviewerRefs.length === 0 && (
                  <span className="text-xs text-zinc-500">No reviewers selected</span>
                )}
              </div>
            </div>

            {/* Add Reviewer Section */}
            <div className="mt-4 rounded border border-white/10 bg-white/[0.02] p-3 text-xs">
              <span className="font-semibold text-zinc-300">Add Reviewer</span>
              <div className="mt-2 flex gap-2 border-b border-white/10 pb-2">
                <button
                  type="button"
                  data-debug-id="taskchain-add-reviewer-mode-member"
                  onClick={() => setAddReviewerMode('member')}
                  className={`rounded px-2 py-1 font-semibold ${addReviewerMode === 'member' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                >
                  Chain member
                </button>
                <button
                  type="button"
                  data-debug-id="taskchain-add-reviewer-mode-existing"
                  onClick={() => setAddReviewerMode('existing')}
                  className={`rounded px-2 py-1 font-semibold ${addReviewerMode === 'existing' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                >
                  Other instance
                </button>
                <button
                  type="button"
                  data-debug-id="taskchain-add-reviewer-mode-user"
                  onClick={() => setAddReviewerMode('user')}
                  className={`rounded px-2 py-1 font-semibold ${addReviewerMode === 'user' ? 'bg-sky-600 text-white' : 'text-zinc-400 hover:text-white'}`}
                >
                  User
                </button>
              </div>

              <div className="mt-3 space-y-2">
                {addReviewerMode === 'member' && (
                  <div>
                    <select
                      data-debug-id="taskchain-add-reviewer-member-select"
                      value={addReviewerMemberInstanceId}
                      onChange={(e) => setAddReviewerMemberInstanceId(e.target.value)}
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                    >
                      <option value="">Select member…</option>
                      {members.map((m: any) => {
                        const id = String(m.agentInstanceId || m.agent_instance_id || '');
                        return <MemberInstanceOption key={id} value={id} role={m.role} instanceId={id} />;
                      })}
                    </select>
                  </div>
                )}

                {addReviewerMode === 'existing' && (
                  <div className="space-y-2">
                    <select
                      data-debug-id="taskchain-add-reviewer-agentid-select"
                      value={addReviewerAgentId}
                      onChange={(e) => { setAddReviewerAgentId(e.target.value); setAddReviewerInstanceId(''); }}
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                    >
                      <option value="">Choose agent…</option>
                      {agentIdentities.map((a: any) => {
                        const id = String(a.agent_id || a.agentId || a.id || '');
                        return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                      })}
                    </select>
                    <select
                      data-debug-id="taskchain-add-reviewer-existing-instance-select"
                      value={addReviewerInstanceId}
                      onChange={(e) => setAddReviewerInstanceId(e.target.value)}
                      disabled={!addReviewerAgentId || reviewerInstancesQuery.isFetching}
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500 disabled:opacity-50"
                    >
                      <option value="">{!addReviewerAgentId ? 'Choose an agent first…' : reviewerInstancesQuery.isFetching ? 'Loading instances…' : 'Choose an instance…'}</option>
                      {reviewerExistingInstances.map((inst: any) => {
                        const iid = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
                        return (
                          <AgentInstanceOption
                            key={iid}
                            value={iid}
                            instanceId={iid}
                            defaultAgentName={selectedReviewerAgent?.name || selectedReviewerAgent?.display_name || selectedReviewerAgent?.agent_id}
                            runtimeStatus={inst.runtime_status}
                          />
                        );
                      })}
                    </select>
                  </div>
                )}

                {addReviewerMode === 'user' && (
                  <div>
                    <input
                      data-debug-id="taskchain-add-reviewer-userid-input"
                      type="text"
                      value={addReviewerUserId}
                      onChange={(e) => setAddReviewerUserId(e.target.value)}
                      placeholder="e.g. user"
                      className="w-full rounded border border-white/10 bg-zinc-900 p-2 text-white focus:outline-none focus:border-sky-500"
                    />
                  </div>
                )}

                <div className="flex justify-end">
                  <button
                    type="button"
                    data-debug-id="taskchain-add-reviewer-btn"
                    onClick={handleAddStagedReviewer}
                    className="rounded bg-zinc-800 px-3 py-1 font-semibold text-sky-400 hover:bg-zinc-700"
                  >
                    + Add to list
                  </button>
                </div>
              </div>
            </div>

            {reviewersError && <p data-debug-id="taskchain-edit-reviewers-error" className="mt-2 text-[11px] text-red-300">{reviewersError}</p>}

            <div className="mt-5 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setEditingReviewersTask(null)}
                className="rounded bg-zinc-800 px-3 py-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-edit-reviewers-submit"
                type="submit"
                disabled={savingReviewers}
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500 disabled:opacity-50"
              >
                {savingReviewers ? 'Saving…' : 'Save Reviewers'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Edit Dependencies Modal */}
      {editingDependenciesTask && (
        <div
          data-debug-id="taskchain-edit-dependencies-modal"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
        >
          <form
            onSubmit={handleSaveDependencies}
            data-debug-id="taskchain-edit-dependencies-form"
            className="w-full max-w-md rounded-xl border border-white/10 bg-[#121212] p-5 shadow-2xl"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-white">Manage Dependencies</h3>
              <button
                type="button"
                onClick={() => setEditingDependenciesTask(null)}
                className="text-zinc-500 hover:text-white"
              >
                ✕
              </button>
            </div>
            <p className="mt-1 text-xs text-zinc-400">
              Task: <span className="text-zinc-200">{editingDependenciesTask.title}</span>
            </p>

            <div className="mt-4">
              <label className="block text-xs font-semibold text-zinc-400">
                Blocked On (Depends On) {stagedDependsOnIds.length > 0 && `(${stagedDependsOnIds.length})`}
              </label>
              <p className="mt-0.5 text-[11px] text-zinc-500">
                Select tasks that must be completed before this task can start.
              </p>

              {tasks.filter((t: any) => String(t.taskId || t.id) !== String(editingDependenciesTask.taskId || editingDependenciesTask.id)).length === 0 ? (
                <div className="mt-2 rounded border border-white/10 bg-zinc-900/50 p-3 text-center text-xs text-zinc-500 italic">
                  No other tasks in this chain.
                </div>
              ) : (
                <div
                  data-debug-id="taskchain-edit-dependencies-list"
                  className="mt-2 max-h-56 overflow-y-auto space-y-1.5 rounded border border-white/10 bg-zinc-900/50 p-2"
                >
                  {tasks
                    .filter((t: any) => String(t.taskId || t.id) !== String(editingDependenciesTask.taskId || editingDependenciesTask.id))
                    .map((t: any) => {
                      const tid = String(t.taskId || t.id);
                      const isSelected = stagedDependsOnIds.includes(tid);
                      return (
                        <label
                          key={tid}
                          data-debug-id={`taskchain-edit-dependency-option-${tid}`}
                          className={`flex items-center gap-2 rounded px-2 py-1.5 cursor-pointer text-xs select-none transition-colors ${
                            isSelected ? 'bg-sky-950/60 border border-sky-500/30 text-white' : 'hover:bg-white/5 text-zinc-300'
                          }`}
                        >
                          <input
                            type="checkbox"
                            checked={isSelected}
                            onChange={(e) => {
                              if (e.target.checked) {
                                setStagedDependsOnIds((prev) => [...prev, tid]);
                              } else {
                                setStagedDependsOnIds((prev) => prev.filter((id) => id !== tid));
                              }
                            }}
                            className="rounded border-zinc-700 bg-zinc-900 text-sky-500 focus:ring-0 focus:ring-offset-0"
                          />
                          <span className="font-mono text-zinc-400 text-[11px]">{tid}</span>
                          <span className="truncate flex-1 font-medium">{t.title}</span>
                          <span className="text-[10px] text-zinc-500 uppercase">{t.status}</span>
                        </label>
                      );
                    })}
                </div>
              )}
            </div>

            {dependenciesError && (
              <p data-debug-id="taskchain-edit-dependencies-error" className="mt-2 text-[11px] text-red-300">
                {dependenciesError}
              </p>
            )}

            <div className="mt-5 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setEditingDependenciesTask(null)}
                className="rounded bg-zinc-800 px-3 py-1.5 text-zinc-300 hover:bg-zinc-700"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-edit-dependencies-submit"
                type="submit"
                disabled={savingDependencies}
                className="rounded bg-sky-600 px-3 py-1.5 font-semibold text-white hover:bg-sky-500 disabled:opacity-50"
              >
                {savingDependencies ? 'Saving…' : 'Save Dependencies'}
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
};

// H10: shellHash builds the routed-shell hash link the dashboard uses for
// navigation (mirrors the helper in AgentDetailPanel).
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }

// H10: InstanceIdLink renders an agent instance id as a clickable control that
// opens that agent's chat. It resolves instance_id -> conversation_id via the
// agents API (GET /agent-instances/{id}) and links to shellHash(/conversations/
// <conversationId>). Graceful fallbacks: while resolving it links to the agent
// instance's chain-agnostic detail is unknown, so it links to /conversations only
// once resolved; if no conversation can be resolved it falls back to the agents
// list route and shows a tooltip — never a dead link and never a crash. user_id
// refs are NOT agent instances and must be rendered with plain text by callers.
export function InstanceIdLink({ instanceId }: { instanceId: string }) {
  const trimmed = String(instanceId || '').trim();
  // Only agent instance ids are clickable; guard against empty values.
  const { data } = useFetchAgentInstanceQuery({ instanceId: trimmed }, { skip: !trimmed });
  const inst = data?.instance || null;
  const conversationId = String(inst?.conversation_id || inst?.conversationId || '');
  const agentId = String(inst?.agent_id || inst?.agentId || '');

  const { data: agentData } = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const agentName = inst?.display_name || inst?.displayName || agentData?.agent?.name || agentData?.agent?.display_name || agentData?.agent?.agent_id || agentId || trimmed;

  if (!trimmed) return null;
  
  const href = conversationId
    ? shellHash(`/conversations/${conversationId}?agent_instance_id=${trimmed}`)
    : shellHash(`/agents`);
  const title = conversationId
    ? `Open chat with ${trimmed}`
    : `No conversation resolved for ${trimmed} — open agents`;
  return (
    <a
      data-debug-id={`taskchain-instance-link-${trimmed}`}
      href={href}
      title={title}
      className="font-mono text-sky-300 underline decoration-dotted underline-offset-2 hover:text-sky-200"
    >
      {agentName}
    </a>
  );
}

export default TaskChainOverview;
