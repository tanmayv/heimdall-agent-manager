import { useEffect, useMemo, useState } from 'react';
import { getRouteSearch } from '../../utils/appLocation';
import {
  normalizeBridgeCapabilities,
  useDeleteBridgeProviderMutation,
  useListBridgeProvidersQuery,
  useListBridgesQuery,
  useRefreshBridgeCapabilitiesMutation,
  useTestBridgeProviderMutation,
  useUpsertBridgeProviderMutation,
} from '../../api/endpoints/bridgeSupport';

type AutoEnterPair = { pattern: string; preKey: string };
type ReasonMapping = { key: string; reason: string };

type ProviderForm = {
  name: string;
  enabled: boolean;
  command: string[];
  modelsFlag: string;
  modelsCheap: string;
  modelsNormal: string;
  modelsSmart: string;
  promptFlags: string[];
  yoloFlags: string[];
  starterPrompt: string;
  promptDelivery: string;
  startupEnabled: boolean;
  startupProbeSeconds: string;
  startupCaptureIntervalMs: string;
  startupBlockedPatterns: string[];
  startupAutoEnterPairs: AutoEnterPair[];
  startupUnknownIsBlocked: boolean;
  startupReasonMappings: ReasonMapping[];
  activityEnabled: boolean;
  activitySampleLines: string;
  activityIgnoreBottomLines: string;
  activityCheckIntervalSeconds: string;
  activityMinGapMs: string;
  activityMaxGapMs: string;
};

const emptyForm: ProviderForm = {
  name: '',
  enabled: true,
  command: [],
  modelsFlag: '--model',
  modelsCheap: '',
  modelsNormal: '',
  modelsSmart: '',
  promptFlags: [],
  yoloFlags: [],
  starterPrompt: '',
  promptDelivery: 'flag-injection',
  startupEnabled: false,
  startupProbeSeconds: '20',
  startupCaptureIntervalMs: '500',
  startupBlockedPatterns: [],
  startupAutoEnterPairs: [],
  startupUnknownIsBlocked: false,
  startupReasonMappings: [],
  activityEnabled: false,
  activitySampleLines: '20',
  activityIgnoreBottomLines: '0',
  activityCheckIntervalSeconds: '2',
  activityMinGapMs: '250',
  activityMaxGapMs: '5000',
};

