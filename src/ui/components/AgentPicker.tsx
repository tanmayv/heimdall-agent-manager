import { useMemo, useState } from 'react';
import * as daemonApi from '../api/daemonApi';

type AgentPickerProps = {
  debugId: string;
  daemonUrl: string;
  agents: any[];
  projects: any[];
  templates?: any[];
  providers?: any[];
  value?: string;
  roleHint?: string;
  defaultProjectId?: string;
  onSelected: (agentInstanceId: string, result?: any) => void | Promise<void>;
  onRefreshAgents?: () => void | Promise<void>;
  selectionOnly?: boolean;
};

function agentId(agent: any): string {
  return agent?.id || agent?.agentInstanceId || agent?.agent_instance_id || '';
}

function agentLabel(agent: any): string {
  return agent?.label || agent?.displayName || agent?.display_name || agentId(agent);
}

function agentTemplate(agent: any): string {
  return agent?.templateId || agent?.template_id || agent?.agentRole || agent?.agent_role || agent?.roleHint || agent?.role_hint || '';
}

function roleMatches(agent: any, roleHint: string) {
  if (!roleHint) return true;
  const hint = roleHint.toLowerCase();
  const haystack = [agentId(agent), agentLabel(agent), agentTemplate(agent), agent?.agentRole || agent?.agent_role || '', agent?.providerProfile || agent?.provider_profile || ''].join(' ').toLowerCase();
  if (hint === 'coder') return haystack.includes('coder') || haystack.includes('code') || haystack.includes('implement');
  if (hint === 'reviewer') return haystack.includes('review') || haystack.includes('verify') || haystack.includes('test');
  if (hint === 'coordinator') return haystack.includes('coord') || haystack.includes('lead') || haystack.includes('principal');
  return haystack.includes(hint);
}

function templateDefault(templates: any[], roleHint: string) {
  if (!roleHint) return templates[0]?.template_id || templates[0]?.templateId || 'coder';
  const hint = roleHint.toLowerCase();
  const found = templates.find((template: any) => {
    const id = String(template.template_id || template.templateId || '').toLowerCase();
    const role = String(template.role_hint || template.roleHint || '').toLowerCase();
    const label = String(template.display_name || template.displayName || '').toLowerCase();
    return id.includes(hint) || role.includes(hint) || label.includes(hint);
  });
  if (found) return found.template_id || found.templateId;
  if (hint === 'coordinator') return 'coordinator';
  if (hint === 'reviewer') return 'reviewer';
  return 'coder';
}

function providerDefault(providers: any[]) {
  return providers[0]?.name || 'pi';
}

function statusLabel(agent: any) {
  const connection = String(agent?.connectionState || agent?.connection_state || '').toLowerCase();
  const live = Boolean(agent?.connected) || connection === 'connected';
  const status = live ? 'live' : 'offline';
  const task = agent?.currentTaskId ? ` · task ${agent.currentTaskId}` : '';
  return `${status}${task}`;
}

function searchMatches(agent: any, query: string) {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  const haystack = [
    agentId(agent),
    agentLabel(agent),
    agentTemplate(agent),
    agent?.agentRole || agent?.agent_role || '',
    agent?.providerProfile || agent?.provider_profile || '',
    agent?.projectId || agent?.project_id || '',
    statusLabel(agent),
  ].join(' ').toLowerCase();
  return haystack.includes(q);
}

