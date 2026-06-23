import { useEffect, useState, memo, FormEvent, useCallback } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { refreshAgents, setTestRuns } from '../store/chatSlice';
import * as daemonApi from '../api/daemonApi';

const STATUS_DOT: Record<string, string> = {
  connected: 'bg-emerald-400 shadow-emerald-400/40',
  starting: 'bg-sky-400 shadow-sky-400/40',
  startup_blocked: 'bg-amber-400 shadow-amber-400/40',
  startup_failed: 'bg-red-400 shadow-red-400/40',
  stopping: 'bg-amber-400 shadow-amber-400/40 animate-soft-pulse',
  offline: 'bg-[#555]/70',
};

const STATUS_LABEL: Record<string, string> = {
  connected: 'Live',
  starting: 'Starting',
  startup_blocked: 'Blocked',
  startup_failed: 'Failed',
  stopping: 'Stopping',
  offline: 'Known',
};

function StoppingLabel({ agent }: { agent: any }) {
  const [remaining, setRemaining] = useState<number | null>(null);

  useEffect(() => {
    if (!agent.stopRequestedUnixMs || !agent.stopTimeoutSeconds) {
      setRemaining(null);
      return;
    }

    const calculateRemaining = () => {
      const elapsedMs = Date.now() - agent.stopRequestedUnixMs;
      const elapsedSec = Math.floor(elapsedMs / 1000);
      const rem = Math.max(0, agent.stopTimeoutSeconds - elapsedSec);
      setRemaining(rem);
    };

    calculateRemaining();
    const interval = window.setInterval(calculateRemaining, 1000);
    return () => window.clearInterval(interval);
  }, [agent.stopRequestedUnixMs, agent.stopTimeoutSeconds]);

  if (remaining === null) return <span>Stopping...</span>;
  return <span>Stopping ({remaining}s)</span>;
}


function normalizeTemplate(t: any) {
  return {
    templateId: t.template_id || t.templateId || '',
    displayName: t.display_name || t.displayName || t.template_id || '',
    roleHint: t.role_hint || t.roleHint || '',
    defaultProviderProfile: t.default_provider_profile || t.defaultProviderProfile || '',
    persona: t.persona || '',
    instructions: t.instructions || '',
    suggestedModelTier: t.suggested_model_tier || t.suggestedModelTier || 'normal',
  };
}

const blankTemplate = { templateId: '', displayName: '', roleHint: '', defaultProviderProfile: '', persona: '', instructions: '', suggestedModelTier: 'normal' };

