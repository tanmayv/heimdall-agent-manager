import React, { useState } from "react";
import {
  useListMemoriesQuery,
  useCreateMemoryMutation,
  useUpdateMemoryMutation,
  useApproveMemoryMutation,
  useRejectMemoryMutation,
  useArchiveMemoryMutation,
} from "../../api/endpoints/memory";
import { MemoryScopeSelector, MemoryScopeValue, MEMORY_TYPES } from "./MemoryScopeSelector";

export const MemoryPanel: React.FC = () => {
  const [statusFilter, setStatusFilter] = useState<string>("all");
  const [typeFilter, setTypeFilter] = useState<string>("");
  const [scopeFilter, setScopeFilter] = useState<MemoryScopeValue>({});
  const [createOpen, setCreateOpen] = useState<boolean>(false);

  // Filters for memories query
  const queryArg = {
    status: statusFilter !== "all" ? statusFilter : undefined,
    type: typeFilter || undefined,
    agent_id: scopeFilter.agent_id,
    project_id: scopeFilter.project_id,
    bridge_id: scopeFilter.bridge_id,
    template_id: scopeFilter.template_id,
  };

  const { data: listData, isLoading, error: listError, refetch } = useListMemoriesQuery(queryArg);
  const memories: any[] = listData?.items || [];

  // Dedicated query for pending proposals
  const { data: pendingData } = useListMemoriesQuery({ status: "pending" });
  const pendingProposals: any[] = pendingData?.items || [];

  // Creation form state
  const [createTitle, setCreateTitle] = useState("");
  const [createBody, setCreateBody] = useState("");
  const [createEvidence, setCreateEvidence] = useState("");
  const [createScope, setCreateScope] = useState<MemoryScopeValue>({ type: "fact" });
  const [createError, setCreateError] = useState("");

  const [createMemory, { isLoading: isCreating }] = useCreateMemoryMutation();

  const handleCreateSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setCreateError("");
    if (!createTitle.trim() || !createBody.trim()) {
      setCreateError("Title and body are required.");
      return;
    }
    try {
      await createMemory({
        title: createTitle.trim(),
        body: createBody.trim(),
        evidence: createEvidence.trim() || undefined,
        type: createScope.type || "fact",
        agent_id: createScope.agent_id,
        project_id: createScope.project_id,
        bridge_id: createScope.bridge_id,
        template_id: createScope.template_id,
        status: "active",
      }).unwrap();
      setCreateTitle("");
      setCreateBody("");
      setCreateEvidence("");
      setCreateScope({ type: "fact" });
      setCreateOpen(false);
    } catch (err: any) {
      setCreateError(String(err?.data?.error || err?.message || err || "Failed to create memory"));
    }
  };

  return (
    <div data-debug-id="settings-memory-panel" id="settings-memory-panel" className="w-full max-w-5xl space-y-6 text-left">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-white/10 pb-4">
        <div>
          <h2 className="text-xl font-bold text-white">Memory Management</h2>
          <p className="text-xs text-zinc-400">
            Manage Hub memory records, proposals, durable scopes, and system memories.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            data-debug-id="memory-create-toggle-btn"
            id="memory-create-toggle-btn"
            onClick={() => setCreateOpen((prev) => !prev)}
            className="inline-flex items-center gap-1.5 rounded-xl bg-sky-500 px-4 py-2 text-xs font-bold text-black hover:bg-sky-400 transition"
          >
            {createOpen ? "Cancel" : "+ New Memory"}
          </button>
          <button
            type="button"
            data-debug-id="memory-refresh-btn"
            id="memory-refresh-btn"
            onClick={() => refetch()}
            className="rounded-xl border border-white/10 bg-white/5 px-3 py-2 text-xs font-semibold text-zinc-300 hover:bg-white/10 hover:text-white"
          >
            Refresh
          </button>
        </div>
      </div>

      {/* Collapsible Create Form */}
      {createOpen && (
        <form
          onSubmit={handleCreateSubmit}
          className="rounded-2xl border border-sky-500/30 bg-sky-950/20 p-5 space-y-4 shadow-lg"
        >
          <h3 className="text-sm font-bold text-sky-200">Create Memory Record</h3>
          {createError && (
            <div data-debug-id="memory-create-error" id="memory-create-error" className="rounded-xl border border-red-400/30 bg-red-500/10 p-3 text-xs text-red-200">
              {createError}
            </div>
          )}
          <div className="grid grid-cols-1 gap-3">
            <div>
              <label className="block text-xs font-medium text-zinc-300 mb-1">Title</label>
              <input
                type="text"
                data-debug-id="memory-create-title-input"
                id="memory-create-title-input"
                value={createTitle}
                onChange={(e) => setCreateTitle(e.target.value)}
                placeholder="Memory title..."
                className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-white p-2.5 focus:border-sky-500 focus:outline-none"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-300 mb-1">Body</label>
              <textarea
                rows={3}
                data-debug-id="memory-create-body-textarea"
                id="memory-create-body-textarea"
                value={createBody}
                onChange={(e) => setCreateBody(e.target.value)}
                placeholder="Memory details and content..."
                className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-white p-2.5 focus:border-sky-500 focus:outline-none"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-300 mb-1">Evidence (Optional)</label>
              <input
                type="text"
                data-debug-id="memory-create-evidence-input"
                id="memory-create-evidence-input"
                value={createEvidence}
                onChange={(e) => setCreateEvidence(e.target.value)}
                placeholder="Supporting URL, file path, or context reference..."
                className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-white p-2.5 focus:border-sky-500 focus:outline-none"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-zinc-300 mb-1">Scope & Targeting</label>
              <MemoryScopeSelector value={createScope} onChange={setCreateScope} />
            </div>
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              data-debug-id="memory-create-cancel-btn"
              id="memory-create-cancel-btn"
              onClick={() => setCreateOpen(false)}
              className="rounded-xl border border-white/10 bg-white/5 px-4 py-2 text-xs font-semibold text-zinc-300 hover:bg-white/10"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={isCreating}
              data-debug-id="memory-create-submit-btn"
              id="memory-create-submit-btn"
              className="rounded-xl bg-sky-500 px-5 py-2 text-xs font-bold text-black hover:bg-sky-400 disabled:opacity-50"
            >
              {isCreating ? "Saving..." : "Create Memory"}
            </button>
          </div>
        </form>
      )}

      {/* Proposals Review Section */}
      <div data-debug-id="memory-proposals-panel" id="memory-proposals-panel" className="space-y-4">
        <div className="flex items-center justify-between">
          <h3 className="text-base font-bold text-amber-300 flex items-center gap-2">
            <span>Pending Proposals</span>
            <span className="rounded-full bg-amber-400/20 text-amber-200 px-2 py-0.5 text-xs font-semibold">
              {pendingProposals.length}
            </span>
          </h3>
        </div>
        {pendingProposals.length === 0 ? (
          <div className="rounded-xl border border-dashed border-white/10 p-4 text-center text-xs text-zinc-500">
            No pending memory proposals to review.
          </div>
        ) : (
          <div className="space-y-3">
            {pendingProposals.map((item: any) => (
              <ProposalCard key={item.id || item.memoryId} memory={item} />
            ))}
          </div>
        )}
      </div>

      {/* Filter Bar */}
      <div className="rounded-2xl border border-white/10 bg-black/20 p-4 space-y-3">
        <h3 className="text-sm font-semibold text-zinc-200">Filter Memories</h3>
        <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-3">
          <div>
            <label className="block text-xs font-medium text-zinc-400 mb-1">Status Filter</label>
            <select
              data-debug-id="memory-filter-status-select"
              id="memory-filter-status-select"
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-zinc-100 p-2 focus:border-sky-500 focus:outline-none"
            >
              <option value="all">All Statuses</option>
              <option value="pending">Pending</option>
              <option value="active">Active</option>
              <option value="archived">Archived</option>
              <option value="rejected">Rejected</option>
            </select>
          </div>
          <div>
            <label className="block text-xs font-medium text-zinc-400 mb-1">Type Filter</label>
            <select
              data-debug-id="memory-filter-type-select"
              id="memory-filter-type-select"
              value={typeFilter}
              onChange={(e) => setTypeFilter(e.target.value)}
              className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-zinc-100 p-2 focus:border-sky-500 focus:outline-none"
            >
              <option value="">All Types</option>
              {MEMORY_TYPES.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
          </div>
        </div>
        <div className="pt-2">
          <label className="block text-xs font-medium text-zinc-400 mb-2">Scope Filters</label>
          <MemoryScopeSelector
            value={scopeFilter}
            onChange={setScopeFilter}
            hideTypeSelect
            debugPrefix="memory-filter-scope"
          />
        </div>
      </div>

      {/* Main Memories List */}
      <div className="space-y-3">
        <h3 className="text-sm font-semibold text-zinc-300">
          Memories List ({memories.length})
        </h3>
        {isLoading ? (
          <div className="text-sm text-zinc-500 py-4">Loading memories...</div>
        ) : listError ? (
          <div className="rounded-xl border border-red-400/30 bg-red-500/10 p-3 text-xs text-red-200">
            {String((listError as any)?.data?.error || (listError as any)?.error || "Failed to load memories")}
          </div>
        ) : memories.length === 0 ? (
          <div className="rounded-2xl border border-dashed border-white/10 p-6 text-center text-sm text-zinc-500">
            No memories matching the selected filters.
          </div>
        ) : (
          <div className="space-y-3">
            {memories.map((m: any) => (
              <MemoryRow key={m.id || m.memoryId} memory={m} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
};

// Sub-component for reviewing a pending proposal card
const ProposalCard: React.FC<{ memory: any }> = ({ memory }) => {
  const memoryId = memory.id || memory.memoryId;
  const isSystem = memory.ownerUserId === "system" || memory.owner_user_id === "system";

  const [title, setTitle] = useState(memory.title || "");
  const [body, setBody] = useState(memory.body || "");
  const [evidence, setEvidence] = useState(memory.evidence || "");
  const [scope, setScope] = useState<MemoryScopeValue>({
    agent_id: memory.targetAgentId,
    project_id: memory.targetProjectId,
    bridge_id: memory.targetBridgeId,
    template_id: memory.targetTemplateId,
    type: memory.type || "fact",
  });
  const [msg, setMsg] = useState<{ text: string; error?: boolean } | null>(null);

  const [updateMemory, { isLoading: isUpdating }] = useUpdateMemoryMutation();
  const [approveMemory, { isLoading: isApproving }] = useApproveMemoryMutation();
  const [rejectMemory, { isLoading: isRejecting }] = useRejectMemoryMutation();

  const handleSave = async () => {
    setMsg(null);
    try {
      await updateMemory({
        memoryId,
        title,
        body,
        evidence: evidence || undefined,
        type: scope.type,
        agent_id: scope.agent_id,
        project_id: scope.project_id,
        bridge_id: scope.bridge_id,
        template_id: scope.template_id,
      }).unwrap();
      setMsg({ text: "Edits saved." });
    } catch (err: any) {
      setMsg({ text: String(err?.data?.error || err?.message || "Failed to save edits"), error: true });
    }
  };

  const handleApprove = async () => {
    setMsg(null);
    try {
      await approveMemory({
        memoryId,
        title,
        body,
        evidence: evidence || undefined,
        type: scope.type,
        agent_id: scope.agent_id,
        project_id: scope.project_id,
        bridge_id: scope.bridge_id,
        template_id: scope.template_id,
      }).unwrap();
      setMsg({ text: "Proposal approved!" });
    } catch (err: any) {
      setMsg({ text: String(err?.data?.error || err?.message || "Failed to approve proposal"), error: true });
    }
  };

  const handleReject = async () => {
    setMsg(null);
    try {
      await rejectMemory({ memoryId, reason: "Rejected by reviewer" }).unwrap();
      setMsg({ text: "Proposal rejected." });
    } catch (err: any) {
      setMsg({ text: String(err?.data?.error || err?.message || "Failed to reject proposal"), error: true });
    }
  };

  return (
    <div
      data-debug-id={`memory-proposal-${memoryId}`}
      id={`memory-proposal-${memoryId}`}
      className="rounded-2xl border border-amber-500/30 bg-amber-950/10 p-4 space-y-3"
    >
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="rounded-full bg-amber-400/20 text-amber-200 px-2 py-0.5 text-[11px] font-bold uppercase">
            Pending Proposal
          </span>
          {isSystem && (
            <span className="rounded-full bg-purple-500/20 text-purple-200 px-2 py-0.5 text-[11px] font-bold">
              System Memory (Read-Only)
            </span>
          )}
        </div>
        <span className="text-[11px] text-zinc-500 font-mono">{memoryId}</span>
      </div>

      {msg && (
        <div className={`rounded-xl p-2.5 text-xs ${msg.error ? "border border-red-400/30 bg-red-500/10 text-red-200" : "border border-emerald-400/30 bg-emerald-500/10 text-emerald-200"}`}>
          {msg.text}
        </div>
      )}

      {isSystem ? (
        <div className="space-y-2">
          <h4 className="font-semibold text-white">{memory.title}</h4>
          <p className="text-xs text-zinc-300 whitespace-pre-wrap">{memory.body}</p>
          {memory.evidence && <p className="text-xs italic text-zinc-400">Evidence: {memory.evidence}</p>}
        </div>
      ) : (
        <div className="space-y-3">
          <div>
            <label className="block text-[11px] font-medium text-zinc-400 mb-1">Title</label>
            <input
              type="text"
              data-debug-id={`memory-proposal-title-input-${memoryId}`}
              id={`memory-proposal-title-input-${memoryId}`}
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-white p-2 focus:border-amber-500 focus:outline-none"
            />
          </div>

          <div>
            <label className="block text-[11px] font-medium text-zinc-400 mb-1">Body</label>
            <textarea
              rows={3}
              data-debug-id={`memory-proposal-body-textarea-${memoryId}`}
              id={`memory-proposal-body-textarea-${memoryId}`}
              value={body}
              onChange={(e) => setBody(e.target.value)}
              className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-white p-2 focus:border-amber-500 focus:outline-none"
            />
          </div>

          <div>
            <label className="block text-[11px] font-medium text-zinc-400 mb-1">Evidence</label>
            <input
              type="text"
              data-debug-id={`memory-proposal-evidence-input-${memoryId}`}
              id={`memory-proposal-evidence-input-${memoryId}`}
              value={evidence}
              onChange={(e) => setEvidence(e.target.value)}
              className="w-full text-sm rounded-xl border border-white/10 bg-black/40 text-white p-2 focus:border-amber-500 focus:outline-none"
            />
          </div>

          <div data-debug-id={`memory-proposal-scope-${memoryId}`} id={`memory-proposal-scope-${memoryId}`}>
            <label className="block text-[11px] font-medium text-zinc-400 mb-1">Scope Settings</label>
            <MemoryScopeSelector value={scope} onChange={setScope} debugPrefix={`memory-proposal-scope-${memoryId}`} />
          </div>

          <div className="flex flex-wrap items-center justify-end gap-2 pt-2 border-t border-white/10">
            <button
              type="button"
              data-debug-id={`memory-proposal-save-btn-${memoryId}`}
              id={`memory-proposal-save-btn-${memoryId}`}
              onClick={handleSave}
              disabled={isUpdating || isApproving || isRejecting}
              className="rounded-xl border border-white/10 bg-white/5 px-3 py-1.5 text-xs font-semibold text-zinc-300 hover:bg-white/10"
            >
              {isUpdating ? "Saving..." : "Save Edits"}
            </button>

            <button
              type="button"
              data-debug-id={`memory-proposal-reject-btn-${memoryId}`}
              id={`memory-proposal-reject-btn-${memoryId}`}
              onClick={handleReject}
              disabled={isUpdating || isApproving || isRejecting}
              className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-1.5 text-xs font-semibold text-red-200 hover:bg-red-500/20"
            >
              {isRejecting ? "Rejecting..." : "Reject"}
            </button>

            <button
              type="button"
              data-debug-id={`memory-proposal-approve-btn-${memoryId}`}
              id={`memory-proposal-approve-btn-${memoryId}`}
              onClick={handleApprove}
              disabled={isUpdating || isApproving || isRejecting}
              className="rounded-xl bg-emerald-500 px-4 py-1.5 text-xs font-bold text-black hover:bg-emerald-400"
            >
              {isApproving ? "Approving..." : "Approve (with edits)"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
};

// Sub-component for individual memory record in the main list
const MemoryRow: React.FC<{ memory: any }> = ({ memory }) => {
  const memoryId = memory.id || memory.memoryId;
  const isSystem = memory.ownerUserId === "system" || memory.owner_user_id === "system";
  const [expanded, setExpanded] = useState(false);
  const [isEditing, setIsEditing] = useState(false);

  const [archiveMemory, { isLoading: isArchiving }] = useArchiveMemoryMutation();

  const handleArchive = async () => {
    try {
      await archiveMemory({ memoryId }).unwrap();
    } catch (_e) {}
  };

  const statusColor =
    memory.status === "active"
      ? "bg-emerald-400/20 text-emerald-300"
      : memory.status === "pending"
      ? "bg-amber-400/20 text-amber-300"
      : memory.status === "archived"
      ? "bg-zinc-500/20 text-zinc-400"
      : "bg-red-400/20 text-red-300";

  return (
    <div
      data-debug-id={`settings-memory-row-${memoryId}`}
      id={`settings-memory-row-${memoryId}`}
      className="rounded-2xl border border-white/10 bg-black/20 p-4 space-y-2 hover:border-white/20 transition"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="space-y-1">
          <div className="flex flex-wrap items-center gap-2">
            <h4 className="font-bold text-white text-base">{memory.title || memoryId}</h4>
            <span className={`rounded-full px-2 py-0.5 text-[11px] font-semibold uppercase ${statusColor}`}>
              {memory.status}
            </span>
            <span className="rounded-full bg-white/10 px-2 py-0.5 text-[11px] font-medium text-zinc-300">
              {memory.type}
            </span>
            {isSystem && (
              <span className="rounded-full bg-purple-500/20 text-purple-200 px-2 py-0.5 text-[11px] font-semibold">
                System
              </span>
            )}
          </div>
          <div
            data-debug-id={`memory-row-scope-${memoryId}`}
            id={`memory-row-scope-${memoryId}`}
            className="text-xs text-zinc-400 italic"
          >
            Scope: {memory.target || "Global"}
          </div>
        </div>

        <div className="flex items-center gap-1.5 shrink-0">
          <button
            type="button"
            data-debug-id={`memory-row-open-btn-${memoryId}`}
            id={`memory-row-open-btn-${memoryId}`}
            onClick={() => setExpanded((prev) => !prev)}
            className="rounded-xl border border-white/10 bg-white/5 px-2.5 py-1 text-xs font-medium text-zinc-300 hover:bg-white/10"
          >
            {expanded ? "Collapse" : "Details"}
          </button>

          {!isSystem && (
            <button
              type="button"
              data-debug-id={`memory-row-edit-btn-${memoryId}`}
              id={`memory-row-edit-btn-${memoryId}`}
              onClick={() => setIsEditing((prev) => !prev)}
              className="rounded-xl border border-white/10 bg-white/5 px-2.5 py-1 text-xs font-medium text-zinc-300 hover:bg-white/10"
            >
              {isEditing ? "Close Edit" : "Edit"}
            </button>
          )}

          {!isSystem && memory.status !== "archived" && (
            <button
              type="button"
              data-debug-id={`memory-row-archive-btn-${memoryId}`}
              id={`memory-row-archive-btn-${memoryId}`}
              onClick={handleArchive}
              disabled={isArchiving}
              className="rounded-xl border border-red-400/20 bg-red-500/10 px-2.5 py-1 text-xs font-medium text-red-200 hover:bg-red-500/20 disabled:opacity-50"
            >
              {isArchiving ? "Archiving..." : "Archive"}
            </button>
          )}
        </div>
      </div>

      <p className="text-xs text-zinc-300 whitespace-pre-wrap line-clamp-3">
        {memory.body}
      </p>

      {expanded && (
        <div className="mt-3 pt-3 border-t border-white/10 space-y-2 text-xs text-zinc-400">
          <div><span className="font-semibold text-zinc-200">Full Body:</span> {memory.body}</div>
          {memory.evidence && <div><span className="font-semibold text-zinc-200">Evidence:</span> {memory.evidence}</div>}
          <div><span className="font-semibold text-zinc-200">ID:</span> {memoryId}</div>
          {memory.sourceTaskId && <div><span className="font-semibold text-zinc-200">Source Task ID:</span> {memory.sourceTaskId}</div>}
          {memory.version > 0 && <div><span className="font-semibold text-zinc-200">Version:</span> {memory.version}</div>}
        </div>
      )}

      {isEditing && !isSystem && (
        <div className="mt-3 pt-3 border-t border-white/10">
          <EditMemoryForm memory={memory} onClose={() => setIsEditing(false)} />
        </div>
      )}
    </div>
  );
};

// Inline Edit Form for non-system memories
const EditMemoryForm: React.FC<{ memory: any; onClose: () => void }> = ({ memory, onClose }) => {
  const memoryId = memory.id || memory.memoryId;
  const [title, setTitle] = useState(memory.title || "");
  const [body, setBody] = useState(memory.body || "");
  const [evidence, setEvidence] = useState(memory.evidence || "");
  const [scope, setScope] = useState<MemoryScopeValue>({
    agent_id: memory.targetAgentId,
    project_id: memory.targetProjectId,
    bridge_id: memory.targetBridgeId,
    template_id: memory.targetTemplateId,
    type: memory.type || "fact",
  });
  const [err, setErr] = useState("");

  const [updateMemory, { isLoading }] = useUpdateMemoryMutation();

  const handleUpdate = async (e: React.FormEvent) => {
    e.preventDefault();
    setErr("");
    try {
      await updateMemory({
        memoryId,
        title,
        body,
        evidence: evidence || undefined,
        type: scope.type,
        agent_id: scope.agent_id,
        project_id: scope.project_id,
        bridge_id: scope.bridge_id,
        template_id: scope.template_id,
      }).unwrap();
      onClose();
    } catch (e: any) {
      setErr(String(e?.data?.error || e?.message || "Failed to update memory"));
    }
  };

  return (
    <form onSubmit={handleUpdate} className="space-y-3 bg-black/40 p-3 rounded-xl border border-white/10">
      <h5 className="text-xs font-bold text-zinc-200">Edit Memory</h5>
      {err && <div className="text-xs text-red-300">{err}</div>}
      <div>
        <label className="block text-[11px] text-zinc-400 mb-1">Title</label>
        <input
          type="text"
          data-debug-id={`memory-edit-title-input-${memoryId}`}
          id={`memory-edit-title-input-${memoryId}`}
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          className="w-full text-xs rounded-lg border border-white/10 bg-black/60 text-white p-2"
        />
      </div>
      <div>
        <label className="block text-[11px] text-zinc-400 mb-1">Body</label>
        <textarea
          rows={2}
          data-debug-id={`memory-edit-body-textarea-${memoryId}`}
          id={`memory-edit-body-textarea-${memoryId}`}
          value={body}
          onChange={(e) => setBody(e.target.value)}
          className="w-full text-xs rounded-lg border border-white/10 bg-black/60 text-white p-2"
        />
      </div>
      <div>
        <label className="block text-[11px] text-zinc-400 mb-1">Evidence</label>
        <input
          type="text"
          data-debug-id={`memory-edit-evidence-input-${memoryId}`}
          id={`memory-edit-evidence-input-${memoryId}`}
          value={evidence}
          onChange={(e) => setEvidence(e.target.value)}
          className="w-full text-xs rounded-lg border border-white/10 bg-black/60 text-white p-2"
        />
      </div>
      <div>
        <label className="block text-[11px] text-zinc-400 mb-1">Scope</label>
        <MemoryScopeSelector value={scope} onChange={setScope} debugPrefix={`memory-edit-scope-${memoryId}`} />
      </div>
      <div className="flex justify-end gap-2 pt-1">
        <button
          type="button"
          data-debug-id={`memory-edit-cancel-btn-${memoryId}`}
          id={`memory-edit-cancel-btn-${memoryId}`}
          onClick={onClose}
          className="rounded-lg border border-white/10 bg-white/5 px-3 py-1 text-xs text-zinc-300"
        >
          Cancel
        </button>
        <button
          type="submit"
          data-debug-id={`memory-edit-save-btn-${memoryId}`}
          id={`memory-edit-save-btn-${memoryId}`}
          disabled={isLoading}
          className="rounded-lg bg-sky-500 px-3 py-1 text-xs font-bold text-black hover:bg-sky-400"
        >
          {isLoading ? "Saving..." : "Save Changes"}
        </button>
      </div>
    </form>
  );
};

export default MemoryPanel;