export default function AgentPicker({ debugId, daemonUrl, agents, projects, templates = [], providers = [], value = '', roleHint = '', defaultProjectId = '', onSelected, onRefreshAgents, selectionOnly = false }: AgentPickerProps) {
  const [query, setQuery] = useState('');
  const filteredAgents = useMemo(() => (agents || []).filter((agent) => agentId(agent) && roleMatches(agent, roleHint) && searchMatches(agent, query)), [agents, roleHint, query]);
  const fallbackTemplate = templateDefault(templates, roleHint);
  const fallbackProvider = providerDefault(providers);
  const [existingId, setExistingId] = useState(value || filteredAgents[0]?.id || '');
  const [runId, setRunId] = useState('');
  const [runTemplate, setRunTemplate] = useState(fallbackTemplate);
  const [runProvider, setRunProvider] = useState(fallbackProvider);
  const [runProject, setRunProject] = useState(defaultProjectId || '');
  const [runTier, setRunTier] = useState('normal');
  const [createId, setCreateId] = useState('');
  const [createName, setCreateName] = useState('');
  const [createTemplate, setCreateTemplate] = useState(fallbackTemplate);
  const [createProvider, setCreateProvider] = useState(fallbackProvider);
  const [createProject, setCreateProject] = useState(defaultProjectId || '');
  const [createTier, setCreateTier] = useState('normal');
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');

  async function refresh() {
    if (onRefreshAgents) await onRefreshAgents();
  }

  async function runAgent(agentInstanceId: string, templateId: string, provider: string, projectId: string, modelTier: string) {
    const trimmed = agentInstanceId.trim();
    if (!trimmed) return;
    setBusy(`run-${trimmed}`);
    setError('');
    try {
      const result = await daemonApi.startAgent({ daemonUrl, agentInstanceId: trimmed, provider, templateId, projectId, modelTier, agentRole: templateId });
      await refresh();
      await onSelected(trimmed, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to run agent');
    } finally {
      setBusy('');
    }
  }

  async function createAndRun() {
    const trimmed = createId.trim();
    if (!trimmed) return;
    setBusy(`create-${trimmed}`);
    setError('');
    try {
      await daemonApi.createAgent({ daemonUrl, agentInstanceId: trimmed, displayName: createName.trim() || trimmed, providerProfile: createProvider, templateId: createTemplate, projectId: createProject, modelTier: createTier, agentRole: createTemplate });
      const result = await daemonApi.startAgent({ daemonUrl, agentInstanceId: trimmed, provider: createProvider, templateId: createTemplate, projectId: createProject, displayName: createName.trim() || trimmed, modelTier: createTier, agentRole: createTemplate });
      await refresh();
      await onSelected(trimmed, result);
    } catch (err: any) {
      setError(err?.message || 'Unable to create agent');
    } finally {
      setBusy('');
    }
  }

  const projectOptions = projects || [];
  const templateOptions = templates.length ? templates : [{ template_id: fallbackTemplate, display_name: fallbackTemplate }];
  const providerOptions = providers.length ? providers : [{ name: fallbackProvider }];

  return (
    <div data-debug-id={debugId} className="rounded-xl border border-white/10 bg-black/20 p-3 text-sm">
      <div className="flex items-center justify-between gap-3">
        <div>
          <div className="font-medium text-zinc-100">Agent picker</div>
          {roleHint && <div className="text-xs text-zinc-500">Filter: {roleHint}</div>}
        </div>
        {value && <div className="max-w-[220px] truncate rounded-full bg-white/5 px-2 py-1 text-xs text-zinc-400">Selected {value}</div>}
      </div>

      <input
        data-debug-id={`${debugId}-search-input`}
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder="Search agents by name, id, role, project, live/offline…"
        className="mt-3 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"
      />

      <div className="mt-3 grid min-w-0 gap-2 md:grid-cols-[minmax(0,1fr)_auto_auto]">
        <select data-debug-id={`${debugId}-existing-select`} value={existingId} onChange={(event) => setExistingId(event.target.value)} className="min-w-0 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">
          {filteredAgents.length === 0 && <option value="">No matching existing agents</option>}
          {filteredAgents.map((agent: any) => {
            const id = agentId(agent);
            const bits = [`[${statusLabel(agent).startsWith('live') ? 'LIVE' : 'OFFLINE'}]`, agentLabel(agent), agentTemplate(agent), agent.projectId ? `home ${agent.projectId}` : 'no project', statusLabel(agent)].filter(Boolean).join(' · ');
            return <option key={id} value={id}>{bits}</option>;
          })}
        </select>
        <button data-debug-id={`${debugId}-use-existing-btn`} disabled={!existingId || Boolean(busy)} onClick={() => onSelected(existingId)} className="rounded-xl bg-white/10 px-3 py-2 text-xs font-semibold text-zinc-100 hover:bg-white/15 disabled:opacity-50">Use selected</button>
        {!selectionOnly && <button data-debug-id={`${debugId}-run-existing-btn`} disabled={!existingId || Boolean(busy)} onClick={() => {
          const selected = filteredAgents.find((agent) => agentId(agent) === existingId) || {};
          runAgent(existingId, agentTemplate(selected) || fallbackTemplate, selected.providerProfile || fallbackProvider, selected.projectId || defaultProjectId || '', selected.modelTier || 'normal');
        }} className="rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-50">Run selected</button>}
      </div>

      {!selectionOnly && <details className="mt-3 rounded-xl bg-white/[0.035] p-3">
        <summary data-debug-id={`${debugId}-run-by-id-summary`} className="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-400">Run agent by ID</summary>
        <div className="mt-3 grid gap-2 md:grid-cols-2">
          <input data-debug-id={`${debugId}-run-id-input`} value={runId} onChange={(event) => setRunId(event.target.value)} placeholder="agent-instance-id" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <select data-debug-id={`${debugId}-run-template-select`} value={runTemplate} onChange={(event) => setRunTemplate(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{templateOptions.map((t: any) => <option key={t.template_id || t.templateId} value={t.template_id || t.templateId}>{t.display_name || t.displayName || t.template_id || t.templateId}</option>)}</select>
          <select data-debug-id={`${debugId}-run-provider-select`} value={runProvider} onChange={(event) => setRunProvider(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providerOptions.map((p: any) => <option key={p.name} value={p.name}>{p.name}</option>)}</select>
          <select data-debug-id={`${debugId}-run-project-select`} value={runProject} onChange={(event) => setRunProject(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">No project</option>{projectOptions.map((p: any) => <option key={p.projectId || p.project_id} value={p.projectId || p.project_id}>{p.name || p.projectId || p.project_id}</option>)}</select>
          <select data-debug-id={`${debugId}-run-tier-select`} value={runTier} onChange={(event) => setRunTier(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="normal">normal</option><option value="smart">smart</option><option value="cheap">cheap</option></select>
          <button data-debug-id={`${debugId}-run-submit-btn`} disabled={!runId.trim() || Boolean(busy)} onClick={() => runAgent(runId, runTemplate, runProvider, runProject, runTier)} className="rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300 disabled:opacity-50">Run agent</button>
        </div>
      </details>}

      {!selectionOnly && <details className="mt-3 rounded-xl bg-white/[0.035] p-3">
        <summary data-debug-id={`${debugId}-create-summary`} className="cursor-pointer text-xs font-semibold uppercase tracking-wide text-zinc-400">Create new agent ID and run</summary>
        <div className="mt-3 grid gap-2 md:grid-cols-2">
          <input data-debug-id={`${debugId}-create-id-input`} value={createId} onChange={(event) => setCreateId(event.target.value)} placeholder="new-agent-id" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <input data-debug-id={`${debugId}-create-name-input`} value={createName} onChange={(event) => setCreateName(event.target.value)} placeholder="Display name (optional)" className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <select data-debug-id={`${debugId}-create-template-select`} value={createTemplate} onChange={(event) => setCreateTemplate(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{templateOptions.map((t: any) => <option key={t.template_id || t.templateId} value={t.template_id || t.templateId}>{t.display_name || t.displayName || t.template_id || t.templateId}</option>)}</select>
          <select data-debug-id={`${debugId}-create-provider-select`} value={createProvider} onChange={(event) => setCreateProvider(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400">{providerOptions.map((p: any) => <option key={p.name} value={p.name}>{p.name}</option>)}</select>
          <select data-debug-id={`${debugId}-create-project-select`} value={createProject} onChange={(event) => setCreateProject(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="">No project</option>{projectOptions.map((p: any) => <option key={p.projectId || p.project_id} value={p.projectId || p.project_id}>{p.name || p.projectId || p.project_id}</option>)}</select>
          <select data-debug-id={`${debugId}-create-tier-select`} value={createTier} onChange={(event) => setCreateTier(event.target.value)} className="rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400"><option value="normal">normal</option><option value="smart">smart</option><option value="cheap">cheap</option></select>
          <button data-debug-id={`${debugId}-create-submit-btn`} disabled={!createId.trim() || Boolean(busy)} onClick={createAndRun} className="rounded-xl bg-emerald-400 px-3 py-2 text-xs font-semibold text-black hover:bg-emerald-300 disabled:opacity-50">Create and run</button>
        </div>
      </details>}

      {busy && <div data-debug-id={`${debugId}-busy`} className="mt-2 text-xs text-sky-300">Working…</div>}
      {error && <div data-debug-id={`${debugId}-error`} className="mt-2 rounded-lg border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{error}</div>}
    </div>
  );
}