export default function AgentsPage({ session, onOpenStartAgent }: { session: any; onOpenStartAgent: () => void }) {
  const renderStart = performance.now();
  useEffect(() => {
    const duration = performance.now() - renderStart;
    console.log(`[Render Timer] AgentsPage took ${duration.toFixed(2)}ms`);
  });
  const dispatch = useDispatch<any>();
  const agents = useSelector((state: any) => state.chat.agents);
  const testRuns = useSelector((state: any) => state.chat.testRuns);

  const [tab, setTab] = useState<'agents' | 'templates' | 'test'>('agents');

  // --- Known Agents state ---
  const [archiving, setArchiving] = useState<string | null>(null);
  const [stopping, setStopping] = useState<string | null>(null);
  const [starting, setStarting] = useState<string | null>(null);
  const [agentError, setAgentError] = useState('');
  const [editingAgentId, setEditingAgentId] = useState<string | null>(null);
  const [agentSaving, setAgentSaving] = useState(false);
  const [agentFormError, setAgentFormError] = useState('');

  // --- Templates state ---
  const [templates, setTemplates] = useState<any[]>([]);
  const [templatesLoading, setTemplatesLoading] = useState(false);
  const [templatesError, setTemplatesError] = useState('');
  const [editingTemplate, setEditingTemplate] = useState<any | null>(null);
  const [templateSaving, setTemplateSaving] = useState(false);
  const [templateFormError, setTemplateFormError] = useState('');

  // --- Test Providers state ---
  const [testProviders, setTestProviders] = useState<string[]>([]);
  const [testProvider, setTestProvider] = useState('');
  const [testTier, setTestTier] = useState<'cheap' | 'normal' | 'smart'>('normal');
  const [testLaunching, setTestLaunching] = useState(false);
  const [testError, setTestError] = useState('');

  // Load templates on mount (needed for agent edit dropdown too)
  useEffect(() => {
    loadTemplates();
  }, [session.daemonUrl]);

  const loadTemplates = useCallback(async () => {
    setTemplatesLoading(true);
    setTemplatesError('');
    try {
      const items = await daemonApi.listAgentTemplates({ daemonUrl: session.daemonUrl });
      setTemplates((items ?? []).map(normalizeTemplate).filter((t) => t.templateId));
    } catch {
      // Silently fall back — daemon may not be reachable yet
    } finally {
      setTemplatesLoading(false);
    }
  }, [session.daemonUrl]);

  // Load providers + history when test tab is opened
  useEffect(() => {
    if (tab !== 'test') return;
    daemonApi.listAgentProviders({ daemonUrl: session.daemonUrl })
      .then((providers: any) => {
        const names: string[] = (providers ?? []).map((p: any) => p.name || p).filter(Boolean);
        setTestProviders(names);
        if (!testProvider && names.length > 0) setTestProvider(names[0]);
      })
      .catch(() => {});
    daemonApi.getTestHistory({ daemonUrl: session.daemonUrl })
      .then((data: any) => { dispatch(setTestRuns(data?.runs ?? [])); })
      .catch(() => {});
  }, [tab, session.daemonUrl]);

  async function handleRunTest() {
    if (!testProvider) return;
    setTestLaunching(true);
    setTestError('');
    try {
      await daemonApi.testLaunch({ daemonUrl: session.daemonUrl, provider: testProvider, tier: testTier });
    } catch (err: any) {
      setTestError(err?.message || 'Failed to launch test');
    } finally {
      setTestLaunching(false);
    }
  }

  // ---- Agent actions ----

  function startEditAgent(agent: any) {
    setEditingAgentId(agent.id);
    setAgentFormError('');
  }

  const cancelEditAgent = useCallback(() => {
    setEditingAgentId(null);
    setAgentFormError('');
  }, []);

  const handleSaveAgent = useCallback(async (formData: any) => {
    const name = formData.displayName.trim();
    if (!name) { setAgentFormError('Display name is required.'); return; }
    const duplicate = agents.find((a: any) => (a.label || '').trim().toLowerCase() === name.toLowerCase() && a.id !== editingAgentId);
    if (duplicate) { setAgentFormError(`An agent named "${name}" already exists.`); return; }
    setAgentSaving(true);
    setAgentFormError('');
    try {
      await daemonApi.updateAgent({
        daemonUrl: session.daemonUrl,
        agentInstanceId: editingAgentId!,
        displayName: name,
        templateId: formData.templateId || undefined,
        providerProfile: formData.providerProfile || undefined,
        modelTier: formData.modelTier || undefined,
      });
      setEditingAgentId(null);
      dispatch(refreshAgents());
    } catch (err: any) {
      setAgentFormError(err?.message || 'Failed to update agent');
    } finally {
      setAgentSaving(false);
    }
  }, [agents, editingAgentId, session.daemonUrl, dispatch]);

  async function handleStopAgent(agent: any) {
    setStopping(agent.id);
    setAgentError('');
    try {
      await daemonApi.stopAgent({ daemonUrl: session.daemonUrl, agentInstanceId: agent.id });
      dispatch(refreshAgents());
    } catch (err: any) {
      setAgentError(err?.message || 'Failed to stop agent');
    } finally {
      setStopping(null);
    }
  }

  async function handleStartAgent(agent: any) {
    setStarting(agent.id);
    setAgentError('');
    try {
      const tpl = templates.find((t) => t.templateId === agent.templateId);
      await daemonApi.startAgent({
        daemonUrl: session.daemonUrl,
        agentInstanceId: agent.id,
        provider: agent.providerProfile || tpl?.defaultProviderProfile || 'pi',
        templateId: agent.templateId || undefined,
        projectId: agent.projectId || undefined,
        displayName: agent.label,
        modelTier: agent.modelTier || 'normal',
      });
      dispatch(refreshAgents());
    } catch (err: any) {
      setAgentError(err?.message || 'Failed to start agent');
    } finally {
      setStarting(null);
    }
  }

  async function handleArchiveAgent(agent: any) {
    if (!window.confirm(`Archive agent "${agent.label}"? This cannot be undone.`)) return;
    setArchiving(agent.id);
    setAgentError('');
    try {
      await daemonApi.archiveAgent({ daemonUrl: session.daemonUrl, agentInstanceId: agent.id });
      dispatch(refreshAgents());
    } catch (err: any) {
      setAgentError(err?.message || 'Failed to archive agent');
    } finally {
      setArchiving(null);
    }
  }

  // ---- Template actions ----

  function startEditTemplate(template: any) {
    setEditingTemplate(template);
    setTemplateFormError('');
  }

  function startNewTemplate() {
    setEditingTemplate({});
    setTemplateFormError('');
  }

  const cancelTemplateEdit = useCallback(() => {
    setEditingTemplate(null);
    setTemplateFormError('');
  }, []);

  const handleSaveTemplate = useCallback(async (formData: any) => {
    const name = formData.displayName.trim();
    const id = formData.templateId.trim();
    if (!name) { setTemplateFormError('Display name is required.'); return; }
    const isNew = !editingTemplate?.templateId;
    if (isNew && !id) { setTemplateFormError('Template ID is required for new templates.'); return; }
    const duplicate = templates.find((t) => t.displayName.trim().toLowerCase() === name.toLowerCase() && t.templateId !== editingTemplate?.templateId);
    if (duplicate) { setTemplateFormError(`A template named "${name}" already exists.`); return; }
    setTemplateSaving(true);
    setTemplateFormError('');
    try {
      await daemonApi.saveAgentTemplate({
        daemonUrl: session.daemonUrl,
        template: {
          template_id: isNew ? id : editingTemplate.templateId,
          display_name: name,
          role_hint: formData.roleHint.trim(),
          default_provider_profile: formData.defaultProviderProfile.trim(),
          persona: formData.persona.trim(),
          instructions: formData.instructions.trim(),
          suggested_model_tier: formData.suggestedModelTier,
          update: !isNew,
        },
      });
      setEditingTemplate(null);
      await loadTemplates();
    } catch (err: any) {
      setTemplateFormError(err?.message || 'Failed to save template');
    } finally {
      setTemplateSaving(false);
    }
  }, [editingTemplate, templates, session.daemonUrl, loadTemplates]);

  async function handleArchiveTemplate(templateId: string, name: string) {
    if (!window.confirm(`Archive template "${name}"? Agents using it won't be affected.`)) return;
    try {
      await daemonApi.archiveAgentTemplate({ daemonUrl: session.daemonUrl, templateId });
      await loadTemplates();
    } catch (err: any) {
      setTemplatesError(err?.message || 'Failed to archive template');
    }
  }

  return (
    <main className="flex min-w-0 min-h-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="framer-panel flex items-center justify-between border-b border-[var(--fd-hairline)] px-6 py-4">
        <div>
          <p className="framer-topline tracking-[0.28em]">Heimdall</p>
          <h2 className="mt-1 text-2xl font-bold text-white">Agents</h2>
        </div>
        <button type="button" data-debug-id="agents-page-start-agent-btn" onClick={onOpenStartAgent} className="framer-pill">
          + Start agent
        </button>
      </header>

      <div className="flex gap-1 border-b border-[var(--fd-hairline)] px-6 pt-3">
        {(['agents', 'templates', 'test'] as const).map((t) => (
          <button
            key={t}
            type="button"
            data-debug-id={`agents-tab-${t}`}
            onClick={() => setTab(t)}
            className={`rounded-t-lg border border-b-0 px-4 py-2 text-xs font-semibold uppercase tracking-[0.14em] transition ${
              tab === t
                ? 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] text-white'
                : 'border-transparent text-[#777] hover:text-white'
            }`}
          >
            {t === 'agents' ? 'Known Agents' : t === 'templates' ? 'Templates' : 'Test Providers'}
          </button>
        ))}
      </div>

      <div className="flex flex-1 flex-col overflow-y-auto p-6">

        {/* ---- KNOWN AGENTS TAB ---- */}
        {tab === 'agents' && (
          <section className="space-y-3">
            {agentError ? <div className="rounded-2xl border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200">{agentError}</div> : null}
            {agents.length === 0 ? (
              <div className="framer-card border border-dashed border-[var(--fd-hairline)] p-6 text-sm text-[#999]">
                No known agents yet. Start one to see it here.
              </div>
            ) : agents.map((agent: any) => (
              <div key={agent.id} className="overflow-hidden rounded-[var(--fd-radius-xl)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-1)]">

                {/* Agent row */}
                <div className="flex items-start justify-between gap-4 p-4">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className={`h-2.5 w-2.5 shrink-0 rounded-full shadow ${STATUS_DOT[agent.status] ?? STATUS_DOT.offline} ${agent.status === 'connected' ? 'animate-soft-pulse' : ''}`} />
                      <p className="truncate text-sm font-semibold text-white">{agent.label}</p>
                      <span className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider ${
                        agent.status === 'connected' ? 'bg-emerald-500/20 text-emerald-300' :
                        agent.status === 'stopping' ? 'bg-amber-500/20 text-amber-300' :
                        'bg-[#333] text-[#888]'
                      }`}>
                        {agent.status === 'stopping' ? (
                          <StoppingLabel agent={agent} />
                        ) : (
                          STATUS_LABEL[agent.status] ?? 'Known'
                        )}
                      </span>
                      <span className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider ${
                        (agent.modelTier || 'normal') === 'smart' ? 'bg-violet-500/20 text-violet-300' :
                        (agent.modelTier || 'normal') === 'cheap' ? 'bg-amber-500/15 text-amber-400' :
                        'border border-[var(--fd-hairline)] text-[#666]'
                      }`}>{agent.modelTier || 'normal'}</span>
                    </div>
                    <p className="framer-subtext mt-1.5 truncate text-xs">
                      {[agent.templateId && `Template: ${agent.templateId === 'none' ? 'None' : agent.templateId}`, agent.providerProfile && `Provider: ${agent.providerProfile}`, agent.projectId && `Project: ${agent.projectId}`, agent.roleHint && `Role: ${agent.roleHint}`].filter(Boolean).join(' · ') || 'No metadata'}
                    </p>
                    <p className="mt-1 text-[11px] text-[#666]">Last seen {agent.lastSeen}</p>
                  </div>
                  <div className="flex shrink-0 gap-2">
                    {agent.status === 'stopping' ? (
                      <button
                        type="button"
                        disabled
                        className="rounded-lg border border-amber-500/20 bg-amber-500/5 px-3 py-1.5 text-[11px] text-amber-500/40 cursor-not-allowed"
                      >
                        Stopping…
                      </button>
                    ) : (agent.status === 'connected' || agent.status === 'idle' || agent.status === 'starting' || agent.status === 'startup_blocked') ? (
                      <button
                        type="button"
                        data-debug-id={`agent-stop-btn-${agent.id}`}
                        onClick={() => handleStopAgent(agent)}
                        disabled={stopping === agent.id}
                        className="rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 py-1.5 text-[11px] text-amber-300 transition hover:bg-amber-500/20 disabled:opacity-40"
                      >
                        {stopping === agent.id ? 'Stopping…' : 'Stop'}
                      </button>
                    ) : (
                      <button
                        type="button"
                        data-debug-id={`agent-start-btn-${agent.id}`}
                        onClick={() => handleStartAgent(agent)}
                        disabled={starting === agent.id}
                        className="rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-3 py-1.5 text-[11px] text-emerald-300 transition hover:bg-emerald-500/20 disabled:opacity-40"
                      >
                        {starting === agent.id ? 'Starting…' : 'Start'}
                      </button>
                    )}
                    <button
                      type="button"
                      data-debug-id={`agent-edit-toggle-btn-${agent.id}`}
                      onClick={() => editingAgentId === agent.id ? cancelEditAgent() : startEditAgent(agent)}
                      className={`rounded-lg border px-3 py-1.5 text-[11px] transition ${editingAgentId === agent.id ? 'border-[var(--fd-accent-blue)]/50 bg-[var(--fd-accent-blue)]/10 text-[var(--fd-accent-blue)]' : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] text-[#ccc] hover:border-[var(--fd-accent-blue)]/50 hover:text-white'}`}
                    >
                      {editingAgentId === agent.id ? 'Cancel' : 'Edit'}
                    </button>
                    <button
                      type="button"
                      data-debug-id={`agent-archive-btn-${agent.id}`}
                      onClick={() => handleArchiveAgent(agent)}
                      disabled={archiving === agent.id}
                      className="rounded-lg border border-red-500/25 bg-red-500/10 px-3 py-1.5 text-[11px] text-red-300 transition hover:bg-red-500/20 disabled:opacity-40"
                    >
                      {archiving === agent.id ? 'Archiving…' : 'Archive'}
                    </button>
                  </div>
                </div>

                {/* Inline edit form */}
                {editingAgentId === agent.id && (
                  <AgentEditForm
                    agent={agent}
                    templates={templates}
                    saving={agentSaving}
                    error={agentFormError}
                    onSubmit={handleSaveAgent}
                    onCancel={cancelEditAgent}
                  />
                )}
              </div>
            ))}
          </section>
        )}

        {/* ---- TEMPLATES TAB ---- */}
        {tab === 'templates' && (
          <section className="space-y-4">
            {templatesError ? <div className="rounded-2xl border border-red-500/30 bg-red-500/10 p-3 text-sm text-red-200">{templatesError}</div> : null}

            {editingTemplate !== null ? (
              <TemplateEditForm
                template={editingTemplate}
                saving={templateSaving}
                error={templateFormError}
                onSubmit={handleSaveTemplate}
                onCancel={cancelTemplateEdit}
              />
            ) : (
              <button data-debug-id="template-new-btn" type="button" onClick={startNewTemplate} className="framer-pill-secondary w-full py-2.5 text-sm">
                + New template
              </button>
            )}

            {templatesLoading ? (
              <p className="text-sm text-[#666]">Loading templates…</p>
            ) : templates.length === 0 ? (
              <div className="framer-card border border-dashed border-[var(--fd-hairline)] p-6 text-sm text-[#999]">No templates found. Daemon may be using built-in defaults.</div>
            ) : templates.map((t) => (
              <div key={t.templateId} className="framer-card flex items-start justify-between gap-4 rounded-[var(--fd-radius-xl)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] p-4">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold text-white">{t.displayName}</p>
                  <p className="framer-subtext mt-1 text-xs">
                    ID: <span className="text-[#aaa]">{t.templateId}</span>
                    {t.roleHint ? <> · Role hint: <span className="text-[#aaa]">{t.roleHint}</span></> : null}
                    {t.defaultProviderProfile ? <> · Provider: <span className="text-[#aaa]">{t.defaultProviderProfile}</span></> : null}
                    {t.suggestedModelTier ? <> · Suggested Tier: <span className="text-[#aaa] capitalize">{t.suggestedModelTier}</span></> : null}
                  </p>
                  {t.persona ? <p className="mt-2 line-clamp-2 text-[11px] leading-4 text-[#888]"><b>Persona:</b> {t.persona}</p> : null}
                  {t.instructions ? <p className="mt-1 line-clamp-2 text-[11px] leading-4 text-[#666]"><b>Instructions:</b> {t.instructions}</p> : null}
                </div>
                <div className="flex shrink-0 gap-2">
                  <button
                    type="button"
                    data-debug-id={`template-edit-btn-${t.templateId}`}
                    onClick={() => startEditTemplate(t)}
                    className="rounded-lg border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-3 py-1.5 text-[11px] text-[#ccc] transition hover:border-[var(--fd-accent-blue)]/50 hover:text-white"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    data-debug-id={`template-archive-btn-${t.templateId}`}
                    onClick={() => handleArchiveTemplate(t.templateId, t.displayName)}
                    className="rounded-lg border border-red-500/25 bg-red-500/10 px-3 py-1.5 text-[11px] text-red-300 transition hover:bg-red-500/20"
                  >
                    Archive
                  </button>
                </div>
              </div>
            ))}
          </section>
        )}

        {/* ---- TEST PROVIDERS TAB ---- */}
        {tab === 'test' && (
          <section className="space-y-4">
            {/* Launch form */}
            <div className="framer-card rounded-[var(--fd-radius-xl)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] p-4 space-y-3">
              <p className="text-xs font-semibold uppercase tracking-[0.14em] text-[#777]">Run provider test</p>

              <div className="flex flex-wrap items-end gap-3">
                <label className="flex flex-col gap-1">
                  <span className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#666]">Provider</span>
                  <select
                    data-debug-id="test-provider-select"
                    value={testProvider}
                    onChange={(e) => setTestProvider(e.target.value)}
                    className="framer-input px-3 py-1.5 text-sm"
                  >
                    {testProviders.length === 0 && <option value="">—</option>}
                    {testProviders.map((p) => <option key={p} value={p}>{p}</option>)}
                  </select>
                </label>

                <div className="flex flex-col gap-1">
                  <span className="text-[10px] font-semibold uppercase tracking-[0.14em] text-[#666]">Tier</span>
                  <div className="flex gap-1">
                    {(['cheap', 'normal', 'smart'] as const).map((tier) => (
                      <button
                        key={tier}
                        type="button"
                        data-debug-id={`test-tier-btn-${tier}`}
                        onClick={() => setTestTier(tier)}
                        className={`rounded-lg border px-3 py-1.5 text-[11px] font-semibold transition ${
                          testTier === tier
                            ? tier === 'smart' ? 'border-violet-500/50 bg-violet-500/20 text-violet-200'
                              : tier === 'cheap' ? 'border-amber-500/50 bg-amber-500/20 text-amber-200'
                              : 'border-sky-500/50 bg-sky-500/20 text-sky-200'
                            : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] text-[#888] hover:text-white'
                        }`}
                      >
                        {tier}
                      </button>
                    ))}
                  </div>
                </div>

                <button
                  type="button"
                  data-debug-id="test-run-btn"
                  onClick={handleRunTest}
                  disabled={testLaunching || !testProvider}
                  className="framer-pill disabled:opacity-40"
                >
                  {testLaunching ? 'Launching…' : 'Run test'}
                </button>
              </div>

              {testError && <p className="text-xs text-red-300">{testError}</p>}
            </div>

            {/* Live run list */}
            {testRuns.length === 0 ? (
              <div className="framer-card border border-dashed border-[var(--fd-hairline)] p-6 text-sm text-[#999]">
                No test runs yet. Launch one above.
              </div>
            ) : testRuns.map((run: any) => {
              const terminal = run.status === 'success' || run.status === 'failed' || run.status === 'timed_out';
              const dotCls = run.status === 'success' ? 'bg-emerald-400' : run.status === 'failed' || run.status === 'timed_out' ? 'bg-red-400' : 'bg-sky-400 animate-soft-pulse';
              const elapsedSec = run.elapsedMs ? (run.elapsedMs / 1000).toFixed(1) + 's' : null;
              return (
                <div key={run.testRunId} className="rounded-[var(--fd-radius-xl)] border border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] p-4 space-y-1.5">
                  <div className="flex items-center gap-2">
                    <span className={`h-2 w-2 shrink-0 rounded-full shadow ${dotCls}`} />
                    <span className="text-sm font-semibold text-white">{run.provider}</span>
                    <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider ${
                      run.tier === 'smart' ? 'bg-violet-500/20 text-violet-300' :
                      run.tier === 'cheap' ? 'bg-amber-500/15 text-amber-400' :
                      'border border-[var(--fd-hairline)] text-[#666]'
                    }`}>{run.tier}</span>
                    <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider ${
                      run.status === 'success' ? 'bg-emerald-500/20 text-emerald-300' :
                      run.status === 'failed' || run.status === 'timed_out' ? 'bg-red-500/20 text-red-300' :
                      'bg-sky-500/15 text-sky-300'
                    }`}>{run.status}</span>
                    {elapsedSec && <span className="text-[11px] text-[#666]">{elapsedSec}</span>}
                  </div>
                  <p className="text-[11px] text-[#666]">{run.testRunId}{run.resolvedModel ? ` · ${run.resolvedModel}` : ''}{run.reason ? ` · ${run.reason}` : ''}</p>
                  {terminal && run.paneTail && (
                    <pre className="mt-1 max-h-24 overflow-y-auto rounded-lg bg-[#111] px-3 py-2 text-[10px] leading-4 text-[#aaa] whitespace-pre-wrap">{run.paneTail}</pre>
                  )}
                </div>
              );
            })}
          </section>
        )}
      </div>
    </main>
  );
}

