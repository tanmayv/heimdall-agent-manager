import { useEffect, useMemo, useState } from 'react';
import {
  normalizeBridgeCapabilities,
  useDeleteBridgeProviderMutation,
  useListBridgeProvidersQuery,
  useListBridgesQuery,
  useRefreshBridgeCapabilitiesMutation,
  useTestBridgeProviderMutation,
  useUpsertBridgeProviderMutation,
} from '../../api/endpoints/bridgeSupport';

type ProviderForm = {
  name: string;
  enabled: boolean;
  command: string;
  modelsFlag: string;
  modelsCheap: string;
  modelsNormal: string;
  modelsSmart: string;
  promptFlags: string;
  yoloFlags: string;
  starterPrompt: string;
  promptDelivery: string;
  startupEnabled: boolean;
  startupProbeSeconds: string;
  startupCaptureIntervalMs: string;
  startupBlockedPatterns: string;
  startupAutoEnterPatterns: string;
  startupAutoEnterPreKeys: string;
  startupUnknownIsBlocked: boolean;
  startupReasonMapping: string;
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
  command: '',
  modelsFlag: '--model',
  modelsCheap: '',
  modelsNormal: '',
  modelsSmart: '',
  promptFlags: '',
  yoloFlags: '',
  starterPrompt: '',
  promptDelivery: 'flag-injection',
  startupEnabled: false,
  startupProbeSeconds: '10',
  startupCaptureIntervalMs: '500',
  startupBlockedPatterns: '',
  startupAutoEnterPatterns: '',
  startupAutoEnterPreKeys: '',
  startupUnknownIsBlocked: false,
  startupReasonMapping: '',
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
  const [editorOpen, setEditorOpen] = useState(false);
  const [form, setForm] = useState<ProviderForm>(emptyForm);
  const [saving, setSaving] = useState(false);
  const [actionError, setActionError] = useState('');
  const [testBusy, setTestBusy] = useState('');
  const [testResults, setTestResults] = useState<Record<string, any>>({});

  useEffect(() => {
    if (!selectedBridgeId && bridges.length > 0) setSelectedBridgeId(bridgeId(bridges[0]));
  }, [bridges, selectedBridgeId]);

  function openNew() {
    setActionError('');
    setForm(emptyForm);
    setEditorOpen(true);
  }

  function openEdit(profile: any) {
    setActionError('');
    setForm(formFromProfile(profile));
    setEditorOpen(true);
  }

  async function saveProvider() {
    const name = form.name.trim();
    if (!selectedId || !name) return;
    setSaving(true);
    setActionError('');
    try {
      await upsertProvider({ bridgeId: selectedId, name, profile: profileFromForm(form) }).unwrap();
      setEditorOpen(false);
    } catch (err: any) {
      setActionError(String(err?.message || 'Save failed'));
    } finally {
      setSaving(false);
    }
  }

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
          <p className="mt-1 max-w-3xl text-sm text-zinc-400">Configure provider profiles on the selected Bridge. Commands, flags, models, and detection settings are persisted on that Bridge; provider credentials are never collected by Heimdall and providers run in your machine&apos;s shell environment.</p>
        </div>
        <button data-debug-id="providers-refresh-caps-btn" type="button" onClick={() => void refreshCapabilities()} disabled={!selectedId || offline} className="rounded-xl border border-white/10 px-3 py-1.5 text-sm text-zinc-200 hover:bg-white/10 disabled:opacity-50">Refresh capabilities</button>
      </div>

      <div className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
        <label className="block text-xs uppercase tracking-wide text-zinc-500">Bridge
          <select data-debug-id="providers-bridge-select" value={selectedId} onChange={(e) => setSelectedBridgeId(e.target.value)} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400">
            {bridges.map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)} · {bridge.status || 'offline'}</option>)}
          </select>
        </label>
        {bridges.length === 0 ? <div className="mt-3 rounded-xl border border-dashed border-white/10 p-4 text-sm text-zinc-500">No bridges connected yet. Add a Bridge first.</div> : null}
        {selectedBridge && offline ? <div className="mt-3 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-sm text-amber-100">bridge_offline: provider edit/test is disabled until this Bridge reconnects.</div> : null}
        {capabilities.length > 0 ? <div className="mt-3 text-xs text-zinc-500">Reported capabilities: <span className="text-zinc-300">{capabilities.map((cap) => `${cap.provider}${cap.tiers.length ? ` (${cap.tiers.join('/')})` : ''}`).join(', ')}</span></div> : null}
      </div>

      {actionError ? <div className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{actionError}</div> : null}

      <div className="flex justify-end">
        <button data-debug-id="providers-add-btn" type="button" onClick={openNew} disabled={!selectedId || offline} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50">＋ Add provider</button>
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
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-semibold text-white">{name}</h3>
                    <span data-debug-id={`provider-source-badge-${name}`} className="rounded-full border border-white/10 bg-black/30 px-2 py-0.5 text-[10px] uppercase tracking-wide text-zinc-400">{profile.source || 'config'}</span>
                    <span className={`rounded-full px-2 py-0.5 text-[10px] ${profile.enabled ? 'bg-emerald-400/10 text-emerald-200' : 'bg-zinc-500/10 text-zinc-400'}`}>{profile.enabled ? 'enabled' : 'disabled'}</span>
                  </div>
                  <div className="mt-2 font-mono text-xs text-zinc-400">{(profile.command || []).join(' ') || 'no command configured'}</div>
                  <div className="mt-1 text-xs text-zinc-500">model flag: <span className="text-zinc-300">{profile.models?.flag || '—'}</span> · cheap <span className="text-zinc-300">{profile.models?.cheap || '—'}</span> · normal <span className="text-zinc-300">{profile.models?.normal || '—'}</span> · smart <span className="text-zinc-300">{profile.models?.smart || '—'}</span></div>
                  <div data-debug-id={`providers-test-result-${name}`} className="mt-2 text-xs text-zinc-500">test: <span className={result?.status === 'ok' ? 'text-emerald-300' : result?.status === 'failed' ? 'text-red-300' : 'text-zinc-300'}>{result?.status || 'not run'}</span>{result?.message ? ` · ${result.message}` : ''}{result?.tested_at ? ` · ${result.tested_at}` : ''}</div>
                </div>
                <div className="flex flex-wrap gap-2">
                  <button data-debug-id={`providers-enabled-toggle-${name}`} type="button" onClick={() => void toggleEnabled(profile)} disabled={offline} className="rounded-lg border border-white/10 px-2.5 py-1 text-xs text-zinc-300 hover:bg-white/10 disabled:opacity-50">{profile.enabled ? 'Disable' : 'Enable'}</button>
                  <button data-debug-id={`providers-edit-btn-${name}`} type="button" onClick={() => openEdit(profile)} disabled={offline} className="rounded-lg border border-white/10 px-2.5 py-1 text-xs text-zinc-300 hover:bg-white/10 disabled:opacity-50">Edit</button>
                  <button data-debug-id={`providers-test-btn-${name}`} type="button" onClick={() => void runTest(profile)} disabled={offline || testBusy === name} className="rounded-lg border border-sky-400/30 px-2.5 py-1 text-xs text-sky-100 hover:bg-sky-400/10 disabled:opacity-50">{testBusy === name ? 'Testing…' : 'Test'}</button>
                  <button data-debug-id={`providers-delete-btn-${name}`} type="button" onClick={() => void removeProvider(profile)} disabled={offline || profile.source !== 'store'} className="rounded-lg border border-rose-400/20 px-2.5 py-1 text-xs text-rose-200 hover:bg-rose-400/10 disabled:opacity-40">Delete</button>
                </div>
              </div>
            </div>
          );
        })}
      </div>

      {editorOpen ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto bg-black/70 p-4">
          <div className="w-full max-w-3xl rounded-3xl border border-white/10 bg-[#0d0f14] p-5 shadow-2xl">
            <div className="flex items-start justify-between gap-3">
              <div><h3 className="text-xl font-semibold text-white">Provider editor</h3><p className="mt-1 text-sm text-zinc-500">No credential or env fields are stored. Use your shell/CLI login on the Bridge machine.</p></div>
              <button data-debug-id="providers-editor-close-btn" type="button" onClick={() => setEditorOpen(false)} className="rounded-xl bg-white/10 px-3 py-2 text-sm hover:bg-white/15">Close</button>
            </div>
            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <TextInput id="providers-editor-name-input" label="Name" value={form.name} onChange={(name) => setForm({ ...form, name })} />
              <label className="flex items-center gap-2 pt-6 text-sm text-zinc-300"><input data-debug-id="providers-enabled-toggle-editor" type="checkbox" checked={form.enabled} onChange={(e) => setForm({ ...form, enabled: e.target.checked })} /> Enabled</label>
              <TextInput id="providers-editor-command-input" label="Command argv" value={form.command} onChange={(command) => setForm({ ...form, command })} placeholder="pi --some-flag" />
              <TextInput id="providers-editor-models-flag-input" label="Model flag" value={form.modelsFlag} onChange={(modelsFlag) => setForm({ ...form, modelsFlag })} />
              <TextInput id="providers-editor-models-cheap-input" label="Cheap model" value={form.modelsCheap} onChange={(modelsCheap) => setForm({ ...form, modelsCheap })} />
              <TextInput id="providers-editor-models-normal-input" label="Normal model" value={form.modelsNormal} onChange={(modelsNormal) => setForm({ ...form, modelsNormal })} />
              <TextInput id="providers-editor-models-smart-input" label="Smart model" value={form.modelsSmart} onChange={(modelsSmart) => setForm({ ...form, modelsSmart })} />
              <TextInput id="providers-editor-prompt-flags-input" label="Prompt flags" value={form.promptFlags} onChange={(promptFlags) => setForm({ ...form, promptFlags })} />
              <TextInput id="providers-editor-yolo-flags-input" label="Yolo/permission flags" value={form.yoloFlags} onChange={(yoloFlags) => setForm({ ...form, yoloFlags })} />
              <TextInput id="providers-editor-prompt-delivery-input" label="Prompt delivery" value={form.promptDelivery} onChange={(promptDelivery) => setForm({ ...form, promptDelivery })} />
              <label className="sm:col-span-2 block text-sm text-zinc-300">Starter prompt<textarea data-debug-id="providers-editor-starter-prompt-input" value={form.starterPrompt} onChange={(e) => setForm({ ...form, starterPrompt: e.target.value })} className="mt-1 h-24 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>
              <label className="flex items-center gap-2 text-sm text-zinc-300"><input data-debug-id="providers-editor-startup-enabled-checkbox" type="checkbox" checked={form.startupEnabled} onChange={(e) => setForm({ ...form, startupEnabled: e.target.checked })} /> Startup detection</label>
              <label className="flex items-center gap-2 text-sm text-zinc-300"><input data-debug-id="providers-editor-startup-unknown-blocked-checkbox" type="checkbox" checked={form.startupUnknownIsBlocked} onChange={(e) => setForm({ ...form, startupUnknownIsBlocked: e.target.checked })} /> Unknown startup is blocked</label>
              <TextInput id="providers-editor-startup-probe-input" label="Startup probe seconds" value={form.startupProbeSeconds} onChange={(startupProbeSeconds) => setForm({ ...form, startupProbeSeconds })} />
              <TextInput id="providers-editor-startup-capture-interval-input" label="Capture interval ms" value={form.startupCaptureIntervalMs} onChange={(startupCaptureIntervalMs) => setForm({ ...form, startupCaptureIntervalMs })} />
              <TextareaInput id="providers-editor-startup-blocked-patterns-input" label="Blocked patterns (one per line)" value={form.startupBlockedPatterns} onChange={(startupBlockedPatterns) => setForm({ ...form, startupBlockedPatterns })} />
              <TextareaInput id="providers-editor-startup-auto-enter-patterns-input" label="Auto-enter patterns" value={form.startupAutoEnterPatterns} onChange={(startupAutoEnterPatterns) => setForm({ ...form, startupAutoEnterPatterns })} />
              <TextareaInput id="providers-editor-startup-auto-enter-pre-keys-input" label="Auto-enter pre-keys" value={form.startupAutoEnterPreKeys} onChange={(startupAutoEnterPreKeys) => setForm({ ...form, startupAutoEnterPreKeys })} />
              <TextareaInput id="providers-editor-startup-reason-mapping-input" label="Sanitized reason mapping" value={form.startupReasonMapping} onChange={(startupReasonMapping) => setForm({ ...form, startupReasonMapping })} />
              <label className="flex items-center gap-2 text-sm text-zinc-300"><input data-debug-id="providers-editor-activity-enabled-checkbox" type="checkbox" checked={form.activityEnabled} onChange={(e) => setForm({ ...form, activityEnabled: e.target.checked })} /> Activity detection</label>
              <TextInput id="providers-editor-activity-sample-lines-input" label="Activity sample lines" value={form.activitySampleLines} onChange={(activitySampleLines) => setForm({ ...form, activitySampleLines })} />
              <TextInput id="providers-editor-activity-ignore-bottom-input" label="Ignore bottom lines" value={form.activityIgnoreBottomLines} onChange={(activityIgnoreBottomLines) => setForm({ ...form, activityIgnoreBottomLines })} />
              <TextInput id="providers-editor-activity-check-interval-input" label="Check interval seconds" value={form.activityCheckIntervalSeconds} onChange={(activityCheckIntervalSeconds) => setForm({ ...form, activityCheckIntervalSeconds })} />
              <TextInput id="providers-editor-activity-min-gap-input" label="Min gap ms" value={form.activityMinGapMs} onChange={(activityMinGapMs) => setForm({ ...form, activityMinGapMs })} />
              <TextInput id="providers-editor-activity-max-gap-input" label="Max gap ms" value={form.activityMaxGapMs} onChange={(activityMaxGapMs) => setForm({ ...form, activityMaxGapMs })} />
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <button data-debug-id="providers-editor-cancel-btn" type="button" onClick={() => setEditorOpen(false)} className="rounded-xl bg-white/10 px-4 py-2 text-sm hover:bg-white/15">Cancel</button>
              <button data-debug-id="providers-editor-save-btn" type="button" onClick={() => void saveProvider()} disabled={saving || !form.name.trim()} className="rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50">{saving ? 'Saving…' : 'Save provider'}</button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function bridgeId(bridge: any): string { return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || ''); }
