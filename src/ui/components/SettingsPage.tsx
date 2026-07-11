import { useEffect, useMemo, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import SessionConfig from './SessionConfig';
import { fetchPreferences, fetchSelectedChat, refreshSettingsCatalog, selectAgent, sendMessageToSelectedAgent } from '../store/chatSlice';
import { refreshMemory } from '../store/memorySlice';

const SETTINGS_ITEMS = [
  { key: 'templates', label: 'Agent templates' },
  { key: 'kinds', label: 'Team kinds' },
  { key: 'providers', label: 'Providers & model tiers' },
  { key: 'memory', label: 'Memory browser' },
  { key: 'agents', label: 'Agents (raw registry)' },
  { key: 'direct-chat', label: 'Direct agent chat (debug)' },
  { key: 'daemon', label: 'Daemon connection' },
];

const TEAM_KINDS = [
  { key: 'coding', label: 'Coding', vcs: 'default on', scaffolds: ['feature', 'bugfix', 'refactor'] },
  { key: 'research', label: 'Research', vcs: 'default off', scaffolds: ['report', 'spike'] },
  { key: 'debugging', label: 'Debugging', vcs: 'default on', scaffolds: ['bug', 'incident'] },
  { key: 'data-analysis', label: 'Data analysis', vcs: 'default on', scaffolds: ['analysis'] },
  { key: 'writing', label: 'Writing', vcs: 'default on', scaffolds: ['article'] },
  { key: 'ops', label: 'Ops', vcs: 'default on', scaffolds: ['chore'] },
  { key: 'solo', label: 'Solo', vcs: 'project default', scaffolds: ['solo'] },
];

function normalizeTemplate(template: any) {
  return {
    id: template.template_id || template.templateId || template.id || '',
    name: template.display_name || template.displayName || template.name || template.template_id || '',
    role: template.role_hint || template.roleHint || '',
    provider: template.default_provider_profile || template.defaultProviderProfile || '',
    tier: template.suggested_model_tier || template.suggestedModelTier || '',
  };
}

export default function SettingsPage({ session, onReconnect, onBack }: any) {
  const dispatch = useDispatch<any>();
  const { agents, preferences, session: reduxSession, settingsTemplates, settingsProviders, chats, sending } = useSelector((state: any) => state.chat);
  const { recordsById, recordIds, loading: memoryLoading } = useSelector((state: any) => state.memory);
  const [selected, setSelected] = useState('templates');
  const [directAgentId, setDirectAgentId] = useState('');
  const [directDraft, setDirectDraft] = useState('');
  const [debugInfo, setDebugInfo] = useState<{ enabled: boolean; port: number; pid: number } | null>(null);

  const effectiveSession = reduxSession || session;

  useEffect(() => {
    if (!effectiveSession?.daemonUrl) return;
    dispatch(refreshSettingsCatalog()).catch(() => undefined);
    dispatch(fetchPreferences()).catch(() => undefined);
    dispatch(refreshMemory()).catch(() => undefined);
  }, [dispatch, effectiveSession?.daemonUrl, effectiveSession?.clientToken]);

  useEffect(() => {
    if ((window as any).odinApi?.getDebugInfo) (window as any).odinApi.getDebugInfo().then(setDebugInfo);
  }, []);

  useEffect(() => {
    if (!directAgentId && agents[0]?.id) setDirectAgentId(agents[0].id);
  }, [agents, directAgentId]);

  useEffect(() => {
    if (!directAgentId) return;
    dispatch(selectAgent(directAgentId));
    dispatch(fetchSelectedChat({ agentId: directAgentId })).catch(() => undefined);
  }, [dispatch, directAgentId]);

  const templates = useMemo(() => (settingsTemplates || []).map(normalizeTemplate).filter((item: any) => item.id), [settingsTemplates]);
  const providers = useMemo(() => (settingsProviders || []).map((item: any) => typeof item === 'string' ? { name: item } : item).filter((item: any) => item?.name), [settingsProviders]);
  const memoryRecords = useMemo(() => (recordIds || []).map((id: string) => recordsById[id]).filter(Boolean), [recordIds, recordsById]);
  const visiblePreferences = (preferences || []).slice(0, 12);
  const directMessages = chats[directAgentId] || [];

  return (
    <main className="h-full min-h-0 bg-[#08090b] text-zinc-100">
      <header className="flex items-center justify-between border-b border-white/10 bg-[#0d0f14] px-6 py-4">
        <div>
          <div className="text-xs uppercase tracking-[0.24em] text-zinc-500">Settings</div>
          <h1 className="mt-1 text-2xl font-semibold">System, debug, and daemon views</h1>
          <p className="mt-1 text-sm text-zinc-500">Moved legacy top-level tabs into this Settings surface. Data is hydrated by shared Redux/HTTP loads.</p>
        </div>
        <button data-debug-id="settings-back-btn" type="button" onClick={onBack} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Back</button>
      </header>

      <div className="grid h-[calc(100%-73px)] grid-cols-[240px_minmax(0,1fr)]">
        <nav className="border-r border-white/10 bg-[#0d0f14] p-3">
          <div className="space-y-1">
            {SETTINGS_ITEMS.map((item) => (
              <button key={item.key} data-debug-id={`settings-nav-${item.key}`} onClick={() => setSelected(item.key)} className={`w-full rounded-xl px-3 py-2 text-left text-sm ${selected === item.key ? 'bg-white text-black' : 'bg-white/5 text-zinc-300 hover:bg-white/10'}`}>{item.label}</button>
            ))}
          </div>
          <div className="mt-4 rounded-xl bg-white/[0.04] p-3 text-[11px] text-zinc-500">
            Freshness: Home-level periodic and WebSocket refreshes keep agents/tasks/chains current; Settings mounts dispatch HTTP-backed Redux loads for templates, preferences, and memory.
          </div>
        </nav>

        <section className="min-w-0 overflow-y-auto p-6">
          {selected === 'templates' && <TemplatesPanel templates={templates} />}
          {selected === 'kinds' && <TeamKindsPanel />}
          {selected === 'providers' && <ProvidersPanel providers={providers} preferences={visiblePreferences} />}
          {selected === 'memory' && <MemoryPanel records={memoryRecords} loading={memoryLoading} />}
          {selected === 'agents' && <AgentsPanel agents={agents} />}
          {selected === 'direct-chat' && <DirectChatPanel agents={agents} agentId={directAgentId} setAgentId={setDirectAgentId} messages={directMessages} draft={directDraft} setDraft={setDirectDraft} sending={sending} onSend={() => { const body = directDraft.trim(); if (!body || !directAgentId) return; dispatch(sendMessageToSelectedAgent({ body, tempId: `settings_${Date.now()}` })); setDirectDraft(''); }} />}
          {selected === 'daemon' && <DaemonPanel session={effectiveSession} onReconnect={onReconnect} debugInfo={debugInfo} setDebugInfo={setDebugInfo} />}
        </section>
      </div>
    </main>
  );
}

function Panel({ title, subtitle, children }: any) {
  return <div className="mx-auto max-w-5xl"><div className="mb-5"><h2 className="text-3xl font-semibold">{title}</h2><p className="mt-1 text-sm text-zinc-500">{subtitle}</p></div>{children}</div>;
}

function TemplatesPanel({ templates }: any) {
  return <Panel title="Agent templates" subtitle="Template registry moved from the legacy Agents tab. Read-only list for this UI pass."><div className="grid gap-3">{templates.length === 0 ? <Empty text="No templates loaded." /> : templates.map((template: any) => <Card key={template.id}><div className="font-semibold">{template.name || template.id}</div><div className="mt-1 text-sm text-zinc-500">{template.id} · role {template.role || '—'} · provider {template.provider || '—'} · tier {template.tier || '—'}</div></Card>)}</div></Panel>;
}

function TeamKindsPanel() {
  return <Panel title="Team kinds" subtitle="Closed-set daemon team kinds. Read-only."><div className="grid gap-3 md:grid-cols-2">{TEAM_KINDS.map((kind) => <Card key={kind.key}><div className="flex items-center justify-between"><div className="font-semibold">{kind.label}</div><span className="rounded-full bg-white/10 px-2 py-0.5 text-xs text-zinc-400">{kind.key}</span></div><div className="mt-2 text-sm text-zinc-500">VCS: {kind.vcs}</div><div className="mt-2 flex flex-wrap gap-1">{kind.scaffolds.map((scaffold) => <span key={scaffold} className="rounded-full bg-sky-400/10 px-2 py-0.5 text-xs text-sky-200">{scaffold}</span>)}</div></Card>)}</div></Panel>;
}

function ProvidersPanel({ providers, preferences }: any) {
  return <Panel title="Providers & model tiers" subtitle="Provider profiles and relevant preference snapshot."><div className="grid gap-4 lg:grid-cols-2"><Card><h3 className="font-semibold">Providers</h3><div className="mt-3 space-y-2">{providers.length === 0 ? <div className="text-sm text-zinc-500">No providers loaded.</div> : providers.map((provider: any) => <div key={provider.name} className="rounded-lg bg-black/20 px-3 py-2 text-sm">{provider.name}</div>)}</div></Card><Card><h3 className="font-semibold">Preference snapshot</h3><div className="mt-3 space-y-2">{preferences.length === 0 ? <div className="text-sm text-zinc-500">No preferences loaded.</div> : preferences.map((pref: any) => <div key={pref.key} className="rounded-lg bg-black/20 px-3 py-2 text-sm"><div className="text-zinc-300">{pref.key}</div><div className="truncate text-xs text-zinc-500">{String(pref.value || '')}</div></div>)}</div></Card></div></Panel>;
}

function MemoryPanel({ records, loading }: any) {
  return <Panel title="Memory browser" subtitle="Redux-backed memory records; refreshed on Settings mount and memory events.">{loading ? <Empty text="Loading memory…" /> : <div className="grid gap-3">{records.length === 0 ? <Empty text="No memory records loaded." /> : records.slice(0, 50).map((record: any) => <Card key={record.memoryId || record.id}><div className="font-semibold">{record.title || record.memoryId || record.id}</div><div className="mt-1 text-sm text-zinc-500">{record.scope || 'scope'} · {record.type || 'type'} · {record.status || 'status'}</div><div className="mt-2 line-clamp-3 text-sm text-zinc-300">{record.body || record.content || ''}</div></Card>)}</div>}</Panel>;
}

function AgentsPanel({ agents }: any) {
  return <Panel title="Agents (raw registry)" subtitle="Debug view of daemon agent registry, moved from the old Agents top-level tab."><div className="grid gap-3">{agents.length === 0 ? <Empty text="No agents loaded." /> : agents.map((agent: any) => <Card key={agent.id}><div className="flex items-center justify-between gap-3"><div className="font-semibold">{agent.label || agent.id}</div><span className="rounded-full bg-white/10 px-2 py-0.5 text-xs text-zinc-400">{agent.state || agent.status || 'unknown'}</span></div><div className="mt-1 text-xs text-zinc-500">{agent.id} · project {agent.projectId || '—'} · current task {agent.currentTaskId || 'idle'}</div></Card>)}</div></Panel>;
}

function DirectChatPanel({ agents, agentId, setAgentId, messages, draft, setDraft, sending, onSend }: any) {
  return (
    <Panel title="Direct agent chat (debug)" subtitle="Debug affordance only. Main-path chat remains chain coordinator-only.">
      <Card>
        <label className="text-sm text-zinc-300">
          Agent
          <select data-debug-id="settings-direct-chat-agent-select" value={agentId} onChange={(event) => setAgentId(event.target.value)} className="mt-2 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none">
            <option value="">Select agent</option>
            {agents.map((agent: any) => <option key={agent.id} value={agent.id}>{agent.label || agent.id}</option>)}
          </select>
        </label>
        <div data-debug-id="settings-direct-chat-feed" className="mt-4 max-h-80 min-h-48 overflow-y-auto rounded-xl bg-black/20 p-3">
          {messages.length === 0 ? <div className="text-sm text-zinc-500">No direct debug messages loaded.</div> : messages.map((message: any, index: number) => (
            <div key={message.id || message.messageId || index} className={`mb-2 rounded-xl px-3 py-2 text-sm ${message.direction === 'user_to_agent' || message.author === 'user' ? 'ml-8 bg-sky-500/15 text-sky-100' : 'mr-8 bg-white/5 text-zinc-200'}`}>{message.body}</div>
          ))}
        </div>
        <div className="mt-3 flex gap-2">
          <input data-debug-id="settings-direct-chat-input" value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') onSend(); }} placeholder="Debug direct message to selected agent…" className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" />
          <button data-debug-id="settings-direct-chat-send-btn" type="button" onClick={onSend} disabled={sending || !agentId || !draft.trim()} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:cursor-not-allowed disabled:opacity-50">{sending ? 'Sending…' : 'Send'}</button>
        </div>
      </Card>
    </Panel>
  );
}

function DaemonPanel({ session, onReconnect, debugInfo, setDebugInfo }: any) {
  return <Panel title="Daemon connection" subtitle="Connection profile and Electron debug server."><div className="grid gap-4 lg:grid-cols-2"><Card><SessionConfig session={session} onReconnect={onReconnect} /></Card><Card><h3 className="font-semibold">Electron debug server</h3><label className="mt-4 flex items-center gap-3 text-sm text-zinc-300"><input type="checkbox" checked={Boolean(debugInfo?.enabled)} onChange={async () => { if (!debugInfo || !(window as any).odinApi?.toggleDebugServer) return; setDebugInfo(await (window as any).odinApi.toggleDebugServer(!debugInfo.enabled)); }} />Enabled</label>{debugInfo?.enabled && <div className="mt-3 rounded-xl bg-black/20 p-3 font-mono text-xs text-zinc-400">http://127.0.0.1:{debugInfo.port}<br />pid {debugInfo.pid}</div>}</Card></div></Panel>;
}

function Card({ children }: any) { return <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">{children}</div>; }
function Empty({ text }: { text: string }) { return <div className="rounded-2xl border border-dashed border-white/10 p-5 text-sm text-zinc-500">{text}</div>; }