export function ProvidersPanel() {
  const bridgesQuery = useListBridgesQuery();
  const bridges = bridgesQuery.data?.bridges || [];
  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const selectedBridge = bridges.find((bridge: any) => bridgeId(bridge) === selectedBridgeId) || bridges[0];
  const selectedId = selectedBridge ? bridgeId(selectedBridge) : '';
  const offline = selectedBridge ? String(selectedBridge.status || '').toLowerCase() !== 'online' : true;
  const providersQuery = useListBridgeProvidersQuery({ bridgeId: selectedId }, { skip: !selectedId || offline });
  const [upsertProvider] = useUpsertBridgeProviderMutation();
  const [deleteProvider] = useDeleteBridgeProviderMutation();
  const [testProvider] = useTestBridgeProviderMutation();
  const [refreshCaps] = useRefreshBridgeCapabilitiesMutation();
  const providers = providersQuery.data?.providers || [];
  const capabilities = useMemo(() => normalizeBridgeCapabilities(selectedBridge), [selectedBridge]);
  const [actionError, setActionError] = useState('');
  const [testBusy, setTestBusy] = useState('');
  const [testResults, setTestResults] = useState<Record<string, any>>({});

  useEffect(() => {
    if (!selectedBridgeId && bridges.length > 0) setSelectedBridgeId(bridgeId(bridges[0]));
  }, [bridges, selectedBridgeId]);

  async function toggleEnabled(profile: any) {
    if (!selectedId || offline) return;
    const next = { ...formFromProfile(profile), enabled: !profile.enabled };
    setActionError('');
    try {
      await upsertProvider({ bridgeId: selectedId, name: next.name, profile: profileFromForm(next) }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.message || 'Toggle failed'));
    }
  }

  async function runTest(profile: any) {
    if (!selectedId || offline) return;
    const name = String(profile.name || '');
    setTestBusy(name);
    setActionError('');
    try {
      const result = await testProvider({ bridgeId: selectedId, name, tier: defaultTier(profile) }).unwrap();
      setTestResults((prev) => ({ ...prev, [name]: result }));
    } catch (err: any) {
      setTestResults((prev) => ({ ...prev, [name]: { status: 'failed', message: String(err?.message || 'Test failed') } }));
    } finally {
      setTestBusy('');
    }
  }

  async function removeProvider(profile: any) {
    if (!selectedId || offline || profile.source !== 'store') return;
    setActionError('');
    try {
      await deleteProvider({ bridgeId: selectedId, name: String(profile.name || '') }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.message || 'Delete failed'));
    }
  }

  async function refreshCapabilities() {
    if (!selectedId || offline) return;
    setActionError('');
    try {
      await refreshCaps({ bridgeId: selectedId }).unwrap();
      await providersQuery.refetch();
      await bridgesQuery.refetch();
    } catch (err: any) {
      setActionError(String(err?.message || 'Refresh failed'));
    }
  }

  return (
    <div className="w-full max-w-5xl space-y-6 text-left">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold text-white">Providers</h2>
          <p className="mt-1 max-w-3xl text-sm text-zinc-400">Configure provider profiles on the selected Bridge. Providers run in your machine&apos;s shell environment; Heimdall never stores credentials.</p>
        </div>
        <button data-debug-id="providers-refresh-caps-btn" type="button" onClick={() => void refreshCapabilities()} disabled={!selectedId || offline} className="min-h-[44px] w-full rounded-xl border border-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/10 disabled:opacity-50 sm:w-auto">Refresh capabilities</button>
      </div>

      <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <label className="block text-xs uppercase tracking-wide text-zinc-500">Bridge
          <select data-debug-id="providers-bridge-select" value={selectedId} onChange={(e) => setSelectedBridgeId(e.target.value)} className="mt-1 min-h-[44px] w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
            {bridges.map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)} · {bridge.status || 'offline'}</option>)}
          </select>
        </label>
        {bridges.length === 0 ? <div className="mt-3 rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No bridges connected yet. Add a Bridge first.</div> : null}
        {selectedBridge && offline ? <div className="mt-3 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-sm text-amber-100">bridge_offline: provider edit/test is disabled until this Bridge reconnects.</div> : null}
        {capabilities.length > 0 ? <div className="mt-3 text-xs text-zinc-500">Reported capabilities: <span className="text-zinc-300">{capabilities.map((cap) => `${cap.provider}${cap.tiers.length ? ` (${cap.tiers.join('/')})` : ''}`).join(', ')}</span></div> : null}
      </div>

      {actionError ? <div className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{actionError}</div> : null}

      <div className="flex justify-end">
        <a data-debug-id="providers-add-btn" href={shellHash(`/settings/providers/new?bridge=${encodeURIComponent(selectedId)}`)} aria-disabled={!selectedId || offline} className={`inline-flex min-h-[44px] w-full items-center justify-center rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 sm:w-auto ${!selectedId || offline ? 'pointer-events-none opacity-50' : ''}`}>＋ Add provider</a>
      </div>

      {providersQuery.isLoading ? <div className="rounded-xl bg-white/5 p-5 text-sm text-zinc-500">Loading providers…</div> : null}
      {!offline && providers.length === 0 && !providersQuery.isLoading ? <div className="rounded-xl border border-dashed border-white/10 p-8 text-center text-sm text-zinc-500">No provider profiles reported by this Bridge.</div> : null}

      <div className="space-y-3">
        {providers.map((profile: any) => {
          const name = String(profile.name || '');
          const result = testResults[name] || profile.last_test;
          return (
            <div key={name} data-debug-id={`providers-provider-row-${name}`} className="rounded-2xl border border-white/10 bg-white/[0.04] p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2"><h3 className="font-semibold text-white">{name}</h3><span data-debug-id={`provider-source-badge-${name}`} className="rounded-full border border-white/10 bg-black/30 px-2 py-0.5 text-[10px] uppercase tracking-wide text-zinc-400">{profile.source || 'config'}</span><span className={`rounded-full px-2 py-0.5 text-[10px] ${profile.enabled ? 'bg-emerald-400/10 text-emerald-200' : 'bg-zinc-500/10 text-zinc-400'}`}>{profile.enabled ? 'enabled' : 'disabled'}</span></div>
                  <div className="mt-2 break-all font-mono text-xs text-zinc-400">{(profile.command || []).join(' ') || 'no command configured'}</div>
                  <div className="mt-1 break-words text-xs text-zinc-500">model flag: <span className="text-zinc-300">{profile.models?.flag || '—'}</span> · cheap <span className="text-zinc-300">{profile.models?.cheap || '—'}</span> · normal <span className="text-zinc-300">{profile.models?.normal || '—'}</span> · smart <span className="text-zinc-300">{profile.models?.smart || '—'}</span></div>
                  <div data-debug-id={`providers-test-result-${name}`} className="mt-2 text-xs text-zinc-500">test: <span className={result?.status === 'ok' ? 'text-emerald-300' : result?.status === 'failed' ? 'text-red-300' : 'text-zinc-300'}>{result?.status || 'not run'}</span>{result?.message ? ` · ${result.message}` : ''}{result?.tested_at ? ` · ${result.tested_at}` : ''}</div>
                </div>
                <div className="grid w-full grid-cols-2 gap-2 sm:flex sm:w-auto sm:flex-wrap">
                  <button data-debug-id={`providers-enabled-toggle-${name}`} type="button" onClick={() => void toggleEnabled(profile)} disabled={offline} className="min-h-[44px] rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/10 disabled:opacity-50">{profile.enabled ? 'Disable' : 'Enable'}</button>
                  <a data-debug-id={`providers-edit-btn-${name}`} href={shellHash(`/settings/providers/${encodeURIComponent(name)}/edit?bridge=${encodeURIComponent(selectedId)}`)} aria-disabled={offline} className={`inline-flex min-h-[44px] items-center justify-center rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/10 ${offline ? 'pointer-events-none opacity-50' : ''}`}>Edit</a>
                  <button data-debug-id={`providers-test-btn-${name}`} type="button" onClick={() => void runTest(profile)} disabled={offline || testBusy === name} className="min-h-[44px] rounded-lg border border-sky-400/30 px-3 py-2 text-xs text-sky-100 hover:bg-sky-400/10 disabled:opacity-50">{testBusy === name ? 'Testing…' : 'Test'}</button>
                  <button data-debug-id={`providers-delete-btn-${name}`} type="button" onClick={() => void removeProvider(profile)} disabled={offline || profile.source !== 'store'} className="min-h-[44px] rounded-lg border border-rose-400/20 px-3 py-2 text-xs text-rose-200 hover:bg-rose-400/10 disabled:opacity-40">Delete</button>
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export function ProviderEditorPage({ providerName = '' }: { providerName?: string }) {
  const isEdit = Boolean(providerName);
  const bridgesQuery = useListBridgesQuery();
  const bridges = bridgesQuery.data?.bridges || [];
  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const selectedBridge = bridges.find((bridge: any) => bridgeId(bridge) === selectedBridgeId) || bridges[0];
  const selectedId = selectedBridge ? bridgeId(selectedBridge) : '';
  const offline = selectedBridge ? String(selectedBridge.status || '').toLowerCase() !== 'online' : true;
  const providersQuery = useListBridgeProvidersQuery({ bridgeId: selectedId }, { skip: !selectedId || offline });
  const providers = providersQuery.data?.providers || [];
  const currentProfile = providers.find((profile: any) => String(profile.name || '') === providerName);
  const [upsertProvider] = useUpsertBridgeProviderMutation();
  const [form, setForm] = useState<ProviderForm>(isEdit ? { ...emptyForm, name: providerName } : emptyForm);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    const params = new URLSearchParams(getRouteSearch());
    const bridge = params.get('bridge') || '';
    if (!selectedBridgeId && bridge) setSelectedBridgeId(bridge);
    else if (!selectedBridgeId && bridges.length > 0) setSelectedBridgeId(bridgeId(bridges[0]));
  }, [bridges, selectedBridgeId]);

  useEffect(() => { if (isEdit && currentProfile) setForm(formFromProfile(currentProfile)); }, [isEdit, providerName, currentProfile]);

  async function saveProvider() {
    const name = form.name.trim();
    if (!selectedId || !name) return;
    setSaving(true); setError('');
    try {
      await upsertProvider({ bridgeId: selectedId, name, profile: profileFromForm(form) }).unwrap();
      window.location.hash = shellHash('/settings/providers');
    } catch (err: any) {
      setError(String(err?.message || 'Save failed'));
    } finally { setSaving(false); }
  }

  return (
    <div className="w-full max-w-5xl space-y-6 text-left">
      <div className="rounded-2xl border border-white/10 bg-white/[0.04] p-5">
        <div className="flex flex-col items-stretch justify-between gap-3 sm:flex-row sm:items-start"><div><h2 className="text-2xl font-semibold text-white">{isEdit ? `Edit provider ${providerName}` : 'New provider'}</h2><p className="mt-1 max-w-3xl text-sm text-zinc-400">Add values with controls and chips; no JSON, comma lists, or array syntax is typed by users.</p></div><a data-debug-id="providers-editor-header-cancel-btn" href={shellHash('/settings/providers')} className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-white/10 px-4 py-2 text-sm text-zinc-200 hover:bg-white/15">Cancel</a></div>
        <label className="mt-5 block text-xs uppercase tracking-wide text-zinc-500">Bridge<select data-debug-id="providers-bridge-select" value={selectedId} onChange={(e) => setSelectedBridgeId(e.target.value)} className="mt-1 min-h-[44px] w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">{bridges.map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)} · {bridge.status || 'offline'}</option>)}</select></label>
        {offline ? <div className="mt-3 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-sm text-amber-100">This Bridge is offline; saving is disabled until it reconnects.</div> : null}
        {error ? <div className="mt-3 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{error}</div> : null}
      </div>
      <ProviderFormFields form={form} setForm={setForm} nameLocked={isEdit} />
      <div className="sticky bottom-20 z-10 flex flex-col-reverse gap-2 rounded-2xl border border-white/10 bg-[#0d0f14]/95 p-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] backdrop-blur md:bottom-0 sm:flex-row sm:justify-end"><a data-debug-id="providers-editor-footer-cancel-btn" href={shellHash('/settings/providers')} className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Cancel</a><button data-debug-id="providers-editor-save-btn" type="button" onClick={() => void saveProvider()} disabled={saving || offline || !form.name.trim()} className="min-h-[44px] rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50">{saving ? 'Saving…' : 'Save provider'}</button></div>
    </div>
  );
}

function ProviderFormFields({ form, setForm, nameLocked = false }: { form: ProviderForm; setForm: (form: ProviderForm) => void; nameLocked?: boolean }) {
  return (
    <div className="space-y-5 rounded-2xl border border-white/10 bg-white/[0.035] p-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <TextInput id="providers-editor-name-input" label="Name" value={form.name} onChange={(name) => setForm({ ...form, name })} placeholder="pi" disabled={nameLocked} />
        <label className="flex items-center gap-2 pt-6 text-sm text-zinc-300"><input data-debug-id="providers-enabled-toggle-editor" type="checkbox" checked={form.enabled} onChange={(e) => setForm({ ...form, enabled: e.target.checked })} /> Enabled</label>
      </div>
      <ChipListInput prefix="providers-editor-command" label="Command argv" placeholder="pi" values={form.command} onChange={(command) => setForm({ ...form, command })} />
      <div className="grid gap-4 sm:grid-cols-2">
        <TextInput id="providers-editor-models-flag-input" label="Model flag" value={form.modelsFlag} onChange={(modelsFlag) => setForm({ ...form, modelsFlag })} placeholder="--model" />
        <TextInput id="providers-editor-prompt-delivery-input" label="Prompt delivery" value={form.promptDelivery} onChange={(promptDelivery) => setForm({ ...form, promptDelivery })} placeholder="flag-injection" />
        <TextInput id="providers-editor-models-cheap-input" label="Cheap model" value={form.modelsCheap} onChange={(modelsCheap) => setForm({ ...form, modelsCheap })} placeholder="anthropic/claude-haiku-4-5" />
        <TextInput id="providers-editor-models-normal-input" label="Normal model" value={form.modelsNormal} onChange={(modelsNormal) => setForm({ ...form, modelsNormal })} placeholder="anthropic/claude-sonnet-4-6" />
        <TextInput id="providers-editor-models-smart-input" label="Smart model" value={form.modelsSmart} onChange={(modelsSmart) => setForm({ ...form, modelsSmart })} placeholder="anthropic/claude-opus-4-5" />
      </div>
      <ChipListInput prefix="providers-editor-prompt-flags" label="Prompt flags" placeholder="--prompt" values={form.promptFlags} onChange={(promptFlags) => setForm({ ...form, promptFlags })} />
      <ChipListInput prefix="providers-editor-yolo-flags" label="Yolo/permission flags" placeholder="--dangerously-skip-permissions" values={form.yoloFlags} onChange={(yoloFlags) => setForm({ ...form, yoloFlags })} />
      <label className="block text-sm text-zinc-300">Starter prompt<textarea data-debug-id="providers-editor-starter-prompt-input" value={form.starterPrompt} onChange={(e) => setForm({ ...form, starterPrompt: e.target.value })} placeholder="You are running under Heimdall. Say start-success when ready." className="mt-1 h-24 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>
      <div className="grid gap-4 sm:grid-cols-2"><label className="flex items-center gap-2 text-sm text-zinc-300"><input data-debug-id="providers-editor-startup-enabled-checkbox" type="checkbox" checked={form.startupEnabled} onChange={(e) => setForm({ ...form, startupEnabled: e.target.checked })} /> Startup detection</label><label className="flex items-center gap-2 text-sm text-zinc-300"><input data-debug-id="providers-editor-startup-unknown-blocked-checkbox" type="checkbox" checked={form.startupUnknownIsBlocked} onChange={(e) => setForm({ ...form, startupUnknownIsBlocked: e.target.checked })} /> Unknown startup is blocked</label><NumberInput id="providers-editor-startup-probe-input" label="Startup probe seconds" value={form.startupProbeSeconds} onChange={(startupProbeSeconds) => setForm({ ...form, startupProbeSeconds })} placeholder="20" min={0} /><NumberInput id="providers-editor-startup-capture-interval-input" label="Capture interval ms" value={form.startupCaptureIntervalMs} onChange={(startupCaptureIntervalMs) => setForm({ ...form, startupCaptureIntervalMs })} placeholder="500" min={0} /></div>
      <ChipListInput prefix="providers-editor-startup-blocked-patterns" label="Blocked patterns" placeholder="Yes, I trust this folder" values={form.startupBlockedPatterns} onChange={(startupBlockedPatterns) => setForm({ ...form, startupBlockedPatterns })} />
      <PairedListInput pairs={form.startupAutoEnterPairs} onChange={(startupAutoEnterPairs) => setForm({ ...form, startupAutoEnterPairs })} />
      <ReasonMappingInput rows={form.startupReasonMappings} onChange={(startupReasonMappings) => setForm({ ...form, startupReasonMappings })} />
      <div className="grid gap-4 sm:grid-cols-2"><label className="flex items-center gap-2 text-sm text-zinc-300"><input data-debug-id="providers-editor-activity-enabled-checkbox" type="checkbox" checked={form.activityEnabled} onChange={(e) => setForm({ ...form, activityEnabled: e.target.checked })} /> Activity detection</label><NumberInput id="providers-editor-activity-sample-lines-input" label="Activity sample lines" value={form.activitySampleLines} onChange={(activitySampleLines) => setForm({ ...form, activitySampleLines })} placeholder="20" min={0} /><NumberInput id="providers-editor-activity-ignore-bottom-input" label="Ignore bottom lines" value={form.activityIgnoreBottomLines} onChange={(activityIgnoreBottomLines) => setForm({ ...form, activityIgnoreBottomLines })} placeholder="0" min={0} /><NumberInput id="providers-editor-activity-check-interval-input" label="Check interval seconds" value={form.activityCheckIntervalSeconds} onChange={(activityCheckIntervalSeconds) => setForm({ ...form, activityCheckIntervalSeconds })} placeholder="2" min={0} /><NumberInput id="providers-editor-activity-min-gap-input" label="Min gap ms" value={form.activityMinGapMs} onChange={(activityMinGapMs) => setForm({ ...form, activityMinGapMs })} placeholder="250" min={0} /><NumberInput id="providers-editor-activity-max-gap-input" label="Max gap ms" value={form.activityMaxGapMs} onChange={(activityMaxGapMs) => setForm({ ...form, activityMaxGapMs })} placeholder="5000" min={0} /></div>
    </div>
  );
}

export function ChipListInput({ prefix, label, placeholder, values, onChange }: { prefix: string; label: string; placeholder: string; values: string[]; onChange: (values: string[]) => void }) {
  const [draft, setDraft] = useState('');
  function add() { const next = draft.trim(); if (!next) return; onChange([...values, next]); setDraft(''); }
  return <div className="rounded-xl border border-white/10 bg-black/20 p-3"><div className="text-sm font-medium text-zinc-300">{label}</div><div className="mt-2 flex flex-col gap-2 sm:flex-row"><input data-debug-id={`${prefix}-chip-input`} value={draft} onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } }} placeholder={placeholder} className="min-h-[44px] min-w-0 flex-1 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /><button data-debug-id={`${prefix}-chip-add-btn`} type="button" onClick={add} className="min-h-[44px] rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Add</button></div><div className="mt-2 flex flex-wrap gap-2">{values.map((value, index) => <span key={`${value}-${index}`} data-debug-id={`${prefix}-chip-${index}`} className="inline-flex min-h-[36px] max-w-full items-center gap-2 rounded-full bg-white/10 px-3 py-1 text-xs text-zinc-200"><span className="min-w-0 break-all">{value}</span><button data-debug-id={`${prefix}-chip-remove-btn-${index}`} type="button" onClick={() => onChange(values.filter((_, i) => i !== index))} className="min-h-[32px] min-w-[32px] text-zinc-400 hover:text-white">×</button></span>)}</div></div>;
}