function splitWords(value: string): string[] { return value.split(/\s+/).map((part) => part.trim()).filter(Boolean); }
function splitLines(value: string): string[] { return value.split(/\r?\n/).map((part) => part.trim()).filter(Boolean); }
function joinWords(value: any): string { return Array.isArray(value) ? value.join(' ') : String(value || ''); }
function joinLines(value: any): string { return Array.isArray(value) ? value.join('\n') : String(value || ''); }
function intValue(value: string, fallback: number): number { const n = Number.parseInt(value, 10); return Number.isFinite(n) ? n : fallback; }
function defaultTier(profile: any): string { return profile.models?.normal ? 'normal' : profile.models?.cheap ? 'cheap' : profile.models?.smart ? 'smart' : 'normal'; }

function formFromProfile(profile: any): ProviderForm {
  const startup = profile.startup_detection || {};
  const activity = profile.activity_detection || {};
  return {
    ...emptyForm,
    name: String(profile.name || ''),
    enabled: Boolean(profile.enabled ?? true),
    command: joinWords(profile.command),
    modelsFlag: String(profile.models?.flag || ''),
    modelsCheap: String(profile.models?.cheap || ''),
    modelsNormal: String(profile.models?.normal || ''),
    modelsSmart: String(profile.models?.smart || ''),
    promptFlags: joinWords(profile.prompt_flags),
    yoloFlags: joinWords(profile.yolo_flags),
    starterPrompt: String(profile.starter_prompt || ''),
    promptDelivery: String(profile.prompt_delivery || ''),
    startupEnabled: Boolean(startup.enabled),
    startupProbeSeconds: String(startup.startup_probe_seconds ?? startup.probe_seconds ?? '10'),
    startupCaptureIntervalMs: String(startup.capture_interval_ms ?? '500'),
    startupBlockedPatterns: joinLines(startup.blocked_patterns),
    startupAutoEnterPatterns: joinLines(startup.auto_enter_patterns),
    startupAutoEnterPreKeys: joinLines(startup.auto_enter_pre_keys),
    startupUnknownIsBlocked: Boolean(startup.startup_unknown_is_blocked),
    startupReasonMapping: joinLines(startup.sanitized_reason_mapping),
    activityEnabled: Boolean(activity.enabled),
    activitySampleLines: String(activity.sample_line_count ?? '20'),
    activityIgnoreBottomLines: String(activity.ignore_bottom_lines ?? '0'),
    activityCheckIntervalSeconds: String(activity.check_interval_seconds ?? '2'),
    activityMinGapMs: String(activity.min_gap_ms ?? '250'),
    activityMaxGapMs: String(activity.max_gap_ms ?? '5000'),
  };
}

