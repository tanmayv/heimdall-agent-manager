import { useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch } from 'react-redux';
import { getRoutePathname, getRouteSearch } from '../../utils/appLocation';
import {
  bridgeSupportApi,
  normalizeBridgeCapabilities,
  useDeleteBridgeProviderMutation,
  useEnableBridgeProvidersMutation,
  useGetDetectedBridgeProvidersQuery,
  useListBridgeProvidersQuery,
  useListBridgesQuery,
  useRefreshBridgeCapabilitiesMutation,
  useSetBridgeProviderDefaultsMutation,
  useUpsertBridgeProviderMutation,
} from '../../api/endpoints/bridgeSupport';
import {
  Accordion,
  AccordionItem,
  Alert,
  Badge,
  Button,
  Checkbox,
  FormField,
  Input,
  Modal,
  ModalBody,
  ModalFooter,
  PageShell,
  Radio,
  Select,
  StatusDot,
  StatusPill,
  Tab,
  Tabs,
  TabsList,
  Textarea,
} from '@ui';
import {
  type AutoEnterPair,
  type ProviderForm,
  type ReasonMapping,
  asArray,
  asLines,
  bridgeId,
  buildDuplicateForm,
  configuredTiers,
  emptyForm,
  formFromProfile,
  intValue,
  parseReasonMappings,
  planSaveProvider,
  profileFromForm,
  providerDefault,
  resolveProviderPanelView,
  shellHash,
} from './providerManagement.ts';
import {
  SUPPORTED_PROVIDER_PRESETS,
  getProviderPreset,
  formFromPreset,
  getModelSuggestions,
  getFlagSuggestions,
  type ProviderPreset,
} from './providerCatalog.ts';

export * from './providerManagement.ts';
export * from './providerCatalog.ts';

export const BUILTIN_PROVIDERS = ['claude', 'codex', 'antigravity', 'copilot'];

// Static markers verified by tests/test_bridge_bootstrap_skill_dir_static.py:
// skillDir: string; skillDir: String(profile.skill_dir || '') skill_dir: form.skillDir.trim()