function PairedListInput({ pairs, onChange }: { pairs: AutoEnterPair[]; onChange: (pairs: AutoEnterPair[]) => void }) {
  const [pattern, setPattern] = useState(''); const [preKey, setPreKey] = useState('');
  function add() { const p = pattern.trim(); const k = preKey.trim(); if (!p && !k) return; onChange([...pairs, { pattern: p, preKey: k }]); setPattern(''); setPreKey(''); }
  return <div className="rounded-xl border border-white/10 bg-black/20 p-3"><div className="text-sm font-medium text-zinc-300">Auto-enter pattern + pre-key pairs</div><div className="mt-2 grid gap-2 sm:grid-cols-[1fr_1fr_auto]"><input data-debug-id="providers-editor-startup-auto-enter-patterns-chip-input" value={pattern} onChange={(e) => setPattern(e.target.value)} placeholder="Yes, I trust this folder" className="min-h-[44px] min-w-0 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /><input data-debug-id="providers-editor-startup-auto-enter-pre-keys-chip-input" value={preKey} onChange={(e) => setPreKey(e.target.value)} placeholder="Enter" className="min-h-[44px] min-w-0 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /><button data-debug-id="providers-editor-startup-auto-enter-patterns-chip-add-btn" type="button" onClick={add} className="min-h-[44px] rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Add</button></div><div className="mt-2 space-y-2">{pairs.map((pair, index) => <div key={index} data-debug-id={`providers-editor-startup-auto-enter-patterns-chip-${index}`} className="flex items-center justify-between gap-2 rounded-xl bg-white/10 px-3 py-2 text-xs text-zinc-200"><span className="min-w-0 break-all">{pair.pattern || '—'} → {pair.preKey || '—'}</span><button data-debug-id={`providers-editor-startup-auto-enter-patterns-chip-remove-btn-${index}`} type="button" onClick={() => onChange(pairs.filter((_, i) => i !== index))} className="min-h-[32px] min-w-[32px] text-zinc-400 hover:text-white">×</button></div>)}</div></div>;
}