// --- OPTIMIZED SUB-COMPONENTS FOR FORM STATE ISOLATION ---

interface AgentEditFormProps {
  agent: any;
  templates: any[];
  saving: boolean;
  error: string;
  onSubmit: (formData: any) => void;
  onCancel: () => void;
}

function AgentEditForm({
  agent,
  templates,
  saving,
  error,
  onSubmit,
  onCancel
}: AgentEditFormProps) {
  console.log('[Render] AgentEditForm', agent.id);
  const [form, setForm] = useState({
    displayName: agent.label || '',
    templateId: agent.templateId || 'none',
    providerProfile: agent.providerProfile || '',
    modelTier: (agent.modelTier || 'normal') as 'cheap' | 'normal' | 'smart',
  });

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    onSubmit(form);
  };

  return (
    <form
      onSubmit={handleSubmit}
      className="border-t border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-4 pb-4 pt-3"
    >
      {error ? <div className="mb-3 rounded-xl border border-red-500/30 bg-red-500/10 p-2.5 text-xs text-red-200">{error}</div> : null}
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <label className="block">
          <span className="framer-topline text-[10px]">Display name <span className="text-red-400">*</span></span>
          <input
            data-debug-id="agent-edit-display-name"
            value={form.displayName}
            onChange={(e) => setForm((f) => ({ ...f, displayName: e.target.value }))}
            className="framer-input mt-1.5 w-full px-3 py-2 text-sm"
            placeholder="e.g. odin-coder"
          />
        </label>
        <label className="block">
          <span className="framer-topline text-[10px]">Template</span>
          <select
            data-debug-id="agent-edit-template-select"
            value={form.templateId}
            onChange={(e) => setForm((f) => ({ ...f, templateId: e.target.value }))}
            className="framer-input mt-1.5 w-full px-3 py-2 text-sm"
          >
            <option value="none">— no template —</option>
            {templates.map((t) => (
              <option key={t.templateId} value={t.templateId}>{t.displayName}</option>
            ))}
          </select>
        </label>
        <label className="block">
          <span className="framer-topline text-[10px]">Provider profile</span>
          <input
            data-debug-id="agent-edit-provider"
            value={form.providerProfile}
            onChange={(e) => setForm((f) => ({ ...f, providerProfile: e.target.value }))}
            className="framer-input mt-1.5 w-full px-3 py-2 text-sm"
            placeholder="e.g. pi, claude"
          />
        </label>
      </div>
      <div className="mt-3">
        <span className="framer-topline text-[10px]">Model tier</span>
        <div className="mt-1.5 flex gap-2">
          {(['cheap', 'normal', 'smart'] as const).map((tier) => (
            <label key={tier} data-debug-id={`agent-edit-model-tier-${tier}`} className={`flex flex-1 cursor-pointer items-center justify-center gap-1.5 rounded-xl border px-2 py-2 text-xs transition ${form.modelTier === tier ? 'border-[var(--fd-accent-blue)]/60 bg-[var(--fd-accent-blue)]/10 text-white' : 'border-[var(--fd-hairline)] text-[#888] hover:text-[#ccc]'}`}>
              <input type="radio" name="editModelTier" value={tier} checked={form.modelTier === tier} onChange={() => setForm((f) => ({ ...f, modelTier: tier }))} className="sr-only" />
              <span className="font-semibold capitalize">{tier}</span>
            </label>
          ))}
        </div>
        <p className="mt-1 text-[11px] text-[#666]">Takes effect on next start.</p>
      </div>
      <div className="mt-3 flex justify-end gap-2">
        <button type="button" data-debug-id="agent-edit-cancel-btn" onClick={onCancel} className="framer-pill-secondary text-xs">Cancel</button>
        <button type="submit" data-debug-id="agent-edit-save-btn" disabled={saving} className="framer-pill text-xs">
          {saving ? 'Saving…' : 'Save changes'}
        </button>
      </div>
    </form>
  );
}

