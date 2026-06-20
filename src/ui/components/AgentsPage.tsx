import { useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { refreshAgents } from '../store/chatSlice';
import * as daemonApi from '../api/daemonApi';

const STATUS_DOT: Record<string, string> = {
  connected: 'bg-emerald-400 shadow-emerald-400/40',
  starting: 'bg-sky-400 shadow-sky-400/40',
  startup_blocked: 'bg-amber-400 shadow-amber-400/40',
  startup_failed: 'bg-red-400 shadow-red-400/40',
  offline: 'bg-[#555]/70',
};

const STATUS_LABEL: Record<string, string> = {
  connected: 'Live',
  starting: 'Starting',
  startup_blocked: 'Blocked',
  startup_failed: 'Failed',
  offline: 'Known',
};

function normalizeTemplate(t: any) {
  return {
    templateId: t.template_id || t.templateId || '',
    displayName: t.display_name || t.displayName || t.template_id || '',
    roleHint: t.role_hint || t.roleHint || '',
    defaultProviderProfile: t.default_provider_profile || t.defaultProviderProfile || '',
    persona: t.persona || t.instructions || t.description || '',
  };
}

const blankTemplate = { templateId: '', displayName: '', roleHint: '', defaultProviderProfile: '', persona: '' };

export default function AgentsPage({ session, onOpenStartAgent }: { session: any; onOpenStartAgent: () => void }) {
  const dispatch = useDispatch<any>();
  const agents = useSelector((state: any) => state.chat.agents);

  const [tab, setTab] = useState<'agents' | 'templates'>('agents');

  // --- Known Agents state ---
  const [archiving, setArchiving] = useState<string | null>(null);
  const [agentError, setAgentError] = useState('');
  const [editingAgentId, setEditingAgentId] = useState<string | null>(null);
  const [agentForm, setAgentForm] = useState({ displayName: '', templateId: '', providerProfile: '' });
  const [agentSaving, setAgentSaving] = useState(false);
  const [agentFormError, setAgentFormError] = useState('');

  // --- Templates state ---
  const [templates, setTemplates] = useState<any[]>([]);
  const [templatesLoading, setTemplatesLoading] = useState(false);
  const [templatesError, setTemplatesError] = useState('');
  const [editingTemplate, setEditingTemplate] = useState<any | null>(null);
  const [templateForm, setTemplateForm] = useState({ ...blankTemplate });
  const [templateSaving, setTemplateSaving] = useState(false);
  const [templateFormError, setTemplateFormError] = useState('');

  // Load templates on mount (needed for agent edit dropdown too)
  useEffect(() => {
    loadTemplates();
  }, [session.daemonUrl]);

  async function loadTemplates() {
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
  }

  // ---- Agent actions ----

  function startEditAgent(agent: any) {
    setEditingAgentId(agent.id);
    setAgentForm({ displayName: agent.label || '', templateId: agent.templateId || '', providerProfile: agent.providerProfile || '' });
    setAgentFormError('');
  }

  function cancelEditAgent() {
    setEditingAgentId(null);
    setAgentFormError('');
  }

  async function handleSaveAgent(event: any) {
    event.preventDefault();
    const name = agentForm.displayName.trim();
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
        templateId: agentForm.templateId || undefined,
        providerProfile: agentForm.providerProfile || undefined,
      });
      setEditingAgentId(null);
      dispatch(refreshAgents());
    } catch (err: any) {
      setAgentFormError(err?.message || 'Failed to update agent');
    } finally {
      setAgentSaving(false);
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
    setTemplateForm({ ...template });
    setTemplateFormError('');
  }

  function startNewTemplate() {
    setEditingTemplate({});
    setTemplateForm({ ...blankTemplate });
    setTemplateFormError('');
  }

  function cancelTemplateEdit() {
    setEditingTemplate(null);
    setTemplateFormError('');
  }

  async function handleSaveTemplate(event: any) {
    event.preventDefault();
    const name = templateForm.displayName.trim();
    const id = templateForm.templateId.trim();
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
          role_hint: templateForm.roleHint.trim(),
          default_provider_profile: templateForm.defaultProviderProfile.trim(),
          persona: templateForm.persona.trim(),
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
  }

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
    <main className="flex min-w-0 flex-1 flex-col bg-[var(--fd-canvas)]">
      <header className="framer-panel flex items-center justify-between border-b border-[var(--fd-hairline)] px-6 py-4">
        <div>
          <p className="framer-topline tracking-[0.28em]">Heimdall</p>
          <h2 className="mt-1 text-2xl font-bold text-white">Agents</h2>
        </div>
        <button type="button" onClick={onOpenStartAgent} className="framer-pill">
          + Start agent
        </button>
      </header>

      <div className="flex gap-1 border-b border-[var(--fd-hairline)] px-6 pt-3">
        {(['agents', 'templates'] as const).map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => setTab(t)}
            className={`rounded-t-lg border border-b-0 px-4 py-2 text-xs font-semibold uppercase tracking-[0.14em] transition ${
              tab === t
                ? 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] text-white'
                : 'border-transparent text-[#777] hover:text-white'
            }`}
          >
            {t === 'agents' ? 'Known Agents' : 'Templates'}
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
                      <span className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider ${agent.status === 'connected' ? 'bg-emerald-500/20 text-emerald-300' : 'bg-[#333] text-[#888]'}`}>
                        {STATUS_LABEL[agent.status] ?? 'Known'}
                      </span>
                    </div>
                    <p className="framer-subtext mt-1.5 truncate text-xs">
                      {[agent.templateId && `Template: ${agent.templateId}`, agent.providerProfile && `Provider: ${agent.providerProfile}`, agent.projectId && `Project: ${agent.projectId}`, agent.roleHint && `Role: ${agent.roleHint}`].filter(Boolean).join(' · ') || 'No metadata'}
                    </p>
                    <p className="mt-1 text-[11px] text-[#666]">Last seen {agent.lastSeen}</p>
                  </div>
                  <div className="flex shrink-0 gap-2">
                    <button
                      type="button"
                      onClick={() => editingAgentId === agent.id ? cancelEditAgent() : startEditAgent(agent)}
                      className={`rounded-lg border px-3 py-1.5 text-[11px] transition ${editingAgentId === agent.id ? 'border-[var(--fd-accent-blue)]/50 bg-[var(--fd-accent-blue)]/10 text-[var(--fd-accent-blue)]' : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] text-[#ccc] hover:border-[var(--fd-accent-blue)]/50 hover:text-white'}`}
                    >
                      {editingAgentId === agent.id ? 'Cancel' : 'Edit'}
                    </button>
                    <button
                      type="button"
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
                  <form
                    onSubmit={handleSaveAgent}
                    className="border-t border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-4 pb-4 pt-3"
                  >
                    {agentFormError ? <div className="mb-3 rounded-xl border border-red-500/30 bg-red-500/10 p-2.5 text-xs text-red-200">{agentFormError}</div> : null}
                    <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                      <label className="block">
                        <span className="framer-topline text-[10px]">Display name <span className="text-red-400">*</span></span>
                        <input
                          value={agentForm.displayName}
                          onChange={(e) => setAgentForm((f) => ({ ...f, displayName: e.target.value }))}
                          className="framer-input mt-1.5 w-full px-3 py-2 text-sm"
                          placeholder="e.g. odin-coder"
                        />
                      </label>
                      <label className="block">
                        <span className="framer-topline text-[10px]">Template</span>
                        <select
                          value={agentForm.templateId}
                          onChange={(e) => setAgentForm((f) => ({ ...f, templateId: e.target.value }))}
                          className="framer-input mt-1.5 w-full px-3 py-2 text-sm"
                        >
                          <option value="">— no template —</option>
                          {templates.map((t) => (
                            <option key={t.templateId} value={t.templateId}>{t.displayName}</option>
                          ))}
                        </select>
                      </label>
                      <label className="block">
                        <span className="framer-topline text-[10px]">Provider profile</span>
                        <input
                          value={agentForm.providerProfile}
                          onChange={(e) => setAgentForm((f) => ({ ...f, providerProfile: e.target.value }))}
                          className="framer-input mt-1.5 w-full px-3 py-2 text-sm"
                          placeholder="e.g. pi, claude"
                        />
                      </label>
                    </div>
                    <div className="mt-3 flex justify-end gap-2">
                      <button type="button" onClick={cancelEditAgent} className="framer-pill-secondary text-xs">Cancel</button>
                      <button type="submit" disabled={agentSaving} className="framer-pill text-xs">
                        {agentSaving ? 'Saving…' : 'Save changes'}
                      </button>
                    </div>
                  </form>
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
              <form onSubmit={handleSaveTemplate} className="framer-card space-y-4 rounded-[var(--fd-radius-xl)] border border-[var(--fd-accent-blue)]/30 bg-[var(--fd-surface-1)] p-5">
                <h3 className="text-base font-semibold text-white">{editingTemplate.templateId ? `Edit: ${editingTemplate.displayName}` : 'New template'}</h3>
                {templateFormError ? <div className="rounded-xl border border-red-500/30 bg-red-500/10 p-2.5 text-xs text-red-200">{templateFormError}</div> : null}
                {!editingTemplate.templateId && (
                  <label className="block">
                    <span className="framer-topline text-[10px]">Template ID <span className="text-red-400">*</span></span>
                    <input value={templateForm.templateId} onChange={(e) => setTemplateForm((f) => ({ ...f, templateId: e.target.value }))} placeholder="e.g. coder" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
                    <p className="mt-1 text-[11px] text-[#777]">Stable identifier — cannot be changed after creation.</p>
                  </label>
                )}
                <label className="block">
                  <span className="framer-topline text-[10px]">Display name <span className="text-red-400">*</span></span>
                  <input value={templateForm.displayName} onChange={(e) => setTemplateForm((f) => ({ ...f, displayName: e.target.value }))} placeholder="e.g. Coding agent" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
                </label>
                <label className="block">
                  <span className="framer-topline text-[10px]">Role hint</span>
                  <input value={templateForm.roleHint} onChange={(e) => setTemplateForm((f) => ({ ...f, roleHint: e.target.value }))} placeholder="e.g. coder, reviewer, coordinator" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
                  <p className="mt-1 text-[11px] text-[#777]">Internal routing metadata — not shown as a required picker.</p>
                </label>
                <label className="block">
                  <span className="framer-topline text-[10px]">Default provider profile</span>
                  <input value={templateForm.defaultProviderProfile} onChange={(e) => setTemplateForm((f) => ({ ...f, defaultProviderProfile: e.target.value }))} placeholder="e.g. pi, claude" className="framer-input mt-1.5 w-full px-3 py-2 text-sm" />
                </label>
                <label className="block">
                  <span className="framer-topline text-[10px]">Persona / instructions</span>
                  <textarea value={templateForm.persona} onChange={(e) => setTemplateForm((f) => ({ ...f, persona: e.target.value }))} rows={3} placeholder="Describe the agent's persona and behaviour…" className="framer-input mt-1.5 w-full resize-none px-3 py-2 text-sm" />
                </label>
                <div className="flex justify-end gap-2">
                  <button type="button" onClick={cancelTemplateEdit} className="framer-pill-secondary">Cancel</button>
                  <button type="submit" disabled={templateSaving} className="framer-pill">{templateSaving ? 'Saving…' : 'Save template'}</button>
                </div>
              </form>
            ) : (
              <button type="button" onClick={startNewTemplate} className="framer-pill-secondary w-full py-2.5 text-sm">
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
                  </p>
                  {t.persona ? <p className="mt-2 line-clamp-2 text-[11px] leading-4 text-[#777]">{t.persona}</p> : null}
                </div>
                <div className="flex shrink-0 gap-2">
                  <button
                    type="button"
                    onClick={() => startEditTemplate(t)}
                    className="rounded-lg border border-[var(--fd-hairline)] bg-[var(--fd-surface-2)] px-3 py-1.5 text-[11px] text-[#ccc] transition hover:border-[var(--fd-accent-blue)]/50 hover:text-white"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
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
      </div>
    </main>
  );
}