function ReasonMappingInput({ rows, onChange }: { rows: ReasonMapping[]; onChange: (rows: ReasonMapping[]) => void }) {
  const [keyValue, setKeyValue] = useState(''); const [reason, setReason] = useState('');
  function add() { const k = keyValue.trim(); const r = reason.trim(); if (!k && !r) return; onChange([...rows, { key: k, reason: r }]); setKeyValue(''); setReason(''); }
  return <div className="rounded-xl border border-white/10 bg-black/20 p-3"><div className="text-sm font-medium text-zinc-300">Sanitized reason mapping</div><div className="mt-2 grid gap-2 sm:grid-cols-[1fr_1fr_auto]"><input data-debug-id="providers-editor-startup-reason-mapping-chip-input" value={keyValue} onChange={(e) => setKeyValue(e.target.value)} placeholder="permission_prompt" className="min-h-[44px] min-w-0 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /><input data-debug-id="providers-editor-startup-reason-mapping-reason-input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Waiting for trust confirmation" className="min-h-[44px] min-w-0 rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /><button data-debug-id="providers-editor-startup-reason-mapping-chip-add-btn" type="button" onClick={add} className="min-h-[44px] rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Add</button></div><div className="mt-2 space-y-2">{rows.map((row, index) => <div key={index} data-debug-id={`providers-editor-startup-reason-mapping-chip-${index}`} className="flex items-center justify-between gap-2 rounded-xl bg-white/10 px-3 py-2 text-xs text-zinc-200"><span className="min-w-0 break-all">{row.key || '—'} → {row.reason || '—'}</span><button data-debug-id={`providers-editor-startup-reason-mapping-chip-remove-btn-${index}`} type="button" onClick={() => onChange(rows.filter((_, i) => i !== index))} className="min-h-[32px] min-w-[32px] text-zinc-400 hover:text-white">×</button></div>)}</div></div>;
}

