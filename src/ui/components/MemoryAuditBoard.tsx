import { useState, useMemo, useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { triggerMemoryAudit, decideMemoryProposal, proposeMemoryChange, refreshMemory, clearActiveAudit } from '../store/memorySlice';
import * as daemonApi from '../api/daemonApi';

const TIME_RANGES = [
  { value: '1h', label: 'Last 1 Hour' },
  { value: '24h', label: 'Last 24 Hours' },
  { value: '1d', label: 'Last 1 Day' },
  { value: '7d', label: 'Last 7 Days' },
  { value: 'all', label: 'All Time' },
];

export default function MemoryAuditBoard({ session, agents = [] }: { session: any; agents?: any[] }) {
  console.log('[Render] MemoryAuditBoard');
  const dispatch = useDispatch<any>();
  const { recordsById, recordIds, activeAudit, auditLoading, error } = useSelector((state: any) => state.memory);
  const [timeRange, setTimeRange] = useState('24h');
  const [editingPropId, setEditingPropId] = useState<string | null>(null);
  const [editTitle, setEditTitle] = useState('');
  const [editBody, setEditBody] = useState('');
  const [decisionReason, setDecisionReason] = useState('');
  const [decidingId, setDecidingId] = useState<string | null>(null);

  // Auditor/Reviewer/Timeout states
  const [auditorId, setAuditorId] = useState('');
  const [reviewerId, setReviewerId] = useState('');
  const [timeoutMin, setTimeoutMin] = useState('10');
  const [prefLoading, setPrefLoading] = useState(false);

  // Refresh memories and fetch preferences on mount
  useEffect(() => {
    if (session.connected && session.clientToken) {
      dispatch(refreshMemory());
      fetchPrefs();
    }
  }, [dispatch, session.connected, session.clientToken]);

  const fetchPrefs = async () => {
    setPrefLoading(true);
    try {
      const data = await daemonApi.fetchPreferences({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
      });
      if (data?.preferences) {
        const aud = data.preferences.find((p: any) => p.key === 'memory_auditor_agent_id')?.value || '';
        const rev = data.preferences.find((p: any) => p.key === 'memory_reviewer_agent_id')?.value || '';
        const tout = data.preferences.find((p: any) => p.key === 'memory_auditor_timeout_min')?.value || '10';
        setAuditorId(aud);
        setReviewerId(rev);
        setTimeoutMin(tout);
      }
    } catch (err) {
      console.error('Failed to fetch preferences in MemoryAuditBoard:', err);
    } finally {
      setPrefLoading(false);
    }
  };

  const handlePrefChange = async (key: string, value: string) => {
    if (key === 'memory_auditor_agent_id') setAuditorId(value);
    if (key === 'memory_reviewer_agent_id') setReviewerId(value);
    if (key === 'memory_auditor_timeout_min') setTimeoutMin(value);

    try {
      await daemonApi.savePreference({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
        key,
        value,
        interrupt: false,
      });
    } catch (err) {
      console.error(`Failed to save preference ${key}:`, err);
      alert('Failed to save configuration change');
    }
  };

  // Map agents to project IDs for hierarchical grouping
  const agentProjectMap = useMemo(() => {
    const map: Record<string, { projectId: string; projectName: string }> = {};
    for (const agent of agents) {
      map[agent.id] = {
        projectId: agent.projectId || 'unassigned',
        projectName: agent.projectName || agent.projectId || 'Unassigned Project',
      };
    }
    return map;
  }, [agents]);

  // Extract and filter pending proposals
  const pendingProposals = useMemo(() => {
    return recordIds
      .map((id) => recordsById[id])
      .filter((rec) => rec && rec.status === 'pending' && rec.proposalId);
  }, [recordIds, recordsById]);

  // Group pending proposals by project and agent instance
  const groupedProposals = useMemo(() => {
    const groups: Record<string, { name: string; agents: Record<string, any[]> }> = {};
    
    for (const prop of pendingProposals) {
      const agentId = prop.subjectAgent || 'global';
      const projectInfo = agentProjectMap[agentId] || { projectId: 'unassigned', projectName: 'No Project' };
      const projId = projectInfo.projectId;

      if (!groups[projId]) {
        groups[projId] = { name: projectInfo.projectName, agents: {} };
      }
      if (!groups[projId].agents[agentId]) {
        groups[projId].agents[agentId] = [];
      }
      groups[projId].agents[agentId].push(prop);
    }
    return groups;
  }, [pendingProposals, agentProjectMap]);

  const knownAgentIds = useMemo(() => agents.map((a: any) => a.id), [agents]);
  const isAuditorKnown = useMemo(() => auditorId !== '' && knownAgentIds.includes(auditorId), [auditorId, knownAgentIds]);
  const isReviewerKnown = useMemo(() => reviewerId !== '' && knownAgentIds.includes(reviewerId), [reviewerId, knownAgentIds]);
  const isConfigValid = isAuditorKnown && isReviewerKnown;

  const auditorOptions = useMemo(() => Array.from(new Set([...knownAgentIds, auditorId])).filter(Boolean), [knownAgentIds, auditorId]);
  const reviewerOptions = useMemo(() => Array.from(new Set([...knownAgentIds, reviewerId])).filter(Boolean), [knownAgentIds, reviewerId]);

  const canTrigger = Boolean(session.clientToken) && 
                     session.connected && 
                     !auditLoading && 
                     (!activeAudit || activeAudit.status !== 'started') &&
                     isConfigValid;

  const handleTrigger = () => {
    if (!canTrigger) return;
    dispatch(triggerMemoryAudit(timeRange));
  };

  const handleDecide = async (proposalId: string, memoryId: string, decision: 'approve' | 'reject') => {
    setDecidingId(proposalId);
    try {
      await dispatch(decideMemoryProposal({
        proposalId,
        decision,
        reason: decisionReason.trim() || `Operator ${decision}d memory proposal.`
      })).unwrap();
      setDecisionReason('');
    } catch (e) {
      console.error('Failed to decide memory:', e);
    } finally {
      setDecidingId(null);
    }
  };

  const handleStartEdit = (prop: any) => {
    setEditingPropId(prop.proposalId);
    setEditTitle(prop.title || '');
    setEditBody(prop.body || '');
  };

  const handleSaveEdit = async (prop: any) => {
    if (!editTitle.trim() || !editBody.trim()) return;
    setDecidingId(prop.proposalId);
    try {
      // Propose edit
      await dispatch(proposeMemoryChange({
        proposalAction: 'edit',
        memory_id: prop.memoryId,
        expected_version: prop.version,
        subject_agent: prop.subjectAgent,
        scope: prop.scope,
        type: prop.type,
        title: editTitle.trim(),
        body: editBody.trim(),
        reason: 'Operator edited proposal content.',
        evidence: prop.evidence || 'Operator manual adjustment.',
        source_task_id: prop.sourceTaskId,
      })).unwrap();
      
      setEditingPropId(null);
    } catch (e) {
      console.error('Failed to edit proposal:', e);
    } finally {
      setDecidingId(null);
    }
  };

  return (
    <main className="flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)] overflow-hidden">
      {/* Page Header */}
      <header className="framer-panel flex items-center justify-between border-b border-[var(--fd-hairline)] px-6 py-4 shrink-0">
        <div>
          <p className="framer-topline tracking-[0.28em]">Auditor</p>
          <h2 className="mt-1 text-2xl font-bold text-white">Memory Audit Workspace</h2>
        </div>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => dispatch(refreshMemory())}
            className="framer-pill-secondary"
            disabled={auditLoading}
          >
            Refresh
          </button>
        </div>
      </header>

      {/* Content Body */}
      <section className="flex-1 overflow-y-auto p-6 space-y-6">
        {/* Trigger Panel & Active Runs */}
        <div className="grid md:grid-cols-[1fr_1.5fr] gap-6 items-start">
          {/* Trigger Card */}
          <div className="framer-card-xl p-5 flex flex-col gap-4">
            <div>
              <h3 className="text-sm font-bold text-white uppercase tracking-wider">Trigger Cognitive Audit</h3>
              <p className="text-[11px] text-[#666] mt-1 leading-relaxed">
                Scan recently completed 'good' task chains and generate memory proposals using the system agents.
              </p>
            </div>
            
            <div className="flex flex-col gap-2.5">
              <label className="text-[10px] text-[#555] font-bold uppercase tracking-wider">Audit Timeframe</label>
              <select
                value={timeRange}
                onChange={(e) => setTimeRange(e.target.value)}
                className="framer-input px-3 py-2 text-sm w-full"
                disabled={auditLoading}
              >
                {TIME_RANGES.map((range) => (
                  <option key={range.value} value={range.value}>
                    {range.label}
                  </option>
                ))}
              </select>
            </div>

            {/* Auditor Picker */}
            <div className="flex flex-col gap-2">
              <label className="text-[10px] text-[#555] font-bold uppercase tracking-wider">🔍 Memory Auditor Agent</label>
              <select
                value={auditorId}
                onChange={(e) => handlePrefChange('memory_auditor_agent_id', e.target.value)}
                className="framer-input px-3 py-2 text-sm w-full font-sans"
                disabled={auditLoading || prefLoading}
              >
                <option value="">-- Select Auditor Agent --</option>
                {auditorOptions.map(id => (
                  <option key={id} value={id}>{id} {!knownAgentIds.includes(id) && '(Offline/Unregistered)'}</option>
                ))}
              </select>
            </div>

            {/* Reviewer Picker */}
            <div className="flex flex-col gap-2">
              <label className="text-[10px] text-[#555] font-bold uppercase tracking-wider">⚖️ Memory Reviewer Agent</label>
              <select
                value={reviewerId}
                onChange={(e) => handlePrefChange('memory_reviewer_agent_id', e.target.value)}
                className="framer-input px-3 py-2 text-sm w-full font-sans"
                disabled={auditLoading || prefLoading}
              >
                <option value="">-- Select Reviewer Agent --</option>
                {reviewerOptions.map(id => (
                  <option key={id} value={id}>{id} {!knownAgentIds.includes(id) && '(Offline/Unregistered)'}</option>
                ))}
              </select>
            </div>

            {/* Timeout Config */}
            <div className="flex flex-col gap-2">
              <label className="text-[10px] text-[#555] font-bold uppercase tracking-wider">⏱️ Audit Execution Timeout (minutes)</label>
              <input
                type="number"
                min="1"
                max="120"
                value={timeoutMin}
                onChange={(e) => handlePrefChange('memory_auditor_timeout_min', e.target.value)}
                className="framer-input px-3 py-2 text-sm w-full font-mono"
                disabled={auditLoading || prefLoading}
                placeholder="e.g. 10"
              />
            </div>

            {/* Configuration Validation Warning */}
            {!isConfigValid && !prefLoading && (
              <div className="text-[10px] text-yellow-500 bg-yellow-500/5 border border-yellow-500/10 p-2.5 rounded-lg leading-relaxed">
                <span className="font-bold">⚠️ Trigger Blocked</span>
                <span className="block mt-0.5 text-[#888]">Both agents must be configured with registered online agents to trigger an audit.</span>
                {!isAuditorKnown && <span className="block mt-0.5 text-yellow-400/90">• Auditor <code className="text-yellow-300 font-mono">"{auditorId || 'None'}"</code> is unregistered.</span>}
                {!isReviewerKnown && <span className="block mt-0.5 text-yellow-400/90">• Reviewer <code className="text-yellow-300 font-mono">"{reviewerId || 'None'}"</code> is unregistered.</span>}
              </div>
            )}

            <button
              type="button"
              onClick={handleTrigger}
              className={`w-full py-2.5 rounded-xl font-bold text-sm transition-all duration-200 ${
                canTrigger
                  ? 'bg-white text-black hover:bg-[#e0e0e0] active:scale-[0.98]'
                  : 'bg-[#111] border border-[#222] text-[#444] pointer-events-none'
              }`}
            >
              {auditLoading ? 'Starting Audit...' : 'Trigger Memory Audit'}
            </button>
          </div>

          {/* Active Audit Run Banner */}
          {activeAudit && (
            <div
              className={`framer-card-xl p-5 border transition-all duration-300 ${
                activeAudit.status === 'started'
                  ? 'border-amber-500/20 bg-amber-500/5'
                  : activeAudit.status === 'failed'
                  ? 'border-red-500/25 bg-red-500/5'
                  : 'border-emerald-500/20 bg-emerald-500/5'
              }`}
            >
              <div className="flex items-start justify-between gap-4">
                <div className="flex-1">
                  <div className="flex items-center gap-2">
                    <span
                      className={`h-2 w-2 rounded-full ${
                        activeAudit.status === 'started'
                          ? 'bg-amber-500 animate-pulse'
                          : activeAudit.status === 'failed'
                          ? 'bg-red-500'
                          : 'bg-emerald-500'
                      }`}
                    />
                    <h4 className="text-xs font-extrabold uppercase tracking-wider text-white">
                      {activeAudit.status === 'started'
                        ? 'Cognitive Audit in Progress'
                        : activeAudit.status === 'failed'
                        ? 'Audit Run Failed'
                        : 'Audit Run Completed'}
                    </h4>
                  </div>
                  <p className="text-[11px] text-[#888] mt-1">ID: {activeAudit.auditId}</p>

                  {activeAudit.status === 'started' && (
                    <div className="mt-4 space-y-3 animate-fade-in">
                      <div className="flex items-center gap-2">
                        <div className="w-4 h-4 border-2 border-t-transparent border-amber-500 rounded-full animate-spin shrink-0" />
                        <span className="text-xs text-[#aaa]">
                          Memory Auditor agent is active. Scanning task chains...
                        </span>
                      </div>
                      {activeAudit.targetChains.length > 0 && (
                        <div className="bg-[#0c0c0c] border border-[#151515] p-2.5 rounded-lg">
                          <span className="text-[9px] text-[#555] font-bold uppercase block tracking-wider">
                            Harvesting target chains
                          </span>
                          <div className="flex flex-wrap gap-1.5 mt-1.5">
                            {activeAudit.targetChains.map((c) => (
                              <span key={c} className="text-[10px] bg-[#1a1a1a] text-[#aaa] border border-[#2a2a2a] px-2 py-0.5 rounded font-mono">
                                {c}
                              </span>
                            ))}
                          </div>
                        </div>
                      )}
                    </div>
                  )}

                  {activeAudit.status === 'failed' && (
                    <div className="mt-3 text-xs text-red-300 bg-red-500/10 border border-red-500/20 p-3 rounded-xl">
                      {activeAudit.error || 'The audit process encountered an unexpected timeout.'}
                    </div>
                  )}

                  {activeAudit.status === 'completed' && (
                    <p className="text-xs text-emerald-300 mt-2">
                      Harvesting and curation review concluded successfully! Pending proposals updated below.
                    </p>
                  )}
                </div>

                <button
                  type="button"
                  onClick={() => dispatch(clearActiveAudit())}
                  className="text-[#555] hover:text-[#bbb] p-1 transition-colors rounded-lg"
                  aria-label="Dismiss banner"
                >
                  <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2.5} d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Global Error Banner */}
        {error && (
          <div className="rounded-2xl border border-red-500/30 bg-red-500/10 p-4 text-sm text-red-200 animate-fade-in flex justify-between items-start gap-4">
            <span>{error}</span>
          </div>
        )}

        {/* Pending proposals Workspace */}
        <div>
          <h3 className="text-xs font-bold text-[#888] uppercase tracking-wider mb-4">Pending Memory Proposals Workspace</h3>
          
          {pendingProposals.length === 0 ? (
            <div className="framer-card border border-dashed border-[#222] p-8 text-center flex flex-col items-center justify-center gap-3">
              <div className="w-10 h-10 rounded-full bg-[#111] border border-[#222] flex items-center justify-center text-[#444]">
                <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
                </svg>
              </div>
              <p className="text-xs font-semibold text-[#888]">No pending memory proposals found.</p>
              <p className="text-[10px] text-[#555] max-w-sm leading-relaxed">
                Trigger a memory audit or let your agents complete more task runs to harvest cognitive improvements.
              </p>
            </div>
          ) : (
            <div className="space-y-6">
              {Object.entries(groupedProposals).map(([projId, project]) => (
                <div key={projId} className="space-y-4">
                  {/* Project Header */}
                  <div className="flex items-center gap-2 border-b border-[#222] pb-1.5">
                    <span className="text-xs bg-[#1a1a1a] text-[var(--fd-accent-blue)] border border-[var(--fd-accent-blue)]/20 px-2 py-0.5 rounded font-bold uppercase tracking-wider">
                      Project
                    </span>
                    <h4 className="text-sm font-extrabold text-[#eee]">{project.name}</h4>
                  </div>

                  {/* Grouped by Agent */}
                  <div className="space-y-4 pl-2 border-l border-[#1c1c1c]">
                    {Object.entries(project.agents).map(([agentId, proposals]) => (
                      <div key={agentId} className="space-y-3">
                        <div className="flex items-center gap-1.5 text-xs text-[#888]">
                          <span className="font-semibold text-[#bbb]">{agentId.split('@')[0]}</span>
                          <span className="text-[#444]">•</span>
                          <span>{proposals.length} proposed updates</span>
                        </div>

                        {/* Proposal Cards Grid */}
                        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
                          {proposals.map((prop) => {
                            const isEditing = editingPropId === prop.proposalId;
                            const isDeciding = decidingId === prop.proposalId;
                            
                            return (
                              <div
                                key={prop.proposalId}
                                className="framer-card-xl p-4 flex flex-col justify-between gap-4 border border-[#222] hover:border-[#333] transition-all"
                              >
                                <div>
                                  {/* Card Header */}
                                  <div className="flex items-start justify-between gap-2">
                                    <span className="text-[9px] bg-amber-500/10 text-amber-300 border border-amber-500/20 px-1.5 py-0.5 rounded font-bold uppercase tracking-wider">
                                      {prop.type}
                                    </span>
                                    <span className="text-[10px] text-[#555] font-mono shrink-0">
                                      {prop.scope}
                                    </span>
                                  </div>

                                  {/* Card Content / Editor */}
                                  {isEditing ? (
                                    <div className="mt-3 space-y-3">
                                      <input
                                        type="text"
                                        value={editTitle}
                                        onChange={(e) => setEditTitle(e.target.value)}
                                        className="framer-input w-full px-2 py-1.5 text-xs"
                                        placeholder="Proposal Title"
                                      />
                                      <textarea
                                        value={editBody}
                                        onChange={(e) => setEditBody(e.target.value)}
                                        className="framer-input w-full px-2 py-1.5 text-xs min-h-24 font-mono"
                                        placeholder="Memory Body"
                                      />
                                    </div>
                                  ) : (
                                    <div className="mt-3">
                                      <h5 className="text-sm font-semibold text-[#eee] leading-snug">
                                        {prop.title || 'Proposed Guidance'}
                                      </h5>
                                      <pre className="mt-2 text-xs text-[#bbb] bg-[#0c0c0c] p-2.5 rounded border border-[#151515] overflow-x-auto whitespace-pre-wrap break-all font-mono max-h-48 overflow-y-auto">
                                        {prop.body}
                                      </pre>
                                    </div>
                                  )}

                                  {/* Curation Justification */}
                                  {!isEditing && (
                                    <div className="mt-3 border-t border-[#181818] pt-3 space-y-2">
                                      {prop.reason && (
                                        <div>
                                          <span className="text-[9px] text-[#555] font-bold uppercase tracking-wider block">
                                            Justification Reason
                                          </span>
                                          <p className="text-xs text-[#888] leading-relaxed italic">
                                            {prop.reason}
                                          </p>
                                        </div>
                                      )}
                                      {prop.evidence && (
                                        <div>
                                          <span className="text-[9px] text-[#555] font-bold uppercase tracking-wider block">
                                            Source Evidence
                                          </span>
                                          <p className="text-[10px] text-[#777] leading-relaxed">
                                            {prop.evidence}
                                          </p>
                                        </div>
                                      )}
                                    </div>
                                  )}
                                </div>

                                {/* Curation Actions Footer */}
                                <div className="border-t border-[#1a1a1a] pt-3 flex items-center justify-end gap-2 shrink-0">
                                  {isEditing ? (
                                    <>
                                      <button
                                        type="button"
                                        onClick={() => setEditingPropId(null)}
                                        className="framer-pill-secondary px-2.5 py-1 text-xs"
                                        disabled={isDeciding}
                                      >
                                        Cancel
                                      </button>
                                      <button
                                        type="button"
                                        onClick={() => handleSaveEdit(prop)}
                                        className="framer-pill px-2.5 py-1 text-xs"
                                        disabled={isDeciding}
                                      >
                                        Save & Approve
                                      </button>
                                    </>
                                  ) : (
                                    <>
                                      <button
                                        type="button"
                                        onClick={() => handleStartEdit(prop)}
                                        className="framer-pill-secondary px-2.5 py-1 text-xs border border-[#333] hover:border-[#555]"
                                        disabled={isDeciding}
                                      >
                                        Edit
                                      </button>
                                      <button
                                        type="button"
                                        onClick={() => handleDecide(prop.proposalId, prop.memoryId, 'reject')}
                                        className="framer-pill-secondary px-2.5 py-1 text-xs border border-red-500/20 hover:border-red-500/40 text-red-400 hover:text-red-300"
                                        disabled={isDeciding}
                                      >
                                        Reject
                                      </button>
                                      <button
                                        type="button"
                                        onClick={() => handleDecide(prop.proposalId, prop.memoryId, 'approve')}
                                        className="framer-pill px-2.5 py-1 text-xs bg-white text-black font-bold hover:bg-[#e0e0e0]"
                                        disabled={isDeciding}
                                      >
                                        Approve
                                      </button>
                                    </>
                                  )}
                                </div>
                              </div>
                            );
                          })}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </section>

      {/* Decision Reason Drawer Overlay */}
      {decidingId && (
        <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4">
          <div className="bg-[#0a0a0a] border border-[#222] p-5 rounded-2xl max-w-md w-full shadow-2xl space-y-4">
            <div>
              <h4 className="text-sm font-bold text-white uppercase tracking-wider">Curation Decision Justification</h4>
              <p className="text-[11px] text-[#666] mt-1 leading-relaxed">
                Provide an optional justification reason for this curation choice to log in the memory history trail.
              </p>
            </div>
            <textarea
              value={decisionReason}
              onChange={(e) => setDecisionReason(e.target.value)}
              placeholder="e.g., Guidance is accurate and aligns with team styling guidelines."
              className="framer-input w-full px-3 py-2 text-xs min-h-20"
            />
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => {
                  setDecidingId(null);
                  setDecisionReason('');
                }}
                className="framer-pill-secondary"
              >
                Skip Justification
              </button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}
