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
  useListAllBridgeProvidersQuery,
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
  Icon,
  Input,
  Modal,
  ModalBody,
  ModalFooter,
  PageShell,
  Radio,
  ResourceContainer,
  ResourceEntryCard,
  ResourceSearchFilter,
  Select,
  StatusDot,
  StatusPill,
  Tab,
  Tabs,
  TabsList,
  Textarea,
  useViewport,
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

export interface AggregatedProviderItem {
  id: string; // `${bridgeId}:${profile.name}`
  name: string;
  bridgeId: string;
  bridgeLabel: string;
  isOnline: boolean;
  isDefault: boolean;
  bridgeDefaultTier: string;
  profile: any;
}

export function ProvidersPanel() {
  const [route, setRoute] = useState(() => getRoutePathname());
  const dispatch = useDispatch();
  const viewport = useViewport();
  const twoPane = viewport === 'desktop';

  useEffect(() => {
    const handleRouteChange = () => setRoute(getRoutePathname());
    window.addEventListener('hashchange', handleRouteChange);
    window.addEventListener('popstate', handleRouteChange);
    return () => {
      window.removeEventListener('hashchange', handleRouteChange);
      window.removeEventListener('popstate', handleRouteChange);
    };
  }, []);

  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const bridges = (bridgesQuery.data?.bridges || []).filter(
    (b: any) => String(b?.status || b?.runtime_status || '').toLowerCase() !== 'revoked' && !b?.revoked_at,
  );
  const onlineBridges = bridges.filter((b: any) => String(b?.status || '').toLowerCase() === 'online');

  const allProvidersQuery = useListAllBridgeProvidersQuery(undefined, {
    pollingInterval: 30000,
    refetchOnMountOrArgChange: true,
  });

  const [selectedId, setSelectedId] = useState<string>('');
  const [searchQuery, setSearchQuery] = useState<string>('');
  const [statusFilter, setStatusFilter] = useState<string>('');
  const [bridgeFilter, setBridgeFilter] = useState<string>('');
  const [actionError, setActionError] = useState<string>('');
  const [defaultBusy, setDefaultBusy] = useState<string>('');

  // Add Custom Provider Modal state
  const [isAddCustomOpen, setIsAddCustomOpen] = useState(false);
  const [customBridgeId, setCustomBridgeId] = useState('');
  const [customForm, setCustomForm] = useState<ProviderForm>(emptyForm);
  const [customDefaultTier, setCustomDefaultTier] = useState<string>('normal');
  const [customSaving, setCustomSaving] = useState(false);
  const [customError, setCustomError] = useState('');

  const [upsertProvider] = useUpsertBridgeProviderMutation();
  const [deleteProvider] = useDeleteBridgeProviderMutation();
  const [setDefaults] = useSetBridgeProviderDefaultsMutation();
  const [refreshCaps] = useRefreshBridgeCapabilitiesMutation();
  const [enableProviders, { isLoading: isEnabling }] = useEnableBridgeProvidersMutation();

  const allProviders: AggregatedProviderItem[] = useMemo(() => {
    const list: AggregatedProviderItem[] = [];
    const bridgeList = allProvidersQuery.data?.bridges;
    if (Array.isArray(bridgeList) && bridgeList.length > 0) {
      for (const b of bridgeList) {
        for (const profile of b.providers || []) {
          const pName = String(profile?.name || '');
          if (!pName) continue;
          list.push({
            id: `${b.bridgeId}:${pName}`,
            name: pName,
            bridgeId: b.bridgeId,
            bridgeLabel: b.bridgeLabel,
            isOnline: b.isOnline,
            isDefault: b.defaultProvider === pName,
            bridgeDefaultTier: b.defaultTier || 'normal',
            profile,
          });
        }
      }
    }
    return list;
  }, [allProvidersQuery.data]);

  const filteredProviders = useMemo(() => {
    return allProviders.filter((item) => {
      if (bridgeFilter && item.bridgeId !== bridgeFilter) {
        return false;
      }
      if (statusFilter === 'enabled' && !item.profile.enabled) {
        return false;
      }
      if (statusFilter === 'disabled' && item.profile.enabled) {
        return false;
      }
      if (searchQuery.trim()) {
        const q = searchQuery.trim().toLowerCase();
        const matchName = item.name.toLowerCase().includes(q);
        const matchBridge = item.bridgeLabel.toLowerCase().includes(q);
        const cheap = String(item.profile.models?.cheap || '').toLowerCase();
        const normal = String(item.profile.models?.normal || '').toLowerCase();
        const smart = String(item.profile.models?.smart || '').toLowerCase();
        const matchModel = cheap.includes(q) || normal.includes(q) || smart.includes(q);
        if (!matchName && !matchBridge && !matchModel) {
          return false;
        }
      }
      return true;
    });
  }, [allProviders, bridgeFilter, statusFilter, searchQuery]);

  // If in two-pane mode and no provider is selected, auto-select the first provider
  useEffect(() => {
    if (twoPane && !selectedId && filteredProviders.length > 0) {
      setSelectedId(filteredProviders[0].id);
    }
  }, [twoPane, selectedId, filteredProviders]);

  const selectedItem = useMemo(() => {
    if (!selectedId) return null;
    return allProviders.find((p) => p.id === selectedId) || null;
  }, [allProviders, selectedId]);

  // Active bridge for detected CLIs or custom provider modal
  const activeBridgeId =
    bridgeFilter ||
    selectedItem?.bridgeId ||
    (onlineBridges[0] ? bridgeId(onlineBridges[0]) : bridges[0] ? bridgeId(bridges[0]) : '');
  const activeBridge = bridges.find((b: any) => bridgeId(b) === activeBridgeId) || bridges[0];
  const activeBridgeLabel = activeBridge ? activeBridge.label || activeBridge.machine_hostname || bridgeId(activeBridge) : '';
  const activeBridgeOffline = activeBridge ? String(activeBridge.status || '').toLowerCase() !== 'online' : true;

  const detectedQuery = useGetDetectedBridgeProvidersQuery(
    { bridgeId: activeBridgeId },
    { skip: !activeBridgeId || activeBridgeOffline },
  );
  const detectedList: Array<{ name: string; detected: boolean; path: string }> =
    detectedQuery.data?.detected_providers || [];
  const detectedCLIs = detectedList.filter((item) => item.detected);

  const detectedGroups = useMemo(() => {
    const groups: Array<{
      bridgeId: string;
      bridgeLabel: string;
      isOnline: boolean;
      clis: Array<{ name: string; detected: boolean; path: string }>;
    }> = [];
    const bridgeList = allProvidersQuery.data?.bridges;
    if (Array.isArray(bridgeList)) {
      for (const b of bridgeList) {
        if (bridgeFilter && b.bridgeId !== bridgeFilter) continue;
        const clis = (b.detectedProviders || []).filter((item: any) => item.detected);
        if (clis.length > 0) {
          groups.push({
            bridgeId: b.bridgeId,
            bridgeLabel: b.bridgeLabel,
            isOnline: b.isOnline,
            clis,
          });
        }
      }
    }
    // Fallback to detectedQuery if allProvidersQuery hasn't populated detectedProviders yet
    if (groups.length === 0 && detectedCLIs.length > 0 && activeBridgeId) {
      groups.push({
        bridgeId: activeBridgeId,
        bridgeLabel: activeBridgeLabel,
        isOnline: !activeBridgeOffline,
        clis: detectedCLIs,
      });
    }
    return groups;
  }, [allProvidersQuery.data, bridgeFilter, detectedCLIs, activeBridgeId, activeBridgeLabel, activeBridgeOffline]);

  const hasUnenabledDetected = useMemo(() => {
    return detectedGroups.some((g) =>
      g.clis.some((cli) => !allProviders.some((p) => p.bridgeId === g.bridgeId && p.name === cli.name && p.profile.enabled)),
    );
  }, [detectedGroups, allProviders]);

  async function enableAllDetected() {
    setActionError('');
    try {
      await Promise.all(
        detectedGroups.map(async (g) => {
          const toEnable = g.clis
            .filter((cli) => !allProviders.some((p) => p.bridgeId === g.bridgeId && p.name === cli.name && p.profile.enabled))
            .map((cli) => cli.name);
          if (toEnable.length > 0) {
            await enableProviders({ bridgeId: g.bridgeId, providers: toEnable }).unwrap();
          }
        }),
      );
      await allProvidersQuery.refetch();
      await detectedQuery.refetch();
    } catch (err: any) {
      setActionError(String(err?.message || 'Failed to enable detected providers'));
    }
  }

  async function enableSingleDetected(targetBridgeId: string, cliName: string) {
    if (!targetBridgeId) return;
    setActionError('');
    try {
      await enableProviders({ bridgeId: targetBridgeId, providers: [cliName] }).unwrap();
      await allProvidersQuery.refetch();
      await detectedQuery.refetch();
    } catch (err: any) {
      setActionError(String(err?.message || `Failed to enable ${cliName}`));
    }
  }

  useEffect(() => {
    if (!customBridgeId && activeBridgeId) {
      setCustomBridgeId(activeBridgeId);
    }
  }, [customBridgeId, activeBridgeId]);

  async function toggleEnabled(item: AggregatedProviderItem) {
    if (!item.bridgeId || !item.isOnline) return;
    const next = { ...formFromProfile(item.profile), enabled: !item.profile.enabled };
    setActionError('');
    try {
      await upsertProvider({ bridgeId: item.bridgeId, name: next.name, profile: profileFromForm(next) }).unwrap();
      await allProvidersQuery.refetch();
    } catch (err: any) {
      setActionError(String(err?.message || 'Toggle failed'));
    }
  }

  async function saveDefaults(targetBridgeId: string, provider: string, tier: string) {
    if (!targetBridgeId || !provider || !tier || defaultBusy) return;
    setActionError('');
    setDefaultBusy(`${targetBridgeId}:${provider}:${tier}`);
    try {
      await setDefaults({ bridgeId: targetBridgeId, provider, tier }).unwrap();
      await allProvidersQuery.refetch();
      await bridgesQuery.refetch();
    } catch (err: any) {
      setActionError(String(err?.message || 'Default save failed'));
    } finally {
      setDefaultBusy('');
    }
  }

  async function removeProvider(item: AggregatedProviderItem) {
    if (!item.bridgeId || !item.isOnline || item.profile.source !== 'store') return;
    setActionError('');
    try {
      await deleteProvider({ bridgeId: item.bridgeId, name: String(item.profile.name || '') }).unwrap();
      if (selectedId === item.id) {
        setSelectedId('');
      }
      await allProvidersQuery.refetch();
    } catch (err: any) {
      setActionError(String(err?.message || 'Delete failed'));
    }
  }

  async function refreshCapabilities() {
    setActionError('');
    try {
      const targetBridges = bridgeFilter
        ? bridges.filter((b: any) => bridgeId(b) === bridgeFilter && String(b.status || '').toLowerCase() === 'online')
        : onlineBridges;
      if (targetBridges.length === 0) return;
      await Promise.all(
        targetBridges.map((b: any) => refreshCaps({ bridgeId: bridgeId(b) }).unwrap()),
      );
      await allProvidersQuery.refetch();
      await bridgesQuery.refetch();
    } catch (err: any) {
      setActionError(String(err?.message || 'Refresh failed'));
    }
  }

  async function handleSaveInline(
    targetBridgeId: string,
    updatedProfile: any,
    defaultTier?: string,
    setAsDefault?: boolean,
  ) {
    if (!targetBridgeId) return;
    setActionError('');
    await upsertProvider({ bridgeId: targetBridgeId, name: updatedProfile.name, profile: updatedProfile }).unwrap();
    if (setAsDefault && defaultTier) {
      await setDefaults({ bridgeId: targetBridgeId, provider: updatedProfile.name, tier: defaultTier }).unwrap();
    }
    await allProvidersQuery.refetch();
    await bridgesQuery.refetch();
  }

  async function saveCustomModalProvider() {
    const newName = customForm.name.trim();
    if (!customBridgeId || !newName) return;
    setCustomSaving(true);
    setCustomError('');
    try {
      const profile = profileFromForm(customForm);
      await upsertProvider({ bridgeId: customBridgeId, name: newName, profile }).unwrap();
      if (customDefaultTier) {
        await setDefaults({ bridgeId: customBridgeId, provider: newName, tier: customDefaultTier }).unwrap();
      }
      dispatch(bridgeSupportApi.util.invalidateTags([
        { type: 'BridgeProviders', id: customBridgeId },
        { type: 'BridgeProviders', id: 'LIST' },
        { type: 'Bridges', id: 'LIST' },
        { type: 'Bridges', id: customBridgeId },
      ]));
      await allProvidersQuery.refetch();
      await bridgesQuery.refetch();
      setSelectedId(`${customBridgeId}:${newName}`);
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

  const listColumn = (
    <div
      data-debug-id="providers-list-column"
      className="flex flex-col h-full min-w-0 overflow-hidden"
    >
      <ResourceSearchFilter
        searchQuery={searchQuery}
        onSearchChange={setSearchQuery}
        searchPlaceholder="Search providers or models…"
        searchDebugId="providers-search-input"
        activeTab={statusFilter}
        onTabChange={setStatusFilter}
        tabs={[
          { value: '', label: 'All', debugId: 'providers-filter-status-all' },
          { value: 'enabled', label: 'Enabled', debugId: 'providers-filter-status-enabled' },
          { value: 'disabled', label: 'Disabled', debugId: 'providers-filter-status-disabled' },
        ]}
        filters={[
          {
            value: bridgeFilter,
            onChange: setBridgeFilter,
            options: [
              { value: '', label: 'All Bridges' },
              ...bridges.map((b: any) => ({
                value: bridgeId(b),
                label: b.label || b.machine_hostname || bridgeId(b),
              })),
            ],
            ariaLabel: 'Filter by bridge',
            debugId: 'providers-bridge-select',
          },
        ]}
      />

      {actionError ? (
        <div className="p-3">
          <Alert tone="danger">{actionError}</Alert>
        </div>
      ) : null}

      {/* Ambient Detected System CLIs Banner */}
      {detectedGroups.length > 0 && (
        <div
          data-debug-id="detected-providers-bar"
          className="border-b border-subtle bg-surface-raised/40 p-3 space-y-3"
        >
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div>
              <div className="text-xs font-semibold text-primary">Detected System CLIs</div>
              <div className="text-[11px] text-muted">Found in PATH across connected bridges. Enable with one click.</div>
            </div>
            {hasUnenabledDetected ? (
              <Button
                variant="secondary"
                size="sm"
                data-debug-id="enable-all-detected-btn"
                disabled={isEnabling}
                onClick={() => void enableAllDetected()}
                className="text-[11px] h-7 px-2"
              >
                Enable all detected
              </Button>
            ) : null}
          </div>
          {detectedGroups.map((group) => (
            <div key={group.bridgeId} className="space-y-1.5">
              <div className="text-[11px] font-medium text-muted flex items-center gap-1.5">
                <StatusDot tone={group.isOnline ? 'success' : 'neutral'} label={group.isOnline ? 'Online' : 'Offline'} size="sm" />
                <span>Detected on <strong>{group.bridgeLabel}</strong>:</span>
              </div>
              <div className="flex flex-wrap gap-1.5">
                {group.clis.map((cli) => {
                  const isEnabled = allProviders.some(
                    (p) => p.bridgeId === group.bridgeId && p.name === cli.name && p.profile.enabled,
                  );
                  return (
                    <div
                      key={`${group.bridgeId}:${cli.name}`}
                      data-debug-id={`detected-provider-chip-${cli.name}`}
                      className={`inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs ${
                        isEnabled
                          ? 'border-subtle bg-surface text-muted'
                          : 'border-accent/40 bg-surface text-primary'
                      }`}
                    >
                      <span className="font-medium capitalize">{cli.name}</span>
                      {isEnabled ? (
                        <StatusPill tone="success">Enabled</StatusPill>
                      ) : (
                        <button
                          type="button"
                          data-debug-id={`enable-detected-${cli.name}-btn`}
                          disabled={!group.isOnline || isEnabling}
                          onClick={() => void enableSingleDetected(group.bridgeId, cli.name)}
                          className="cursor-pointer rounded bg-accent px-1.5 py-0.5 text-[11px] font-semibold text-accent-fg hover:bg-accent/90"
                        >
                          Enable
                        </button>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* List items */}
      <div className="flex-1 min-h-0 overflow-y-auto">
        {allProvidersQuery.isLoading && bridges.length > 0 && allProviders.length === 0 ? (
          <div className="p-8 text-center text-muted">
            <p className="text-xs">Loading providers across bridges...</p>
          </div>
        ) : bridges.length === 0 ? (
          <div className="p-8 text-center text-muted">
            <p className="text-sm font-medium text-primary">No bridges connected</p>
            <p className="text-xs text-muted mt-1">Connect a bridge to start configuring models and providers.</p>
          </div>
        ) : filteredProviders.length === 0 ? (
          <div className="p-8 text-center text-muted">
            <p className="text-sm font-medium text-primary">No providers found</p>
            <p className="text-xs text-muted mt-1">
              {searchQuery || statusFilter || bridgeFilter
                ? 'Try clearing your search filters.'
                : 'No provider profiles reported on connected bridges.'}
            </p>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => {
                setCustomForm(emptyForm);
                setCustomDefaultTier('normal');
                setCustomError('');
                if (activeBridgeId) setCustomBridgeId(activeBridgeId);
                setIsAddCustomOpen(true);
              }}
              className="mt-4"
            >
              Add Custom Provider
            </Button>
          </div>
        ) : (
          <ul className="flex flex-col">
            {filteredProviders.map((item) => {
              const name = item.name;
              const isActive = selectedId === item.id;
              const previewModel =
                item.profile.models?.normal ||
                item.profile.models?.cheap ||
                item.profile.models?.smart ||
                '';
              return (
                <ResourceEntryCard
                  key={item.id}
                  id={item.id}
                  dataDebugId={`providers-provider-row-${name}`}
                  title={
                    <div className="flex items-center gap-2">
                      <span className="font-semibold text-primary text-sm">{name}</span>
                      <Badge data-debug-id={`provider-source-badge-${name}`} tone="neutral">
                        {item.profile.source || 'config'}
                      </Badge>
                    </div>
                  }
                  active={isActive}
                  onSelect={() => setSelectedId(item.id)}
                  status={
                    <StatusPill tone={item.profile.enabled ? 'success' : 'neutral'}>
                      {item.profile.enabled ? 'Enabled' : 'Disabled'}
                    </StatusPill>
                  }
                  badges={
                    <span className="inline-flex items-center gap-1.5 rounded-md border border-subtle bg-surface px-2 py-0.5 text-[11px] text-primary">
                      <StatusDot tone={item.isOnline ? 'success' : 'neutral'} label={item.isOnline ? 'Online' : 'Offline'} size="sm" />
                      <span className="font-medium">{item.bridgeLabel}</span>
                    </span>
                  }
                  snippet={previewModel ? `Model: ${previewModel}` : 'No model configured'}
                  metadata={
                    item.isDefault ? (
                      <span className="text-[10px] text-muted font-medium">Default provider ({item.bridgeDefaultTier || 'normal'})</span>
                    ) : null
                  }
                />
              );
            })}
          </ul>
        )}
      </div>

      {/* Footer count */}
      <div className="p-2 border-t border-subtle text-[11px] text-muted text-right px-3 shrink-0">
        {filteredProviders.length} {filteredProviders.length === 1 ? 'provider' : 'providers'}
      </div>
    </div>
  );

  return (
    <>
      <ResourceContainer
        title="Models & Providers"
        description="Configure provider profiles across connected bridges. Providers run in your machine's shell environment; Heimdall never stores credentials."
        actions={
          <div className="flex items-center gap-2">
            <Button
              variant="secondary"
              data-debug-id="providers-refresh-caps-btn"
              onClick={() => void refreshCapabilities()}
              disabled={onlineBridges.length === 0}
              className="min-h-[36px] text-xs"
            >
              Refresh capabilities
            </Button>
            <Button
              variant="primary"
              data-debug-id="providers-add-custom-btn"
              onClick={() => {
                setCustomForm(emptyForm);
                setCustomDefaultTier('normal');
                setCustomError('');
                if (activeBridgeId) setCustomBridgeId(activeBridgeId);
                else if (bridges.length > 0) setCustomBridgeId(bridgeId(bridges[0]));
                setIsAddCustomOpen(true);
              }}
              className="min-h-[36px] text-xs"
            >
              Add Custom Provider
            </Button>
            <a
              data-debug-id="providers-add-btn"
              href={shellHash(`/settings/providers/new${activeBridgeId ? `?bridge=${encodeURIComponent(activeBridgeId)}` : ''}`)}
              className="sr-only"
              aria-hidden="true"
            >
              Add provider
            </a>
          </div>
        }
        selectedId={selectedId}
        detailTitle={selectedItem ? selectedItem.name : 'Provider Details'}
        listDebugId="providers-list-column"
        detailDebugId="providers-detail-pane"
        emptyDetailText="Select a provider to view its models and configuration."
        list={listColumn}
        detail={
          selectedItem ? (
            <div data-debug-id="providers-detail-pane" className="h-full overflow-y-auto p-4 sm:p-6">
              <ProviderDetailView
                item={selectedItem}
                onBack={() => setSelectedId('')}
                onToggleEnabled={toggleEnabled}
                onRemoveProvider={removeProvider}
                onSaveInline={handleSaveInline}
                onSaveDefaults={saveDefaults}
                defaultBusy={defaultBusy}
              />
            </div>
          ) : null
        }
      />

      {/* Modal for Add Custom Provider */}
      <Modal open={isAddCustomOpen} onOpenChange={setIsAddCustomOpen} title="Add Custom Provider" size="lg">
        <ModalBody className="space-y-4">
          {customError ? <Alert tone="danger">{customError}</Alert> : null}
          <FormField label="Target Bridge" required>
            <Select
              value={customBridgeId}
              onChange={setCustomBridgeId}
              width="full"
              className="min-h-[40px]"
            >
              {bridges.map((b: any) => {
                const bId = bridgeId(b);
                const isOnline = String(b.status || '').toLowerCase() === 'online';
                return (
                  <option key={bId} value={bId}>
                    {b.label || b.machine_hostname || bId} ({isOnline ? 'online' : 'offline'})
                  </option>
                );
              })}
            </Select>
          </FormField>
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField label="Provider Name" required>
              <Input
                data-debug-id="custom-modal-name-input"
                value={customForm.name}
                onChange={(name) => setCustomForm({ ...customForm, name })}
                placeholder="my-provider"
                width="full"
                className="min-h-[44px]"
              />
            </FormField>
            <label className="flex items-center gap-2 pt-6 text-sm text-muted cursor-pointer">
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
            disabled={customSaving || !customForm.name.trim() || !customBridgeId}
          >
            {customSaving ? 'Adding…' : 'Add Provider'}
          </Button>
        </ModalFooter>
      </Modal>
    </>
  );
}

function ProviderDetailView({
  item,
  onBack,
  onToggleEnabled,
  onRemoveProvider,
  onSaveInline,
  onSaveDefaults,
  defaultBusy,
}: {
  item: AggregatedProviderItem;
  onBack: () => void;
  onToggleEnabled: (item: AggregatedProviderItem) => Promise<void>;
  onRemoveProvider: (item: AggregatedProviderItem) => Promise<void>;
  onSaveInline: (targetBridgeId: string, updatedProfile: any, defaultTier?: string, setAsDefault?: boolean) => Promise<void>;
  onSaveDefaults: (targetBridgeId: string, provider: string, tier: string) => Promise<void>;
  defaultBusy: string;
}) {
  const profile = item.profile;
  const name = String(profile.name || '');
  const selectedId = item.bridgeId;
  const tiers = configuredTiers(profile);
  const matchedPreset = useMemo(
    () => getProviderPreset((profile.command && profile.command[0]) || name),
    [profile.command, name],
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
    if (item.isDefault && item.bridgeDefaultTier) return item.bridgeDefaultTier;
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
    if (item.isDefault && item.bridgeDefaultTier) {
      setCardDefaultTier(item.bridgeDefaultTier);
    }
  }, [item.isDefault, item.bridgeDefaultTier]);

  const isDefault = item.isDefault;

  async function handleInlineSave() {
    if (!selectedId || !item.isOnline) return;
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
      await onSaveInline(item.bridgeId, updatedProfile, cardDefaultTier, isDefault);
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
    <div className="space-y-6">
      {/* Mobile back button */}
      <div className="sm:hidden">
        <Button
          variant="ghost"
          size="sm"
          onClick={onBack}
          leading={<Icon name="arrow-left" size="sm" />}
          className="text-xs -ml-2 mb-2"
        >
          Back to all providers
        </Button>
      </div>

      {/* Header: Name, badges, bridge chip, and action buttons */}
      <div className="flex flex-wrap items-start justify-between gap-4 pb-4 border-b border-subtle">
        <div className="space-y-2">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="text-xl font-bold text-primary">{name}</h2>
            <Badge data-debug-id={`provider-source-badge-${name}`} tone="neutral">
              {profile.source || 'config'}
            </Badge>
            <StatusPill tone={profile.enabled ? 'success' : 'neutral'}>
              {profile.enabled ? 'Enabled' : 'Disabled'}
            </StatusPill>
          </div>
          <div className="flex items-center gap-2 text-xs">
            <span className="inline-flex items-center gap-1.5 rounded-md border border-subtle bg-surface-raised px-2.5 py-1 text-primary">
              <StatusDot tone={item.isOnline ? 'success' : 'neutral'} label={item.isOnline ? 'Online' : 'Offline'} size="sm" />
              <span>Active on <strong>{item.bridgeLabel}</strong> ({item.isOnline ? 'online' : 'offline'})</span>
            </span>
            {isDefault ? (
              <span className="rounded-md bg-accent/15 text-accent border border-accent/30 px-2 py-0.5 text-[11px] font-medium">
                Default provider
              </span>
            ) : null}
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <Button
            variant="secondary"
            data-debug-id={`providers-enabled-toggle-${name}`}
            onClick={() => void onToggleEnabled(item)}
            disabled={!item.isOnline}
            className="min-h-[36px] text-xs"
          >
            {profile.enabled ? 'Disable' : 'Enable'}
          </Button>
          <a
            data-debug-id={`providers-edit-btn-${name}`}
            href={shellHash(`/settings/providers/${encodeURIComponent(name)}/edit?bridge=${encodeURIComponent(selectedId)}`)}
            aria-disabled={!item.isOnline}
            className={`inline-flex min-h-[36px] items-center justify-center rounded-lg border border-subtle px-3 py-1.5 text-xs text-muted hover:bg-neutral-soft ${
              !item.isOnline ? 'pointer-events-none opacity-50' : ''
            }`}
          >
            Edit
          </a>
          <a
            data-debug-id={`providers-duplicate-btn-${name}`}
            href={shellHash(`/settings/providers/new?bridge=${encodeURIComponent(selectedId)}&duplicateFrom=${encodeURIComponent(name)}`)}
            aria-disabled={!item.isOnline}
            className={`inline-flex min-h-[36px] items-center justify-center rounded-lg border border-subtle px-3 py-1.5 text-xs text-muted hover:bg-neutral-soft ${
              !item.isOnline ? 'pointer-events-none opacity-50' : ''
            }`}
          >
            Duplicate
          </a>
          <Button
            variant="danger"
            data-debug-id={`providers-delete-btn-${name}`}
            onClick={() => void onRemoveProvider(item)}
            disabled={!item.isOnline || profile.source !== 'store'}
            className="min-h-[36px] text-xs"
          >
            Delete
          </Button>
        </div>
      </div>

      {/* Model Tier Inputs */}
      <div className="rounded-2xl border border-subtle bg-surface-raised/40 p-4 space-y-4">
        <div>
          <div className="text-xs font-semibold uppercase tracking-wider text-muted mb-2">Model Tiers</div>
          <div className="grid gap-3 sm:grid-cols-3">
            <FormField label="Cheap / Fast model">
              <Input
                id="providers-editor-models-cheap-input"
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
                id="providers-editor-models-normal-input"
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
                id="providers-editor-models-smart-input"
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
                name={`bridge-default-provider-${item.bridgeId}`}
                checked={isDefault}
                disabled={Boolean(defaultBusy) || !item.isOnline}
                onChange={() => void onSaveDefaults(item.bridgeId, name, cardDefaultTier)}
              />
              Default provider
            </label>
            <div data-debug-id="providers-editor-default-tier-selector" className="flex items-center gap-3">
              <span className="text-muted">Default tier:</span>
              {(['cheap', 'normal', 'smart'] as const).map((tier) => (
                <label key={tier} className="flex items-center gap-1.5 cursor-pointer capitalize text-primary">
                  <Radio
                    name={`card-default-tier-${name}`}
                    value={tier}
                    checked={cardDefaultTier === tier}
                    disabled={!item.isOnline}
                    onChange={() => {
                      setCardDefaultTier(tier);
                      if (isDefault) void onSaveDefaults(item.bridgeId, name, tier);
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
              disabled={!item.isOnline || isSaving}
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