function bridgeId(bridge: any): string { return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || ''); }
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }
function asArray(value: any): string[] { return Array.isArray(value) ? value.map(String).filter(Boolean) : String(value || '').split(/\s+/).map((part) => part.trim()).filter(Boolean); }
function asLines(value: any): string[] { return Array.isArray(value) ? value.map(String).filter(Boolean) : String(value || '').split(/\r?\n/).map((part) => part.trim()).filter(Boolean); }
function intValue(value: string, fallback: number): number { const n = Number.parseInt(value, 10); return Number.isFinite(n) ? n : fallback; }
function defaultTier(profile: any): string { return profile.models?.normal ? 'normal' : profile.models?.cheap ? 'cheap' : profile.models?.smart ? 'smart' : 'normal'; }

function parseReasonMappings(value: any): ReasonMapping[] { return asLines(value).map((line) => { const idx = line.indexOf('='); return idx >= 0 ? { key: line.slice(0, idx), reason: line.slice(idx + 1) } : { key: line, reason: '' }; }); }

function formFromProfile(profile: any): ProviderForm {
  const startup = profile.startup_detection || {}; const activity = profile.activity_detection || {}; const patterns = asLines(startup.auto_enter_patterns); const preKeys = asLines(startup.auto_enter_pre_keys);
  return { ...emptyForm, name: String(profile.name || ''), enabled: Boolean(profile.enabled ?? true), command: asArray(profile.command), modelsFlag: String(profile.models?.flag || ''), modelsCheap: String(profile.models?.cheap || ''), modelsNormal: String(profile.models?.normal || ''), modelsSmart: String(profile.models?.smart || ''), promptFlags: asArray(profile.prompt_flags), yoloFlags: asArray(profile.yolo_flags), starterPrompt: String(profile.starter_prompt || ''), promptDelivery: String(profile.prompt_delivery || ''), startupEnabled: Boolean(startup.enabled), startupProbeSeconds: String(startup.startup_probe_seconds ?? startup.probe_seconds ?? '20'), startupCaptureIntervalMs: String(startup.capture_interval_ms ?? '500'), startupBlockedPatterns: asLines(startup.blocked_patterns), startupAutoEnterPairs: Array.from({ length: Math.max(patterns.length, preKeys.length) }, (_, i) => ({ pattern: patterns[i] || '', preKey: preKeys[i] || '' })), startupUnknownIsBlocked: Boolean(startup.startup_unknown_is_blocked), startupReasonMappings: parseReasonMappings(startup.sanitized_reason_mapping), activityEnabled: Boolean(activity.enabled), activitySampleLines: String(activity.sample_line_count ?? '20'), activityIgnoreBottomLines: String(activity.ignore_bottom_lines ?? '0'), activityCheckIntervalSeconds: String(activity.check_interval_seconds ?? '2'), activityMinGapMs: String(activity.min_gap_ms ?? '250'), activityMaxGapMs: String(activity.max_gap_ms ?? '5000') };
}