interface TemplateEditFormProps {
  template: any;
  saving: boolean;
  error: string;
  onSubmit: (formData: any) => void;
  onCancel: () => void;
}

function TemplateEditForm({
  template,
  saving,
  error,
  onSubmit,
  onCancel
}: TemplateEditFormProps) {
  console.log('[Render] TemplateEditForm', template.templateId || 'new');
  const [form, setForm] = useState({
    templateId: template.templateId || '',
    displayName: template.displayName || '',
    roleHint: template.roleHint || '',
    defaultProviderProfile: template.defaultProviderProfile || '',
    persona: template.persona || '',
    instructions: template.instructions || '',
    suggestedModelTier: template.suggestedModelTier || 'normal',
  });

  const isNew = !template.templateId;

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    onSubmit(form);
  };

  return (
    <form onSubmit={handleSubmit} className="framer-card space-y-4 rounded-[var(--fd-radius-xl)] border border-[var(--fd-accent-blue)]/30 bg-[var(--fd-surface-1)] p-5">
      <h3 className="text-base font-semibold text-white">{isNew ? 'New template' : `Edit: ${form.displayName}`}</h3>
      {error ? <div className="rounded-xl border border-red-500/30 bg-red-500/10 p-2.5 text-xs text-red-200">{error}</div> : null}
      {isNew && (
        <label className="block">
          <span className="framer-topline text-[10px]">Template ID <span className="text-red-400">*</span></span>
          <input data-debug-id="template-form-id" value={form.templateId} onChange={(e) => setForm((f) => ({ ...f, templateId: e.target.value }))} placeholder="e.g. coder" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
          <p className="mt-1 text-[11px] text-[#777]">Stable identifier — cannot be changed after creation.</p>
        </label>
      )}
      <label className="block">
        <span className="framer-topline text-[10px]">Display name <span className="text-red-400">*</span></span>
        <input data-debug-id="template-form-display-name" value={form.displayName} onChange={(e) => setForm((f) => ({ ...f, displayName: e.target.value }))} placeholder="e.g. Coding agent" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
      </label>
      <label className="block">
        <span className="framer-topline text-[10px]">Role hint</span>
        <input data-debug-id="template-form-role-hint" value={form.roleHint} onChange={(e) => setForm((f) => ({ ...f, roleHint: e.target.value }))} placeholder="e.g. coder, reviewer, coordinator" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
        <p className="mt-1 text-[11px] text-[#777]">Internal routing metadata — not shown as a required picker.</p>
      </label>
      <label className="block">
        <span className="framer-topline text-[10px]">Default provider profile</span>
        <input data-debug-id="template-form-provider" value={form.defaultProviderProfile} onChange={(e) => setForm((f) => ({ ...f, defaultProviderProfile: e.target.value }))} placeholder="e.g. pi, claude" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
      </label>
      <label className="block">
        <span className="framer-topline text-[10px]">Suggested model tier</span>
        <select
          data-debug-id="template-form-model-tier"
          value={form.suggestedModelTier}
          onChange={(e) => setForm((f) => ({ ...f, suggestedModelTier: e.target.value }))}
          className="framer-input mt-1.5 w-full bg-[var(--fd-surface-2)] px-3 py-2 text-sm text-white"
        >
          <option value="cheap">Cheap (e.g. Gemini Flash Lite)</option>
          <option value="normal">Normal (e.g. Gemini Flash)</option>
          <option value="smart">Smart (e.g. Gemini Pro)</option>
        </select>
      </label>
      <label className="block">
        <span className="framer-topline text-[10px]">Persona</span>
        <textarea data-debug-id="template-form-persona" value={form.persona} onChange={(e) => setForm((f) => ({ ...f, persona: e.target.value }))} rows={3} placeholder="Describe the agent's persona and behavioral style..." className="framer-input mt-1.5 w-full resize-none px-3 py-2 text-sm" />
      </label>
      <label className="block">
        <span className="framer-topline text-[10px]">Instructions</span>
        <textarea data-debug-id="template-form-instructions" value={form.instructions} onChange={(e) => setForm((f) => ({ ...f, instructions: e.target.value }))} rows={3} placeholder="Provide step-by-step operating guidelines or starter prompts..." className="framer-input mt-1.5 w-full resize-none px-3 py-2 text-sm" />
      </label>
      <div className="flex justify-end gap-2">
        <button type="button" data-debug-id="template-form-cancel-btn" onClick={onCancel} className="framer-pill-secondary">Cancel</button>
        <button data-debug-id="template-form-submit" type="submit" disabled={saving} className="framer-pill">{saving ? 'Saving…' : 'Save template'}</button>
      </div>
    </form>
  );
}