function profileFromForm(form: ProviderForm): any {
  return {
    name: form.name.trim(),
    enabled: form.enabled,
    command: splitWords(form.command),
    models: { flag: form.modelsFlag.trim(), cheap: form.modelsCheap.trim(), normal: form.modelsNormal.trim(), smart: form.modelsSmart.trim() },
    prompt_flags: splitWords(form.promptFlags),
    yolo_flags: splitWords(form.yoloFlags),
    starter_prompt: form.starterPrompt,
    prompt_delivery: form.promptDelivery,
    startup_detection: {
      enabled: form.startupEnabled,
      startup_probe_seconds: intValue(form.startupProbeSeconds, 10),
      capture_interval_ms: intValue(form.startupCaptureIntervalMs, 500),
      blocked_patterns: splitLines(form.startupBlockedPatterns),
      auto_enter_patterns: splitLines(form.startupAutoEnterPatterns),
      auto_enter_pre_keys: splitLines(form.startupAutoEnterPreKeys),
      startup_unknown_is_blocked: form.startupUnknownIsBlocked,
      sanitized_reason_mapping: splitLines(form.startupReasonMapping),
    },
    activity_detection: {
      enabled: form.activityEnabled,
      sample_line_count: intValue(form.activitySampleLines, 20),
      ignore_bottom_lines: intValue(form.activityIgnoreBottomLines, 0),
      check_interval_seconds: intValue(form.activityCheckIntervalSeconds, 2),
      min_gap_ms: intValue(form.activityMinGapMs, 250),
      max_gap_ms: intValue(form.activityMaxGapMs, 5000),
    },
  };
}

function TextInput({ id, label, value, onChange, placeholder = '' }: { id: string; label: string; value: string; onChange: (value: string) => void; placeholder?: string }) {
  return <label className="block text-sm text-zinc-300">{label}<input data-debug-id={id} value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>;
}

function TextareaInput({ id, label, value, onChange }: { id: string; label: string; value: string; onChange: (value: string) => void }) {
  return <label className="block text-sm text-zinc-300">{label}<textarea data-debug-id={id} value={value} onChange={(e) => onChange(e.target.value)} className="mt-1 h-20 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm outline-none focus:border-sky-400" /></label>;
}