function profileFromForm(form: ProviderForm): any {
  return { name: form.name.trim(), enabled: form.enabled, command: form.command, models: { flag: form.modelsFlag.trim(), cheap: form.modelsCheap.trim(), normal: form.modelsNormal.trim(), smart: form.modelsSmart.trim() }, prompt_flags: form.promptFlags, yolo_flags: form.yoloFlags, starter_prompt: form.starterPrompt, prompt_delivery: form.promptDelivery, startup_detection: { enabled: form.startupEnabled, startup_probe_seconds: intValue(form.startupProbeSeconds, 20), capture_interval_ms: intValue(form.startupCaptureIntervalMs, 500), blocked_patterns: form.startupBlockedPatterns, auto_enter_patterns: form.startupAutoEnterPairs.map((pair) => pair.pattern), auto_enter_pre_keys: form.startupAutoEnterPairs.map((pair) => pair.preKey), startup_unknown_is_blocked: form.startupUnknownIsBlocked, sanitized_reason_mapping: form.startupReasonMappings.map((row) => `${row.key}=${row.reason}`) }, activity_detection: { enabled: form.activityEnabled, sample_line_count: intValue(form.activitySampleLines, 20), ignore_bottom_lines: intValue(form.activityIgnoreBottomLines, 0), check_interval_seconds: intValue(form.activityCheckIntervalSeconds, 2), min_gap_ms: intValue(form.activityMinGapMs, 250), max_gap_ms: intValue(form.activityMaxGapMs, 5000) } };
}

function TextInput({ id, label, value, onChange, placeholder, disabled = false }: { id: string; label: string; value: string; onChange: (value: string) => void; placeholder: string; disabled?: boolean }) { return <label className="block text-sm text-zinc-300">{label}<input data-debug-id={id} value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} disabled={disabled} className="mt-1 min-h-[44px] w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400 disabled:opacity-60" /></label>; }
function NumberInput({ id, label, value, onChange, placeholder, min = 0 }: { id: string; label: string; value: string; onChange: (value: string) => void; placeholder: string; min?: number }) { return <label className="block text-sm text-zinc-300">{label}<input data-debug-id={id} type="number" min={min} step="1" value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} className="mt-1 min-h-[44px] w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>; }