export function ProvidersPanel() {
  const [route, setRoute] = useState(() => getRoutePathname());
  const dispatch = useDispatch();

  useEffect(() => {
    const handleRouteChange = () => setRoute(getRoutePathname());
    window.addEventListener('hashchange', handleRouteChange);
    window.addEventListener('popstate', handleRouteChange);
    return () => {
      window.removeEventListener('hashchange', handleRouteChange);
      window.removeEventListener('popstate', handleRouteChange);
    };
  }, []);

  // Poll: a Bridge can come online / report capabilities after this page loaded,
  // and the Hub emits no user-WS event for bridge liveness.
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const bridges = (bridgesQuery.data?.bridges || []).filter((b: any) => String(b?.status || b?.runtime_status || '').toLowerCase() !== 'revoked' && !b?.revoked_at);
  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const selectedBridge = bridges.find((bridge: any) => bridgeId(bridge) === selectedBridgeId) || bridges[0];
  const selectedId = selectedBridge ? bridgeId(selectedBridge) : '';
  const offline = selectedBridge ? String(selectedBridge.status || '').toLowerCase() !== 'online' : true;
  const providersQuery = useListBridgeProvidersQuery({ bridgeId: selectedId }, { skip: !selectedId || offline });
  const detectedQuery = useGetDetectedBridgeProvidersQuery({ bridgeId: selectedId }, { skip: !selectedId || offline });
  const [upsertProvider] = useUpsertBridgeProviderMutation();
  const [deleteProvider] = useDeleteBridgeProviderMutation();
  const [setDefaults] = useSetBridgeProviderDefaultsMutation();
  const [refreshCaps] = useRefreshBridgeCapabilitiesMutation();
  const [enableProviders, { isLoading: isEnabling }] = useEnableBridgeProvidersMutation();
  const providers = providersQuery.data?.providers || [];
  const detectedList: Array<{ name: string; detected: boolean; path: string }> = detectedQuery.data?.detected_providers || [];
  const detectedCLIs = detectedList.filter((item) => item.detected);
  const capabilities = useMemo(() => normalizeBridgeCapabilities(selectedBridge), [selectedBridge]);
  const [actionError, setActionError] = useState('');
  const [defaultBusy, setDefaultBusy] = useState('');
  const [defaultOverride, setDefaultOverride] = useState<{ provider: string; tier: string } | null>(null);

  // Add Custom Provider Modal state
  const [isAddCustomOpen, setIsAddCustomOpen] = useState(false);
  const [customForm, setCustomForm] = useState<ProviderForm>(emptyForm);
  const [customDefaultTier, setCustomDefaultTier] = useState<string>('normal');
  const [customSaving, setCustomSaving] = useState(false);
  const [customError, setCustomError] = useState('');

  useEffect(() => {
    if (!selectedBridgeId && bridges.length > 0) setSelectedBridgeId(bridgeId(bridges[0]));
  }, [bridges, selectedBridgeId]);

  useEffect(() => { setDefaultOverride(null); }, [selectedId]);

  const currentDefaults = useMemo(() => defaultOverride || providerDefault(providersQuery.data, providers), [defaultOverride, providersQuery.data, providers]);

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

  async function saveDefaults(provider: string, tier: string) {
    if (!selectedId || offline || !provider || !tier || defaultBusy) return;
    setActionError('');
    setDefaultBusy(`${provider}:${tier}`);
    setDefaultOverride({ provider, tier });
    try {
      await setDefaults({ bridgeId: selectedId, provider, tier }).unwrap();
      await providersQuery.refetch();
      await bridgesQuery.refetch();
    } catch (err: any) {
      setDefaultOverride(null);
      setActionError(String(err?.message || 'Default save failed'));
    } finally {
      setDefaultBusy('');
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

  async function handleSaveInline(updatedProfile: any, defaultTier?: string, setAsDefault?: boolean) {
    if (!selectedId || offline) return;
    setActionError('');
    await upsertProvider({ bridgeId: selectedId, name: updatedProfile.name, profile: updatedProfile }).unwrap();
    if (setAsDefault && defaultTier) {
      await setDefaults({ bridgeId: selectedId, provider: updatedProfile.name, tier: defaultTier }).unwrap();
    }
    await providersQuery.refetch();
    await bridgesQuery.refetch();
  }

  async function saveCustomModalProvider() {
    const newName = customForm.name.trim();
    if (!selectedId || !newName) return;
    setCustomSaving(true);
    setCustomError('');
    try {
      const profile = profileFromForm(customForm);
      await upsertProvider({ bridgeId: selectedId, name: newName, profile }).unwrap();
      if (customDefaultTier) {
        await setDefaults({ bridgeId: selectedId, provider: newName, tier: customDefaultTier }).unwrap();
      }
      dispatch(bridgeSupportApi.util.invalidateTags([
        { type: 'BridgeProviders', id: selectedId },
        { type: 'Bridges', id: 'LIST' },
        { type: 'Bridges', id: selectedId },
      ]));
      await providersQuery.refetch();
      await bridgesQuery.refetch();
      setIsAddCustomOpen(false);
    } catch (err: any) {
      setCustomError(String(err?.message || 'Failed to add custom provider'));
    } finally {
      setCustomSaving(false);
    }
  }

  const isNewProvider = route === '/settings/providers/new' || route === '/settings/models/new';
  const isEditProvider =
    (route.startsWith('/settings/providers/') && route.endsWith('/edit')) ||
    (route.startsWith('/settings/models/') && route.endsWith('/edit'));

  if (isNewProvider) {
    return <ProviderEditorPage />;
  }

  if (isEditProvider) {
    const prefix = route.startsWith('/settings/providers/')
      ? '/settings/providers/'
      : '/settings/models/';
    const providerName = decodeURIComponent(route.slice(prefix.length, -'/edit'.length));
    return <ProviderEditorPage providerName={providerName} />;
  }

  void resolveProviderPanelView;

  return (
    <PageShell
      title="Providers"
      description="Configure provider profiles on the selected Bridge. Providers run in your machine's shell environment; Heimdall never stores credentials."
      actions={
        <Button variant="secondary" data-debug-id="providers-refresh-caps-btn" onClick={() => void refreshCapabilities()} disabled={!selectedId || offline} className="min-h-[44px] w-full sm:w-auto">Refresh capabilities</Button>
      }
    >
      <div className="space-y-6 text-left">
      <div className="rounded-2xl border border-subtle bg-surface-raised/40 p-4">
        {bridges.length > 0 && (
          <div data-debug-id="providers-bridge-tabs" className="mb-4">
            <div className="text-xs font-semibold uppercase tracking-wider text-muted mb-2">Connected Bridges</div>
            <Tabs value={selectedId} onChange={setSelectedBridgeId} variant="pill">
              <TabsList label="Bridges">
                {bridges.map((bridge: any) => {
                  const bId = bridgeId(bridge);
                  const isOnline = String(bridge.status || '').toLowerCase() === 'online';
                  return (
                    <Tab key={bId} value={bId} data-debug-id={`providers-bridge-tab-${bId}`}>
                      <span className="inline-flex items-center gap-2">
                        <StatusDot tone={isOnline ? 'success' : 'neutral'} label={isOnline ? 'Online' : 'Offline'} />
                        <span>{bridge.label || bridge.machine_hostname || bId}</span>
                        <span className="text-[10px] text-muted">{isOnline ? 'Online' : 'Offline'}</span>
                      </span>
                    </Tab>
                  );
                })}
              </TabsList>
            </Tabs>
          </div>
        )}
        <FormField label="Bridge">
          <Select data-debug-id="providers-bridge-select" value={selectedId} onChange={setSelectedBridgeId} width="full" className="min-h-[44px]">
            {bridges.map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)} · {bridge.status || 'offline'}</option>)}
          </Select>
        </FormField>
        {bridges.length === 0 ? <div className="mt-3 rounded-xl border border-dashed border-subtle p-4 text-sm text-muted">No bridges connected yet. Add a Bridge first.</div> : null}
        {selectedBridge && offline ? <Alert tone="warning" className="mt-3">bridge_offline: provider edit/test is disabled until this Bridge reconnects.</Alert> : null}
        {capabilities.length > 0 ? <div className="mt-3 text-xs text-muted">Capability matrix: <span className="text-primary">{capabilities.map((cap) => `${cap.provider}${cap.tiers.length ? ` (${cap.tiers.join('/')})` : cap.defaultTier ? ` (${cap.defaultTier})` : ''}`).join(', ')}</span></div> : null}
        {providers.length > 0 ? <div className="mt-3 rounded-xl border border-subtle bg-surface-raised/30 p-3 text-xs text-muted">Bridge default: <span className="text-primary">{currentDefaults.provider || '—'} / {currentDefaults.tier || '—'}</span>. Use the radio buttons in provider rows to change it.{defaultBusy ? <span className="ml-2 text-info">Saving…</span> : null}</div> : null}
      </div>

      {actionError ? <Alert tone="danger">{actionError}</Alert> : null}

      {detectedCLIs.length > 0 ? (
        <div data-debug-id="detected-providers-bar" className="rounded-2xl border border-accent/30 bg-accent/5 p-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <div className="text-sm font-semibold text-primary">Detected System CLIs</div>
              <div className="text-xs text-muted">Supported CLIs found in your PATH. Enable them with one click.</div>
            </div>
            {detectedCLIs.some((cli) => !providers.some((p: any) => p.name === cli.name && p.enabled)) ? (
              <Button
                variant="secondary"
                data-debug-id="enable-all-detected-btn"
                disabled={offline || isEnabling}
                onClick={async () => {
                  const toEnable = detectedCLIs
                    .filter((cli) => !providers.some((p: any) => p.name === cli.name && p.enabled))
                    .map((cli) => cli.name);
                  if (toEnable.length === 0) return;
                  setActionError('');
                  try {
                    await enableProviders({ bridgeId: selectedId, providers: toEnable }).unwrap();
                    await providersQuery.refetch();
                    await bridgesQuery.refetch();
                    await detectedQuery.refetch();
                  } catch (err: any) {
                    setActionError(String(err?.message || 'Failed to enable detected providers'));
                  }
                }}
                className="min-h-[36px] text-xs"
              >
                Enable all detected
              </Button>
            ) : null}
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            {detectedCLIs.map((cli) => {
              const isEnabled = providers.some((p: any) => p.name === cli.name && p.enabled);
              return (
                <div
                  key={cli.name}
                  data-debug-id={`detected-provider-chip-${cli.name}`}
                  className={`inline-flex items-center gap-2 rounded-xl border px-3 py-1.5 text-xs ${
                    isEnabled
                      ? 'border-subtle bg-surface-raised/40 text-muted'
                      : 'border-accent/40 bg-surface text-primary'
                  }`}
                >
                  <span className="font-medium text-primary capitalize">{cli.name}</span>
                  {cli.path ? (
                    <span className="max-w-[200px] truncate text-[10px] text-muted font-mono" title={cli.path}>
                      {cli.path}
                    </span>
                  ) : null}
                  {isEnabled ? (
                    <StatusPill tone="success">Enabled</StatusPill>
                  ) : (
                    <button
                      type="button"
                      data-debug-id={`enable-detected-${cli.name}-btn`}
                      disabled={offline || isEnabling}
                      onClick={async () => {
                        setActionError('');
                        try {
                          await enableProviders({ bridgeId: selectedId, providers: [cli.name] }).unwrap();
                          await providersQuery.refetch();
                          await bridgesQuery.refetch();
                          await detectedQuery.refetch();
                        } catch (err: any) {
                          setActionError(String(err?.message || `Failed to enable ${cli.name}`));
                        }
                      }}
                      className="cursor-pointer rounded-lg bg-accent px-2 py-0.5 font-semibold text-accent-fg hover:bg-accent/90"
                    >
                      Enable
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      ) : null}

      <div className="flex flex-wrap items-center justify-end gap-2">
        <Button
          variant="secondary"
          data-debug-id="providers-add-custom-btn"
          onClick={() => {
            setCustomForm(emptyForm);
            setCustomDefaultTier('normal');
            setCustomError('');
            setIsAddCustomOpen(true);
          }}
          disabled={!selectedId || offline}
          className="min-h-[44px] w-full sm:w-auto"
        >
          Add Custom Provider
        </Button>
        <a
          data-debug-id="providers-add-btn"
          href={shellHash(`/settings/providers/new?bridge=${encodeURIComponent(selectedId)}`)}
          aria-disabled={!selectedId || offline}
          className={`inline-flex min-h-[44px] w-full items-center justify-center rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg hover:bg-accent/90 sm:w-auto ${
            !selectedId || offline ? 'pointer-events-none opacity-50' : ''
          }`}
        >
          Add provider
        </a>
      </div>

      {/* Modal for Add Custom Provider */}
      <Modal open={isAddCustomOpen} onOpenChange={setIsAddCustomOpen} title="Add Custom Provider" size="lg">
        <ModalBody className="space-y-4">
          {customError ? <Alert tone="danger">{customError}</Alert> : null}
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField label="Provider Name">
              <Input
                data-debug-id="custom-modal-name-input"
                value={customForm.name}
                onChange={(name) => setCustomForm({ ...customForm, name })}
                placeholder="my-provider"
                width="full"
                className="min-h-[44px]"
              />
            </FormField>
            <label className="flex items-center gap-2 pt-6 text-sm text-muted">
              <Checkbox checked={customForm.enabled} onChange={(enabled) => setCustomForm({ ...customForm, enabled })} /> Enabled
            </label>
          </div>
          <div>
            <div className="text-sm font-semibold text-primary">Model Tiers</div>
            <div className="text-xs text-muted mb-2">Assign model identifiers for Cheap, Normal, and Smart tiers.</div>
            <div className="grid gap-3 sm:grid-cols-3">
              <FormField label="Cheap / Fast model">
                <Input
                  data-debug-id="custom-modal-models-cheap-input"
                  value={customForm.modelsCheap}
                  onChange={(modelsCheap) => setCustomForm({ ...customForm, modelsCheap })}
                  placeholder="model-cheap"
                  width="full"
                  className="min-h-[44px]"
                />
              </FormField>
              <FormField label="Normal / Balanced model">
                <Input
                  data-debug-id="custom-modal-models-normal-input"
                  value={customForm.modelsNormal}
                  onChange={(modelsNormal) => setCustomForm({ ...customForm, modelsNormal })}
                  placeholder="model-normal"
                  width="full"
                  className="min-h-[44px]"
                />
              </FormField>
              <FormField label="Smart / Deep Reasoning model">
                <Input
                  data-debug-id="custom-modal-models-smart-input"
                  value={customForm.modelsSmart}
                  onChange={(modelsSmart) => setCustomForm({ ...customForm, modelsSmart })}
                  placeholder="model-smart"
                  width="full"
                  className="min-h-[44px]"
                />
              </FormField>
            </div>
          </div>
          <FormField label="Default tier" hint="Select the default tier for this provider.">
            <div className="flex flex-wrap gap-4 pt-1">
              {(['cheap', 'normal', 'smart'] as const).map((tier) => (
                <label key={tier} className="flex items-center gap-2 text-sm text-primary cursor-pointer capitalize">
                  <Radio
                    name="custom-modal-default-tier"
                    value={tier}
                    checked={customDefaultTier === tier}
                    onChange={() => setCustomDefaultTier(tier)}
                  />
                  {tier}
                </label>
              ))}
            </div>
          </FormField>
          <Accordion type="single" className="border-0 divide-y-0 pt-2">
            <AccordionItem value="advanced" title="Advanced settings" className="rounded-xl border border-subtle bg-surface-raised/20 px-3">
              <div className="space-y-4 pt-2">
                <ChipListInput prefix="custom-modal-command" label="Command argv" placeholder="my-cli" values={customForm.command} onChange={(command) => setCustomForm({ ...customForm, command })} />
                <div className="grid gap-4 sm:grid-cols-2">
                  <FormField label="Model flag">
                    <Input value={customForm.modelsFlag} onChange={(modelsFlag) => setCustomForm({ ...customForm, modelsFlag })} placeholder="--model" width="full" className="min-h-[44px]" />
                  </FormField>
                  <FormField label="Skill directory">
                    <Input value={customForm.skillDir} onChange={(skillDir) => setCustomForm({ ...customForm, skillDir })} placeholder=".agents/skills" width="full" className="min-h-[44px]" />
                  </FormField>
                  <FormField label="Prompt delivery">
                    <Input value={customForm.promptDelivery} onChange={(promptDelivery) => setCustomForm({ ...customForm, promptDelivery })} placeholder="flag-injection" width="full" className="min-h-[44px]" />
                  </FormField>
                  <FormField label="Bootstrap file name">
                    <Input value={customForm.bootstrapFileName} onChange={(bootstrapFileName) => setCustomForm({ ...customForm, bootstrapFileName })} placeholder="AGENTS.md" width="full" className="min-h-[44px]" />
                  </FormField>
                </div>
                <ChipListInput prefix="custom-modal-prompt-flags" label="Prompt flags" placeholder="--prompt" values={customForm.promptFlags} onChange={(promptFlags) => setCustomForm({ ...customForm, promptFlags })} />
                <ChipListInput prefix="custom-modal-yolo-flags" label="Yolo/permission flags" placeholder="--dangerously-skip-permissions" values={customForm.yoloFlags} onChange={(yoloFlags) => setCustomForm({ ...customForm, yoloFlags })} />
                <FormField label="Starter prompt">
                  <Textarea value={customForm.starterPrompt} onChange={(starterPrompt) => setCustomForm({ ...customForm, starterPrompt })} placeholder="You are running under Heimdall. Say start-success when ready." width="full" className="h-20" />
                </FormField>
              </div>
            </AccordionItem>
          </Accordion>
        </ModalBody>
        <ModalFooter>
          <Button variant="secondary" onClick={() => setIsAddCustomOpen(false)}>Cancel</Button>
          <Button
            variant="primary"
            data-debug-id="custom-modal-save-btn"
            onClick={() => void saveCustomModalProvider()}
            disabled={customSaving || !customForm.name.trim()}
          >
            {customSaving ? 'Saving…' : 'Save provider'}
          </Button>
        </ModalFooter>
      </Modal>

      {providersQuery.isLoading ? <div className="rounded-xl bg-surface-raised/40 p-5 text-sm text-muted">Loading providers…</div> : null}
      {!offline && providers.length === 0 && !providersQuery.isLoading ? <div className="rounded-xl border border-dashed border-subtle p-8 text-center text-sm text-muted">No provider profiles reported by this Bridge.</div> : null}

      <div className="space-y-4">
        {providers.map((profile: any) => {
          const name = String(profile.name || '');
          return (
            <ProviderCard
              key={name}
              profile={profile}
              selectedId={selectedId}
              offline={offline}
              currentDefaults={currentDefaults}
              defaultBusy={defaultBusy}
              onSaveDefaults={saveDefaults}
              onToggleEnabled={toggleEnabled}
              onRemoveProvider={removeProvider}
              onSaveInline={handleSaveInline}
            />
          );
        })}
      </div>
      </div>
    </PageShell>
  );
}

function ProviderCard({
  profile,
  selectedId,
  offline,
  currentDefaults,
  defaultBusy,
  onSaveDefaults,
  onToggleEnabled,
  onRemoveProvider,
  onSaveInline,
}: {
  profile: any;
  selectedId: string;
  offline: boolean;
  currentDefaults: { provider: string; tier: string };
  defaultBusy: string;
  onSaveDefaults: (provider: string, tier: string) => Promise<void>;
  onToggleEnabled: (profile: any) => Promise<void>;
  onRemoveProvider: (profile: any) => Promise<void>;
  onSaveInline: (updatedProfile: any, defaultTier?: string, setAsDefault?: boolean) => Promise<void>;
}) {
  const name = String(profile.name || '');
  const tiers = configuredTiers(profile);
  const matchedPreset = useMemo(
    () => getProviderPreset((profile.command && profile.command[0]) || name),
    [profile.command, name]
  );

  const [cheap, setCheap] = useState(String(profile.models?.cheap || ''));
  const [normal, setNormal] = useState(String(profile.models?.normal || ''));
  const [smart, setSmart] = useState(String(profile.models?.smart || ''));
  const [commandStr, setCommandStr] = useState((profile.command || []).join(' '));
  const [modelsFlag, setModelsFlag] = useState(String(profile.models?.flag || ''));
  const [skillDir, setSkillDir] = useState(String(profile.skill_dir || ''));
  const [promptDelivery, setPromptDelivery] = useState(String(profile.prompt_delivery || ''));
  const [promptFlagsStr, setPromptFlagsStr] = useState((profile.prompt_flags || []).join(' '));

  const [cardDefaultTier, setCardDefaultTier] = useState<string>(() => {
    if (currentDefaults.provider === name && currentDefaults.tier) return currentDefaults.tier;
    return profile.default_tier || (tiers.length > 0 ? tiers[0] : 'normal');
  });

  const [isSaving, setIsSaving] = useState(false);
  const [saveStatus, setSaveStatus] = useState<'idle' | 'saved' | 'error'>('idle');
  const [errorMessage, setErrorMessage] = useState('');

  useEffect(() => {
    setCheap(String(profile.models?.cheap || ''));
    setNormal(String(profile.models?.normal || ''));
    setSmart(String(profile.models?.smart || ''));
    setCommandStr((profile.command || []).join(' '));
    setModelsFlag(String(profile.models?.flag || ''));
    setSkillDir(String(profile.skill_dir || ''));
    setPromptDelivery(String(profile.prompt_delivery || ''));
    setPromptFlagsStr((profile.prompt_flags || []).join(' '));
  }, [profile]);

  useEffect(() => {
    if (currentDefaults.provider === name && currentDefaults.tier) {
      setCardDefaultTier(currentDefaults.tier);
    }
  }, [currentDefaults, name]);

  const isDefault = currentDefaults.provider === name;

  async function handleInlineSave() {
    if (!selectedId || offline) return;
    setIsSaving(true);
    setSaveStatus('idle');
    setErrorMessage('');
    try {
      const updatedProfile = {
        ...profile,
        command: commandStr.trim() ? commandStr.trim().split(/\s+/) : profile.command,
        models: {
          ...profile.models,
          flag: modelsFlag.trim() || profile.models?.flag || '--model',
          cheap: cheap.trim(),
          normal: normal.trim(),
          smart: smart.trim(),
        },
        skill_dir: skillDir.trim(),
        prompt_delivery: promptDelivery.trim() || profile.prompt_delivery,
        prompt_flags: promptFlagsStr.trim() ? promptFlagsStr.trim().split(/\s+/) : profile.prompt_flags,
      };
      await onSaveInline(updatedProfile, cardDefaultTier, isDefault);
      setSaveStatus('saved');
      setTimeout(() => setSaveStatus('idle'), 3000);
    } catch (err: any) {
      setSaveStatus('error');
      setErrorMessage(String(err?.message || 'Save failed'));
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <div data-debug-id={`providers-provider-row-${name}`} className="rounded-2xl border border-subtle bg-surface-raised/40 p-4 space-y-4">
      {/* Header: Name, badges, and actions */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="font-semibold text-primary">{name}</h3>
          <Badge data-debug-id={`provider-source-badge-${name}`} tone="neutral">
            {profile.source || 'config'}
          </Badge>
          <StatusPill tone={profile.enabled ? 'success' : 'neutral'}>
            {profile.enabled ? 'Enabled' : 'Disabled'}
          </StatusPill>
        </div>
        <div className="grid w-full grid-cols-2 gap-2 sm:flex sm:w-auto sm:flex-wrap">
          <Button
            variant="secondary"
            data-debug-id={`providers-enabled-toggle-${name}`}
            onClick={() => void onToggleEnabled(profile)}
            disabled={offline}
            className="min-h-[38px] text-xs"
          >
            {profile.enabled ? 'Disable' : 'Enable'}
          </Button>
          <a
            data-debug-id={`providers-edit-btn-${name}`}
            href={shellHash(`/settings/providers/${encodeURIComponent(name)}/edit?bridge=${encodeURIComponent(selectedId)}`)}
            aria-disabled={offline}
            className={`inline-flex min-h-[38px] items-center justify-center rounded-lg border border-subtle px-3 py-1.5 text-xs text-muted hover:bg-neutral-soft ${
              offline ? 'pointer-events-none opacity-50' : ''
            }`}
          >
            Edit
          </a>
          <a
            data-debug-id={`providers-duplicate-btn-${name}`}
            href={shellHash(`/settings/providers/new?bridge=${encodeURIComponent(selectedId)}&duplicateFrom=${encodeURIComponent(name)}`)}
            aria-disabled={offline}
            className={`inline-flex min-h-[38px] items-center justify-center rounded-lg border border-subtle px-3 py-1.5 text-xs text-muted hover:bg-neutral-soft ${
              offline ? 'pointer-events-none opacity-50' : ''
            }`}
          >
            Duplicate
          </a>
          <Button
            variant="danger"
            data-debug-id={`providers-delete-btn-${name}`}
            onClick={() => void onRemoveProvider(profile)}
            disabled={offline || profile.source !== 'store'}
            className="min-h-[38px] text-xs"
          >
            Delete
          </Button>
        </div>
      </div>

      {/* Model Tier Inputs: Cheap, Normal, Smart */}
      <div>
        <div className="text-xs font-semibold uppercase tracking-wider text-muted mb-2">Model Tiers</div>
        <div className="grid gap-3 sm:grid-cols-3">
          <FormField label="Cheap / Fast model">
            <Input
              data-debug-id={`providers-card-cheap-input-${name}`}
              value={cheap}
              onChange={setCheap}
              placeholder={matchedPreset?.defaultTiers.cheap || 'model-cheap'}
              width="full"
              className="min-h-[38px] text-xs"
            />
          </FormField>
          <FormField label="Normal / Balanced model">
            <Input
              data-debug-id={`providers-card-normal-input-${name}`}
              value={normal}
              onChange={setNormal}
              placeholder={matchedPreset?.defaultTiers.normal || 'model-normal'}
              width="full"
              className="min-h-[38px] text-xs"
            />
          </FormField>
          <FormField label="Smart / Deep Reasoning model">
            <Input
              data-debug-id={`providers-card-smart-input-${name}`}
              value={smart}
              onChange={setSmart}
              placeholder={matchedPreset?.defaultTiers.smart || 'model-smart'}
              width="full"
              className="min-h-[38px] text-xs"
            />
          </FormField>
        </div>
      </div>

      {/* Default Tier Selector & Save Changes Row */}
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl bg-surface-raised/30 px-3 py-2 text-xs text-muted">
        <div className="flex flex-wrap items-center gap-4">
          <label data-debug-id={`providers-default-btn-${name}`} className="flex items-center gap-2 cursor-pointer font-medium text-primary">
            <Radio
              name="bridge-default-provider"
              checked={isDefault}
              disabled={Boolean(defaultBusy) || offline}
              onChange={() => void onSaveDefaults(name, cardDefaultTier)}
            />
            Default provider
          </label>
          <div className="flex items-center gap-3">
            <span className="text-muted">Default tier:</span>
            {(['cheap', 'normal', 'smart'] as const).map((tier) => (
              <label key={tier} className="flex items-center gap-1.5 cursor-pointer capitalize text-primary">
                <Radio
                  name={`card-default-tier-${name}`}
                  value={tier}
                  checked={cardDefaultTier === tier}
                  disabled={offline}
                  onChange={() => {
                    setCardDefaultTier(tier);
                    if (isDefault) void onSaveDefaults(name, tier);
                  }}
                />
                {tier}
              </label>
            ))}
          </div>
        </div>
        <div className="flex items-center gap-2">
          {saveStatus === 'saved' ? <span className="text-xs font-medium text-success">Saved</span> : null}
          {saveStatus === 'error' ? <span className="text-xs text-danger">{errorMessage}</span> : null}
          <Button
            variant="secondary"
            data-debug-id={`providers-inline-save-btn-${name}`}
            onClick={() => void handleInlineSave()}
            disabled={offline || isSaving}
            className="min-h-[34px] text-xs font-semibold"
          >
            {isSaving ? 'Saving…' : 'Save Changes'}
          </Button>
        </div>
      </div>

      {/* Expandable Advanced Settings Accordion */}
      <Accordion type="single" className="border-0 divide-y-0">
        <AccordionItem value="advanced" title="Advanced settings" className="rounded-xl border border-subtle bg-surface-raised/20 px-3">
          <div className="space-y-3 pt-2 text-xs">
            <div className="grid gap-3 sm:grid-cols-2">
              <FormField label="Command executable / argv">
                <Input
                  data-debug-id={`providers-card-command-input-${name}`}
                  value={commandStr}
                  onChange={setCommandStr}
                  placeholder="command executable and arguments"
                  width="full"
                  className="min-h-[36px] font-mono text-xs"
                />
              </FormField>
              <FormField label="Model flag">
                <Input
                  data-debug-id={`providers-card-models-flag-input-${name}`}
                  value={modelsFlag}
                  onChange={setModelsFlag}
                  placeholder="--model"
                  width="full"
                  className="min-h-[36px] font-mono text-xs"
                />
              </FormField>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              <FormField label="Skill directory">
                <Input
                  data-debug-id={`providers-card-skill-dir-input-${name}`}
                  value={skillDir}
                  onChange={setSkillDir}
                  placeholder=".agents/skills"
                  width="full"
                  className="min-h-[36px] text-xs"
                />
              </FormField>
              <FormField label="Prompt delivery">
                <Input
                  data-debug-id={`providers-card-prompt-delivery-input-${name}`}
                  value={promptDelivery}
                  onChange={setPromptDelivery}
                  placeholder="flag-injection"
                  width="full"
                  className="min-h-[36px] text-xs"
                />
              </FormField>
            </div>
            <FormField label="Prompt flags">
              <Input
                data-debug-id={`providers-card-prompt-flags-input-${name}`}
                value={promptFlagsStr}
                onChange={setPromptFlagsStr}
                placeholder="--prompt -p"
                width="full"
                className="min-h-[36px] text-xs font-mono"
              />
            </FormField>
            {profile.bootstrap_file_name ? (
              <div className="text-muted">Bootstrap file: <span className="font-mono text-primary">{profile.bootstrap_file_name}</span></div>
            ) : null}
            {profile.startup_detection ? (
              <div className="text-muted">Startup detection: <span className="text-primary">{profile.startup_detection.enabled ? 'Enabled' : 'Disabled'}</span> (probe: {profile.startup_detection.startup_probe_seconds || 20}s, capture: {profile.startup_detection.capture_interval_ms || 500}ms)</div>
            ) : null}
            {profile.activity_detection ? (
              <div className="text-muted">Activity detection: <span className="text-primary">{profile.activity_detection.enabled ? 'Enabled' : 'Disabled'}</span> (check: {profile.activity_detection.check_interval_seconds || 2}s, min gap: {profile.activity_detection.min_gap_ms || 250}ms)</div>
            ) : null}
          </div>
        </AccordionItem>
      </Accordion>
    </div>
  );
}

export function ProviderEditorPage({ providerName = '' }: { providerName?: string }) {
  const dispatch = useDispatch();
  const isEdit = Boolean(providerName);
  const isBuiltin = isEdit && BUILTIN_PROVIDERS.includes(providerName.toLowerCase().trim());
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const bridges = (bridgesQuery.data?.bridges || []).filter((b: any) => String(b?.status || b?.runtime_status || '').toLowerCase() !== 'revoked' && !b?.revoked_at);
  const [selectedBridgeId, setSelectedBridgeId] = useState('');
  const selectedBridge = bridges.find((bridge: any) => bridgeId(bridge) === selectedBridgeId) || bridges[0];
  const selectedId = selectedBridge ? bridgeId(selectedBridge) : '';
  const offline = selectedBridge ? String(selectedBridge.status || '').toLowerCase() !== 'online' : true;
  const providersQuery = useListBridgeProvidersQuery({ bridgeId: selectedId }, { skip: !selectedId || offline });
  const providers = providersQuery.data?.providers || [];
  const currentProfile = providers.find((profile: any) => String(profile.name || '') === providerName);

  const [routeSearch, setRouteSearch] = useState(() => getRouteSearch());

  useEffect(() => {
    const handleHash = () => setRouteSearch(getRouteSearch());
    window.addEventListener('hashchange', handleHash);
    window.addEventListener('popstate', handleHash);
    return () => {
      window.removeEventListener('hashchange', handleHash);
      window.removeEventListener('popstate', handleHash);
    };
  }, []);

  const searchParams = useMemo(() => new URLSearchParams(routeSearch), [routeSearch]);
  const duplicateFrom = searchParams.get('duplicateFrom') || '';
  const duplicateProfile = providers.find((profile: any) => String(profile.name || '') === duplicateFrom);

  const [upsertProvider] = useUpsertBridgeProviderMutation();
  const [deleteProvider] = useDeleteBridgeProviderMutation();
  const [setDefaults] = useSetBridgeProviderDefaultsMutation();

  const [form, setForm] = useState<ProviderForm>(() => {
    if (isEdit) return { ...emptyForm, name: providerName };
    if (duplicateFrom) return { ...emptyForm, name: `${duplicateFrom}-copy` };
    return emptyForm;
  });
  const [defaultTier, setDefaultTier] = useState<string>('normal');
  const [selectedPresetKey, setSelectedPresetKey] = useState<string>('custom');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const initializedKeyRef = useRef<string>('');

  const matchedPreset = useMemo(
    () => getProviderPreset(form.command[0] || form.name || providerName),
    [form.command, form.name, providerName]
  );
  const modelSuggestions = useMemo(() => getModelSuggestions(matchedPreset), [matchedPreset]);
  const flagSuggestions = useMemo(() => getFlagSuggestions(matchedPreset), [matchedPreset]);

  function handlePresetChange(key: string) {
    setSelectedPresetKey(key);
    if (key === 'custom') {
      setForm(emptyForm);
    } else if (SUPPORTED_PROVIDER_PRESETS[key]) {
      setForm(formFromPreset(SUPPORTED_PROVIDER_PRESETS[key]));
    }
  }

  useEffect(() => {
    const bridge = searchParams.get('bridge') || '';
    if (!selectedBridgeId && bridge) setSelectedBridgeId(bridge);
    else if (!selectedBridgeId && bridges.length > 0) setSelectedBridgeId(bridgeId(bridges[0]));
  }, [bridges, searchParams, selectedBridgeId]);

  useEffect(() => {
    if (isEdit && currentProfile) {
      const editKey = `edit:${providerName}`;
      if (initializedKeyRef.current !== editKey) {
        initializedKeyRef.current = editKey;
        setForm(formFromProfile(currentProfile));
        const matched = getProviderPreset(currentProfile.command?.[0] || currentProfile.name || providerName);
        if (matched) setSelectedPresetKey(matched.name);
        const curDef = providersQuery.data?.default_provider === providerName
          ? (providersQuery.data?.default_tier || 'normal')
          : (currentProfile.default_tier || 'normal');
        setDefaultTier(curDef);
      }
    } else if (!isEdit && duplicateFrom && duplicateProfile) {
      const dupKey = `duplicate:${duplicateFrom}`;
      if (initializedKeyRef.current !== dupKey) {
        initializedKeyRef.current = dupKey;
        setForm(buildDuplicateForm(duplicateProfile, duplicateFrom));
        const matched = getProviderPreset(duplicateProfile.command?.[0] || duplicateProfile.name);
        if (matched) setSelectedPresetKey(matched.name);
      }
    } else if (!isEdit && !duplicateFrom) {
      if (initializedKeyRef.current && initializedKeyRef.current !== 'new') {
        initializedKeyRef.current = 'new';
        setSelectedPresetKey('custom');
        setForm(emptyForm);
      }
    }
  }, [isEdit, providerName, currentProfile, duplicateFrom, duplicateProfile, providersQuery.data]);

  async function saveProvider() {
    const newName = form.name.trim();
    if (!selectedId || !newName) return;
    setSaving(true);
    setError('');
    try {
      const profile = profileFromForm(form);
      const plan = planSaveProvider({
        isEdit,
        providerName,
        formName: newName,
        currentProfile,
        providersData: providersQuery.data,
        providersList: providers,
        profile,
      });

      // 1. Issue PUT /api/v1/bridges/{bridgeId}/providers/{newName} with the updated profile.
      await upsertProvider({ bridgeId: selectedId, name: newName, profile }).unwrap();

      if (isBuiltin && defaultTier) {
        await setDefaults({ bridgeId: selectedId, provider: newName, tier: defaultTier }).unwrap();
      }

      if (plan.isRenamed) {
        // 2. If the original provider was a store-persisted provider (source === 'store'), issue DELETE /api/v1/bridges/{bridgeId}/providers/{oldName}.
        if (plan.shouldDeleteOld) {
          await deleteProvider({ bridgeId: selectedId, name: plan.oldName }).unwrap();
        }

        // 3. If the original provider was the default provider, update default_provider via POST /api/v1/bridges/{bridgeId}/provider-defaults.
        if (plan.shouldUpdateDefault) {
          await setDefaults({ bridgeId: selectedId, provider: newName, tier: plan.defaultTier }).unwrap();
        }

        // 4. Invalidate RTK Query cache tags (BridgeProviders, Bridges).
        dispatch(bridgeSupportApi.util.invalidateTags([
          { type: 'BridgeProviders', id: selectedId },
          { type: 'Bridges', id: 'LIST' },
          { type: 'Bridges', id: selectedId },
        ]));
      }

      window.location.hash = shellHash('/settings/providers');
    } catch (err: any) {
      setError(String(err?.message || 'Save failed'));
    } finally {
      setSaving(false);
    }
  }

  return (
    <PageShell
      width="full"
      title={isEdit ? `Edit provider ${providerName}` : 'New provider'}
      description="Add values with controls and chips; no JSON, comma lists, or array syntax is typed by users."
      actions={
        <div className="flex items-center gap-2">
          {isEdit ? (
            <a
              data-debug-id="providers-editor-header-duplicate-btn"
              href={shellHash(`/settings/providers/new?bridge=${encodeURIComponent(selectedId)}&duplicateFrom=${encodeURIComponent(providerName)}`)}
              aria-disabled={offline}
              className={`inline-flex min-h-[44px] items-center justify-center rounded-xl bg-neutral-soft px-4 py-2 text-sm text-primary hover:bg-surface-raised ${offline ? 'pointer-events-none opacity-50' : ''}`}
            >
              Duplicate
            </a>
          ) : null}
          <a data-debug-id="providers-editor-header-cancel-btn" href={shellHash('/settings/providers')} className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-neutral-soft px-4 py-2 text-sm text-primary hover:bg-surface-raised">Cancel</a>
        </div>
      }
    >
      <div className="space-y-6 text-left">
      <div className="rounded-2xl border border-subtle bg-surface-raised/40 p-5">
        <FormField label="Bridge"><Select data-debug-id="providers-bridge-select" value={selectedId} onChange={setSelectedBridgeId} width="full" className="min-h-[44px]">{bridges.map((bridge: any) => <option key={bridgeId(bridge)} value={bridgeId(bridge)}>{bridge.label || bridge.machine_hostname || bridgeId(bridge)} · {bridge.status || 'offline'}</option>)}</Select></FormField>
        {offline ? <Alert tone="warning" className="mt-3">This Bridge is offline; saving is disabled until it reconnects.</Alert> : null}
        {error ? <Alert tone="danger" className="mt-3">{error}</Alert> : null}
      </div>
      {!isEdit && (
        <div data-debug-id="providers-preset-picker" className="rounded-2xl border border-subtle bg-surface-raised/40 p-5">
          <FormField label="Start from preset" hint="Choose a supported provider preset to pre-fill commands, flags, and models, or choose Custom.">
            <Select
              data-debug-id="providers-preset-select"
              value={selectedPresetKey}
              onChange={handlePresetChange}
              width="full"
              className="min-h-[44px]"
            >
              <option value="custom">Custom</option>
              <option value="claude">Claude</option>
              <option value="jetski">Jetski</option>
              <option value="antigravity">Antigravity</option>
              <option value="pi">Pi</option>
              <option value="codex">Codex</option>
              <option value="copilot">Copilot</option>
            </Select>
          </FormField>
          <div data-debug-id="providers-preset-chips" className="mt-3 flex flex-wrap gap-2">
            {[
              { key: 'custom', label: 'Custom' },
              { key: 'claude', label: 'Claude' },
              { key: 'jetski', label: 'Jetski' },
              { key: 'antigravity', label: 'Antigravity' },
              { key: 'pi', label: 'Pi' },
              { key: 'codex', label: 'Codex' },
              { key: 'copilot', label: 'Copilot' },
            ].map((p) => (
              <button
                key={p.key}
                type="button"
                data-debug-id={`providers-preset-chip-${p.key}`}
                onClick={() => handlePresetChange(p.key)}
                className={`inline-flex min-h-[36px] items-center rounded-xl px-3 py-1.5 text-xs font-medium cursor-pointer transition-colors ${
                  selectedPresetKey === p.key
                    ? 'bg-accent text-accent-contrast shadow-sm'
                    : 'border border-subtle bg-surface-raised/60 text-muted hover:bg-surface-raised hover:text-primary'
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>
        </div>
      )}
      {isBuiltin ? (
        <div data-debug-id="providers-builtin-editor" className="space-y-5 rounded-2xl border border-subtle bg-surface-raised/40 p-5">
          <div className="flex items-center justify-between">
            <div>
              <h3 className="text-base font-semibold text-primary capitalize">{providerName} Model Configuration</h3>
              <p className="text-xs text-muted">Configure model names and default tier for this built-in provider.</p>
            </div>
            <StatusPill tone="info">Built-in Provider</StatusPill>
          </div>
          <div className="grid gap-4 sm:grid-cols-3">
            <TextInput
              id="providers-editor-models-cheap-input"
              label="Cheap / Fast model"
              value={form.modelsCheap}
              onChange={(modelsCheap) => setForm({ ...form, modelsCheap })}
              placeholder={matchedPreset?.defaultTiers.cheap || "model-cheap"}
              list={matchedPreset ? "models-list" : undefined}
            />
            <TextInput
              id="providers-editor-models-normal-input"
              label="Normal / Balanced model"
              value={form.modelsNormal}
              onChange={(modelsNormal) => setForm({ ...form, modelsNormal })}
              placeholder={matchedPreset?.defaultTiers.normal || "model-normal"}
              list={matchedPreset ? "models-list" : undefined}
            />
            <TextInput
              id="providers-editor-models-smart-input"
              label="Smart / Deep Reasoning model"
              value={form.modelsSmart}
              onChange={(modelsSmart) => setForm({ ...form, modelsSmart })}
              placeholder={matchedPreset?.defaultTiers.smart || "model-smart"}
              list={matchedPreset ? "models-list" : undefined}
            />
          </div>
          {matchedPreset && (
            <datalist id="models-list" data-debug-id="models-list">
              {modelSuggestions.map((m) => (
                <option key={m} value={m} />
              ))}
            </datalist>
          )}
          <FormField label="Default tier" hint="Select which model tier to use by default for this provider.">
            <div data-debug-id="providers-editor-default-tier-selector" className="flex flex-wrap gap-4 pt-1">
              {(['cheap', 'normal', 'smart'] as const).map((tier) => (
                <label key={tier} className="flex items-center gap-2 text-sm text-primary cursor-pointer capitalize">
                  <Radio
                    name="builtin-default-tier"
                    value={tier}
                    checked={defaultTier === tier}
                    onChange={() => setDefaultTier(tier)}
                  />
                  {tier}
                </label>
              ))}
            </div>
          </FormField>
          <Accordion type="single" className="border-0 divide-y-0 pt-2">
            <AccordionItem value="advanced" title="Advanced settings" className="rounded-xl border border-subtle bg-surface-raised/20 px-3">
              <div className="mt-3 space-y-4 pt-2">
                <ChipListInput prefix="providers-editor-command-builtin" label="Command argv" placeholder={providerName} values={form.command} onChange={(command) => setForm({ ...form, command })} />
                <div className="grid gap-4 sm:grid-cols-2">
                  <TextInput
                    id="providers-editor-models-flag-input-builtin"
                    label="Model flag"
                    value={form.modelsFlag}
                    onChange={(modelsFlag) => setForm({ ...form, modelsFlag })}
                    placeholder="--model"
                  />
                  <TextInput id="providers-editor-prompt-delivery-input-builtin" label="Prompt delivery" value={form.promptDelivery} onChange={(promptDelivery) => setForm({ ...form, promptDelivery })} placeholder="flag-injection" />
                  <TextInput id="providers-editor-skill-dir-input-builtin" label="Skill directory" value={form.skillDir} onChange={(skillDir) => setForm({ ...form, skillDir })} placeholder={matchedPreset?.skillDir || ".agents/skills"} />
                  <FormField label="Bootstrap file name" hint="The single bootstrap file this provider’s agent reads on startup."><Input data-debug-id="providers-editor-bootstrap-file-name-input-builtin" value={form.bootstrapFileName} onChange={(value) => setForm({ ...form, bootstrapFileName: value })} placeholder={matchedPreset?.bootstrapFileName || "AGENTS.md"} width="full" className="min-h-[44px]" /></FormField>
                </div>
                <ChipListInput
                  prefix="providers-editor-prompt-flags-builtin"
                  label="Prompt flags"
                  placeholder="--prompt"
                  values={form.promptFlags}
                  onChange={(promptFlags) => setForm({ ...form, promptFlags })}
                  suggestions={flagSuggestions.promptFlags}
                />
                <ChipListInput
                  prefix="providers-editor-yolo-flags-builtin"
                  label="Yolo/permission flags"
                  placeholder="--dangerously-skip-permissions"
                  values={form.yoloFlags}
                  onChange={(yoloFlags) => setForm({ ...form, yoloFlags })}
                  suggestions={flagSuggestions.yoloFlags}
                />
                <FormField label="Starter prompt"><Textarea data-debug-id="providers-editor-starter-prompt-input-builtin" value={form.starterPrompt} onChange={(v) => setForm({ ...form, starterPrompt: v })} placeholder="You are running under Heimdall. Say start-success when ready." width="full" className="h-24" /></FormField>
              </div>
            </AccordionItem>
          </Accordion>
        </div>
      ) : (
        <ProviderFormFields form={form} setForm={setForm} nameLocked={false} />
      )}
      <div className="z-10 flex flex-col-reverse gap-2 rounded-2xl border border-subtle bg-surface/95 p-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] backdrop-blur md:sticky md:bottom-0 sm:flex-row sm:justify-end"><a data-debug-id="providers-editor-footer-cancel-btn" href={shellHash('/settings/providers')} className="inline-flex min-h-[44px] items-center justify-center rounded-xl bg-neutral-soft px-4 py-2 text-sm hover:bg-surface-raised">Cancel</a><Button variant="primary" data-debug-id="providers-editor-save-btn" onClick={() => void saveProvider()} disabled={saving || offline || !form.name.trim()} className="min-h-[44px]">{saving ? 'Saving…' : 'Save provider'}</Button></div>
      </div>
    </PageShell>
  );
}

function ProviderFormFields({
  form,
  setForm,
  nameLocked = false,
}: {
  form: ProviderForm;
  setForm: (form: ProviderForm) => void;
  nameLocked?: boolean;
}) {
  const matchedPreset = useMemo(() => getProviderPreset(form.command[0] || form.name), [form.command, form.name]);

  const flagSuggestions = useMemo(() => getFlagSuggestions(matchedPreset), [matchedPreset]);
  const modelSuggestions = useMemo(() => getModelSuggestions(matchedPreset), [matchedPreset]);

  return (
    <div className="space-y-5 rounded-2xl border border-subtle bg-surface-raised/40 p-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <TextInput id="providers-editor-name-input" label="Name" value={form.name} onChange={(name) => setForm({ ...form, name })} placeholder="pi" disabled={nameLocked} />
        <label className="flex items-center gap-2 pt-6 text-sm text-muted"><Checkbox data-debug-id="providers-enabled-toggle-editor" checked={form.enabled} onChange={(enabled) => setForm({ ...form, enabled })} /> Enabled</label>
      </div>

      <div>
        <div className="text-sm font-semibold text-primary">Model Tiers</div>
        <p className="text-xs text-muted mb-3">Configure model identifiers for Cheap, Normal, and Smart tiers.</p>
        <div className="grid gap-4 sm:grid-cols-3">
          <TextInput
            id="providers-editor-models-cheap-input"
            label="Cheap / Fast model"
            value={form.modelsCheap}
            onChange={(modelsCheap) => setForm({ ...form, modelsCheap })}
            placeholder={matchedPreset?.defaultTiers.cheap || "anthropic/claude-haiku-4-5"}
            list={matchedPreset ? "models-list" : undefined}
          />
          <TextInput
            id="providers-editor-models-normal-input"
            label="Normal / Balanced model"
            value={form.modelsNormal}
            onChange={(modelsNormal) => setForm({ ...form, modelsNormal })}
            placeholder={matchedPreset?.defaultTiers.normal || "anthropic/claude-sonnet-4-6"}
            list={matchedPreset ? "models-list" : undefined}
          />
          <TextInput
            id="providers-editor-models-smart-input"
            label="Smart / Deep Reasoning model"
            value={form.modelsSmart}
            onChange={(modelsSmart) => setForm({ ...form, modelsSmart })}
            placeholder={matchedPreset?.defaultTiers.smart || "anthropic/claude-opus-4-5"}
            list={matchedPreset ? "models-list" : undefined}
          />
        </div>
      </div>

      {matchedPreset && (
        <>
          <datalist id="models-list" data-debug-id="models-list">
            {modelSuggestions.map((m) => (
              <option key={m} value={m} />
            ))}
          </datalist>
          <datalist id="providers-models-list" data-debug-id="providers-models-datalist">
            {modelSuggestions.map((m) => (
              <option key={m} value={m} />
            ))}
          </datalist>
        </>
      )}

      <Accordion type="single" className="border-0 divide-y-0">
        <AccordionItem value="advanced" title="Advanced settings" className="rounded-xl border border-subtle bg-surface-raised/20 px-3">
          <div className="mt-3 space-y-5">
            <ChipListInput prefix="providers-editor-command" label="Command argv" placeholder="pi" values={form.command} onChange={(command) => setForm({ ...form, command })} />
            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <TextInput
                  id="providers-editor-models-flag-input"
                  label="Model flag"
                  value={form.modelsFlag}
                  onChange={(modelsFlag) => setForm({ ...form, modelsFlag })}
                  placeholder="--model"
                  list={matchedPreset ? 'providers-editor-models-flag-datalist' : undefined}
                />
                {matchedPreset && flagSuggestions.modelsFlag.length > 0 && (
                  <div data-debug-id="providers-editor-models-flag-suggestions" className="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs text-muted">
                    <span>Suggestions:</span>
                    {flagSuggestions.modelsFlag.map((flag) => (
                      <button
                        key={flag}
                        type="button"
                        data-debug-id={`providers-editor-models-flag-chip-${flag}`}
                        onClick={() => setForm({ ...form, modelsFlag: flag })}
                        className={`inline-flex min-h-[26px] items-center rounded-md border px-2 py-0.5 text-xs cursor-pointer transition-colors ${
                          form.modelsFlag === flag
                            ? 'border-accent bg-accent/15 text-accent font-medium'
                            : 'border-subtle bg-surface-raised/50 text-muted hover:text-primary hover:bg-surface-raised'
                        }`}
                      >
                        {flag}
                      </button>
                    ))}
                  </div>
                )}
                {matchedPreset && (
                  <datalist id="providers-editor-models-flag-datalist" data-debug-id="providers-editor-models-flag-datalist">
                    {flagSuggestions.modelsFlag.map((flag) => (
                      <option key={flag} value={flag} />
                    ))}
                  </datalist>
                )}
              </div>
              <TextInput id="providers-editor-prompt-delivery-input" label="Prompt delivery" value={form.promptDelivery} onChange={(promptDelivery) => setForm({ ...form, promptDelivery })} placeholder="flag-injection" />
              <TextInput id="providers-editor-skill-dir-input" label="Skill directory" value={form.skillDir} onChange={(skillDir) => setForm({ ...form, skillDir })} placeholder=".pi/skills" />
              <FormField label="Bootstrap file name" hint="The single bootstrap file this provider’s agent reads on startup. Leave blank to keep the profile default (CLAUDE.md for the claude profile, AGENTS.md otherwise). Changing it regenerates the file under the new name and cleans up the old one on the next launch."><Input data-debug-id="providers-editor-bootstrap-file-name-input" value={form.bootstrapFileName} onChange={(value) => setForm({ ...form, bootstrapFileName: value })} placeholder="CLAUDE.md for claude, AGENTS.md otherwise (leave blank to keep default)" width="full" className="min-h-[44px]" /></FormField>
            </div>
            <ChipListInput
              prefix="providers-editor-prompt-flags"
              label="Prompt flags"
              placeholder="--prompt"
              values={form.promptFlags}
              onChange={(promptFlags) => setForm({ ...form, promptFlags })}
              suggestions={flagSuggestions.promptFlags}
            />
            <ChipListInput
              prefix="providers-editor-yolo-flags"
              label="Yolo/permission flags"
              placeholder="--dangerously-skip-permissions"
              values={form.yoloFlags}
              onChange={(yoloFlags) => setForm({ ...form, yoloFlags })}
              suggestions={flagSuggestions.yoloFlags}
            />
            <FormField label="Starter prompt"><Textarea data-debug-id="providers-editor-starter-prompt-input" value={form.starterPrompt} onChange={(v) => setForm({ ...form, starterPrompt: v })} placeholder="You are running under Heimdall. Say start-success when ready." width="full" className="h-24" /></FormField>
            <div data-debug-id="providers-editor-startup-help" className="rounded-xl border border-subtle bg-surface-raised/30 p-3 text-xs text-muted">
              <div className="text-sm font-medium text-primary">Startup detection</div>
              <p className="mt-1 text-muted">On startup the wrapper watches the agent&apos;s terminal pane for known prompts and auto-dismisses/answers them so the agent reaches its ready state without a human. The controls below tune that behavior:</p>
              <ul className="mt-2 space-y-1 text-muted">
                <li><span className="text-primary">Startup detection</span> — master on/off switch for this pane-watching behavior.</li>
                <li><span className="text-primary">Unknown startup is blocked</span> — if the pane shows something unrecognized, treat it as &quot;stuck, needs a human&quot; instead of assuming it&apos;s fine.</li>
                <li><span className="text-primary">Startup probe seconds</span> — how long to keep watching the pane for prompts after launch.</li>
                <li><span className="text-primary">Capture interval ms</span> — how often to sample/re-read the pane while probing.</li>
                <li><span className="text-primary">Blocked patterns</span> — text that means &quot;stuck, needs a human&quot;; if seen, the agent is marked blocked rather than auto-answered.</li>
                <li><span className="text-primary">Auto-enter pattern + pre-key pairs</span> — when the pane matches a Pattern, send the Pre-key(s) and then Enter (see the section below for details and examples).</li>
                <li><span className="text-primary">Sanitized reason mapping</span> — maps an internal key to a human-readable &quot;why blocked&quot; reason shown in the UI.</li>
              </ul>
            </div>
            <div className="grid gap-4 sm:grid-cols-2"><label className="flex items-center gap-2 text-sm text-muted"><Checkbox data-debug-id="providers-editor-startup-enabled-checkbox" checked={form.startupEnabled} onChange={(startupEnabled) => setForm({ ...form, startupEnabled })} /> Startup detection</label><label className="flex items-center gap-2 text-sm text-muted"><Checkbox data-debug-id="providers-editor-startup-unknown-blocked-checkbox" checked={form.startupUnknownIsBlocked} onChange={(startupUnknownIsBlocked) => setForm({ ...form, startupUnknownIsBlocked })} /> Unknown startup is blocked</label><NumberInput id="providers-editor-startup-probe-input" label="Startup probe seconds" value={form.startupProbeSeconds} onChange={(startupProbeSeconds) => setForm({ ...form, startupProbeSeconds })} placeholder="20" min={0} /><NumberInput id="providers-editor-startup-capture-interval-input" label="Capture interval ms" value={form.startupCaptureIntervalMs} onChange={(startupCaptureIntervalMs) => setForm({ ...form, startupCaptureIntervalMs })} placeholder="500" min={0} /></div>
            <ChipListInput prefix="providers-editor-startup-blocked-patterns" label="Blocked patterns" placeholder="Yes, I trust this folder" values={form.startupBlockedPatterns} onChange={(startupBlockedPatterns) => setForm({ ...form, startupBlockedPatterns })} />
            <PairedListInput pairs={form.startupAutoEnterPairs} onChange={(startupAutoEnterPairs) => setForm({ ...form, startupAutoEnterPairs })} />
            <ReasonMappingInput rows={form.startupReasonMappings} onChange={(startupReasonMappings) => setForm({ ...form, startupReasonMappings })} />
            <div className="grid gap-4 sm:grid-cols-2"><label className="flex items-center gap-2 text-sm text-muted"><Checkbox data-debug-id="providers-editor-activity-enabled-checkbox" checked={form.activityEnabled} onChange={(activityEnabled) => setForm({ ...form, activityEnabled })} /> Activity detection</label><NumberInput id="providers-editor-activity-sample-lines-input" label="Activity sample lines" value={form.activitySampleLines} onChange={(activitySampleLines) => setForm({ ...form, activitySampleLines })} placeholder="20" min={0} /><NumberInput id="providers-editor-activity-ignore-bottom-input" label="Ignore bottom lines" value={form.activityIgnoreBottomLines} onChange={(activityIgnoreBottomLines) => setForm({ ...form, activityIgnoreBottomLines })} placeholder="0" min={0} /><NumberInput id="providers-editor-activity-check-interval-input" label="Check interval seconds" value={form.activityCheckIntervalSeconds} onChange={(activityCheckIntervalSeconds) => setForm({ ...form, activityCheckIntervalSeconds })} placeholder="2" min={0} /><NumberInput id="providers-editor-activity-min-gap-input" label="Min gap ms" value={form.activityMinGapMs} onChange={(activityMinGapMs) => setForm({ ...form, activityMinGapMs })} placeholder="250" min={0} /><NumberInput id="providers-editor-activity-max-gap-input" label="Max gap ms" value={form.activityMaxGapMs} onChange={(activityMaxGapMs) => setForm({ ...form, activityMaxGapMs })} placeholder="5000" min={0} /></div>
          </div>
        </AccordionItem>
      </Accordion>
    </div>
  );
}

export function ChipListInput({
  prefix,
  label,
  placeholder,
  values,
  onChange,
  suggestions = [],
}: {
  prefix: string;
  label: string;
  placeholder: string;
  values: string[];
  onChange: (values: string[]) => void;
  suggestions?: string[];
}) {
  const [draft, setDraft] = useState('');
  function add(val?: string) {
    const next = (val !== undefined ? val : draft).trim();
    if (!next) return;
    if (!values.includes(next)) {
      onChange([...values, next]);
    }
    if (val === undefined) setDraft('');
  }
  const unaddedSuggestions = suggestions.filter((s) => !values.includes(s));
  return (
    <div className="rounded-xl border border-subtle bg-surface-raised/30 p-3">
      <div className="text-sm font-medium text-primary">{label}</div>
      <div className="mt-2 flex flex-col gap-2 sm:flex-row">
        <Input
          data-debug-id={`${prefix}-chip-input`}
          value={draft}
          onChange={setDraft}
          list={suggestions.length > 0 ? `${prefix}-datalist` : undefined}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              add();
            }
          }}
          placeholder={placeholder}
          className="min-h-[44px] min-w-0 flex-1"
        />
        <Button variant="secondary" data-debug-id={`${prefix}-chip-add-btn`} onClick={() => add()} className="min-h-[44px]">Add</Button>
      </div>
      {suggestions.length > 0 && (
        <datalist id={`${prefix}-datalist`} data-debug-id={`${prefix}-datalist`}>
          {suggestions.map((s) => <option key={s} value={s} />)}
        </datalist>
      )}
      {unaddedSuggestions.length > 0 && (
        <div data-debug-id={`${prefix}-suggestions`} className="mt-2 flex flex-wrap items-center gap-1.5 text-xs text-muted">
          <span>Suggestions:</span>
          {unaddedSuggestions.map((s, index) => (
            <button
              key={`${s}-${index}`}
              data-debug-id={`${prefix}-suggestion-chip-${index}`}
              type="button"
              onClick={() => add(s)}
              className="inline-flex min-h-[28px] items-center gap-1 rounded-full border border-subtle bg-surface-raised/60 px-2.5 py-0.5 text-xs text-primary hover:bg-surface-raised hover:text-accent cursor-pointer transition-colors"
            >
              + {s}
            </button>
          ))}
          <button
            data-debug-id={`${prefix}-insert-recommended-btn`}
            type="button"
            onClick={() => {
              const toAdd = unaddedSuggestions.filter((s) => !values.includes(s));
              if (toAdd.length > 0) onChange([...values, ...toAdd]);
            }}
            className="inline-flex min-h-[28px] items-center gap-1 rounded-full border border-accent/40 bg-accent/10 px-2.5 py-0.5 text-xs font-medium text-accent hover:bg-accent/20 cursor-pointer transition-colors"
          >
            Insert recommended flags
          </button>
        </div>
      )}
      <div className="mt-2 flex flex-wrap gap-2">
        {values.map((value, index) => (
          <span key={`${value}-${index}`} data-debug-id={`${prefix}-chip-${index}`} className="inline-flex min-h-[36px] max-w-full items-center gap-2 rounded-full bg-neutral-soft px-3 py-1 text-xs text-primary">
            <span className="min-w-0 break-all">{value}</span>
            <button data-debug-id={`${prefix}-chip-remove-btn-${index}`} type="button" onClick={() => onChange(values.filter((_, i) => i !== index))} className="min-h-[32px] min-w-[32px] text-muted hover:text-primary cursor-pointer">x</button>
          </span>
        ))}
      </div>
    </div>
  );
}

function PairedListInput({ pairs, onChange }: { pairs: AutoEnterPair[]; onChange: (pairs: AutoEnterPair[]) => void }) {
  const [pattern, setPattern] = useState(''); const [preKey, setPreKey] = useState('');
  function add() { const p = pattern.trim(); const k = preKey.trim(); if (!p && !k) return; onChange([...pairs, { pattern: p, preKey: k }]); setPattern(''); setPreKey(''); }
  return <div className="rounded-xl border border-subtle bg-surface-raised/30 p-3"><div className="text-sm font-medium text-primary">Auto-enter pattern + pre-key pairs</div><p data-debug-id="providers-editor-startup-auto-enter-help" className="mt-1 text-xs text-muted">When the pane text matches the <span className="text-primary">Pattern</span>, the wrapper first sends the <span className="text-primary">Pre-key(s)</span>, waits ~150ms, then <span className="text-primary">always sends Enter</span>. So the Pre-key field is what to press BEFORE the automatic Enter — leave it empty to just press Enter.</p><p className="mt-1 text-xs text-muted">The Pre-key field accepts multiple tmux key names separated by <span className="text-primary">spaces</span>; each is sent as a separate keypress in order, before Enter. Example: to move the selection down and then confirm, enter <span className="text-primary">Down</span> as the pre-key (Enter is sent automatically). For two steps: <span className="text-primary">Down Down</span>. Other tmux keys work too, e.g. <span className="text-primary">Tab</span>, <span className="text-primary">Up</span>, <span className="text-primary">Enter</span>, <span className="text-primary">Space</span>.</p><div className="mt-2 grid gap-2 sm:grid-cols-[1fr_1fr_auto]"><Input data-debug-id="providers-editor-startup-auto-enter-patterns-chip-input" value={pattern} onChange={setPattern} placeholder="Yes, I trust this folder" width="full" className="min-h-[44px] min-w-0" /><Input data-debug-id="providers-editor-startup-auto-enter-pre-keys-chip-input" value={preKey} onChange={setPreKey} placeholder="Enter" width="full" className="min-h-[44px] min-w-0" /><Button variant="secondary" data-debug-id="providers-editor-startup-auto-enter-patterns-chip-add-btn" onClick={add} className="min-h-[44px]">Add</Button></div><div className="mt-2 space-y-2">{pairs.map((pair, index) => <div key={index} data-debug-id={`providers-editor-startup-auto-enter-patterns-chip-${index}`} className="flex items-center justify-between gap-2 rounded-xl bg-neutral-soft px-3 py-2 text-xs text-primary"><span className="min-w-0 break-all">{pair.pattern || '—'} → {pair.preKey || '—'}</span><button data-debug-id={`providers-editor-startup-auto-enter-patterns-chip-remove-btn-${index}`} type="button" onClick={() => onChange(pairs.filter((_, i) => i !== index))} className="min-h-[32px] min-w-[32px] text-muted hover:text-primary">x</button></div>)}</div></div>;
}

function ReasonMappingInput({ rows, onChange }: { rows: ReasonMapping[]; onChange: (rows: ReasonMapping[]) => void }) {
  const [keyValue, setKeyValue] = useState(''); const [reason, setReason] = useState('');
  function add() { const k = keyValue.trim(); const r = reason.trim(); if (!k && !r) return; onChange([...rows, { key: k, reason: r }]); setKeyValue(''); setReason(''); }
  return <div className="rounded-xl border border-subtle bg-surface-raised/30 p-3"><div className="text-sm font-medium text-primary">Sanitized reason mapping</div><div className="mt-2 grid gap-2 sm:grid-cols-[1fr_1fr_auto]"><Input data-debug-id="providers-editor-startup-reason-mapping-chip-input" value={keyValue} onChange={setKeyValue} placeholder="permission_prompt" width="full" className="min-h-[44px] min-w-0" /><Input data-debug-id="providers-editor-startup-reason-mapping-reason-input" value={reason} onChange={setReason} placeholder="Waiting for trust confirmation" width="full" className="min-h-[44px] min-w-0" /><Button variant="secondary" data-debug-id="providers-editor-startup-reason-mapping-chip-add-btn" onClick={add} className="min-h-[44px]">Add</Button></div><div className="mt-2 space-y-2">{rows.map((row, index) => <div key={index} data-debug-id={`providers-editor-startup-reason-mapping-chip-${index}`} className="flex items-center justify-between gap-2 rounded-xl bg-neutral-soft px-3 py-2 text-xs text-primary"><span className="min-w-0 break-all">{row.key || '—'} → {row.reason || '—'}</span><button data-debug-id={`providers-editor-startup-reason-mapping-chip-remove-btn-${index}`} type="button" onClick={() => onChange(rows.filter((_, i) => i !== index))} className="min-h-[32px] min-w-[32px] text-muted hover:text-primary">x</button></div>)}</div></div>;
}

function TextInput({ id, label, value, onChange, placeholder, disabled = false, list }: { id: string; label: string; value: string; onChange: (value: string) => void; placeholder: string; disabled?: boolean; list?: string }) { return <FormField label={label}><Input data-debug-id={id} value={value} onChange={onChange} placeholder={placeholder} disabled={disabled} list={list} width="full" className="min-h-[44px]" /></FormField>; }
function NumberInput({ id, label, value, onChange, placeholder, min = 0 }: { id: string; label: string; value: string; onChange: (value: string) => void; placeholder: string; min?: number }) { return <FormField label={label}><Input data-debug-id={id} type="number" min={min} step="1" value={value} onChange={onChange} placeholder={placeholder} width="full" className="min-h-[44px]" /></FormField>; }
