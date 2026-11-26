import { useRef, useState } from 'react';
import { useDispatch } from 'react-redux';
import { Link, Text } from '@ui';
import { useGetHomeFleetQuery } from '../../api/endpoints/home';
import { normalizeBridgeCapabilities, useListBridgeProvidersQuery } from '../../api/endpoints/bridgeSupport';
import { useListAgentIdentitiesQuery, useListAgentInstancesQuery } from '../../api/endpoints/agents';
import {
  bridgeFleetApi, useApplyBridgeFleetMutation, useGetBridgeFleetApplicationQuery,
  useGetBridgeFleetSettingsQuery, useRetryBridgeFleetApplicationMutation,
  type FleetApplication, type FleetApplyInput,
} from '../../api/endpoints/bridgeFleet';
import { queryErrorStatus } from '../../api/cookieFetch';
import { getExpectedUserId } from '../../utils/expectedUser';
import { fleetApplyInput, fleetExcludedCounts, type FleetSettingsSnapshot } from './fleetDraft';
import { FleetBridgeEditor } from './FleetBridgeEditor';
import { type FleetBridge, type WidgetLoader, type WidgetResource } from './widgetData';
import { useWidgetData, WidgetHeading, WidgetState } from './WidgetShared';

/** `applied` is the settings snapshot the tracked application saved, so excluded counts can use that revision after settings move on. */
interface TrackedApply { input?: FleetApplyInput; applicationId?: string; applied?: FleetSettingsSnapshot }
function readTracked(key: string): TrackedApply {
  try { return key ? JSON.parse(window.sessionStorage.getItem(key) || '{}') : {}; } catch { return {}; }
}
function LiveFleetBridge({ bridge, initiallyExpanded }: { bridge: FleetBridge; initiallyExpanded: boolean }) {
  const dispatch = useDispatch<any>();
  const settings = useGetBridgeFleetSettingsQuery(bridge.id);
  const providers = useListBridgeProvidersQuery({ bridgeId: bridge.id });
  const identities = useListAgentIdentitiesQuery();
  const owner = getExpectedUserId();
  const storageKey = owner ? `heimdall:fleet:${owner}:${bridge.id}` : '';
  const [tracked, setTracked] = useState<TrackedApply>(() => readTracked(storageKey));
  const trackedRef = useRef(tracked);
  const track = (next: TrackedApply) => {
    trackedRef.current = next; setTracked(next);
    try { if (storageKey) window.sessionStorage.setItem(storageKey, JSON.stringify(next)); } catch { /* Storage may be disabled; the server still deduplicates request keys. */ }
  };
  const [apply] = useApplyBridgeFleetMutation();
  const [retry] = useRetryBridgeFleetApplicationMutation();
  const status = useGetBridgeFleetApplicationQuery({ bridgeId: bridge.id, applicationId: tracked.applicationId || '' }, { skip: !tracked.applicationId });
  const [accepted, setAccepted] = useState<FleetApplication>();
  const application = status.currentData && (!accepted || status.currentData.application_id === accepted.application_id && status.currentData.revision >= accepted.revision) ? status.currentData : accepted;
  // Optional bounded client view; failures must not hide the durable application.
  const instances = useListAgentInstancesQuery({ bridgeId: bridge.id, limit: 200 }, { skip: !application });
  if (!settings.data || !providers.data || !identities.data) {
    const failed = settings.isError || providers.isError || identities.isError;
    return <div className="home-fleet-result"><Text role="body-sm">{bridge.label}</Text><WidgetState status={failed ? 'error' : 'loading'} name={`Fleet ${bridge.label}`} message={failed ? 'Could not load settings, provider catalog or agent identities' : undefined} onRetry={() => { void settings.refetch(); void providers.refetch(); void identities.refetch(); }} /></div>;
  }
  const agents = (identities.data.agents || []).filter((a: any) => !a.archived_at && (!a.state || String(a.state).toLowerCase() === 'active')).map((a: any) => ({ agent_id: String(a.agent_id || a.id), name: String(a.name || a.display_name || a.agent_id) }));
  return <FleetBridgeEditor bridge={bridge} settings={settings.data} catalog={normalizeBridgeCapabilities(providers.data)} agents={agents} initiallyExpanded={initiallyExpanded}
    excludedCounts={application && !instances.isError && instances.currentData ? fleetExcludedCounts(instances.currentData.instances, settings.data, application, tracked.applied) : undefined}
    excludedCountsUnavailable={!!application && instances.isError}
    restoredInput={tracked.input} replay={!!tracked.input} application={application}
    applicationError={status.isError ? 'Could not refresh restart results. Last known outcomes are shown.' : undefined}
    onRefreshApplication={() => void status.refetch()}
    onRetry={async () => { const result = await retry({ bridgeId: bridge.id, applicationId: tracked.applicationId! }).unwrap(); setAccepted(result); }}
    onApply={async (draft) => {
      const input = trackedRef.current.input || fleetApplyInput(draft, crypto.randomUUID());
      track({ input });
      try {
        const result = await apply({ bridgeId: bridge.id, input }).unwrap();
        setAccepted(result); track({ applicationId: result.application_id, applied: { revision: result.settings_revision, default_runtime: input.default_runtime, overrides: input.overrides } });
        dispatch(bridgeFleetApi.util.upsertQueryData('getBridgeFleetSettings', bridge.id, { bridge_id: bridge.id, revision: result.settings_revision, default_runtime: input.default_runtime, overrides: input.overrides }));
      } catch (err) {
        const status = queryErrorStatus(err);
        if (status && status >= 400 && status < 500) track({});
        if (status === 409) void settings.refetch();
        throw err;
      }
    }} />;
}
function FixtureFleetBridge({ bridge, initiallyExpanded }: { bridge: FleetBridge; initiallyExpanded: boolean }) {
  return <FleetBridgeEditor bridge={bridge} initiallyExpanded={initiallyExpanded} settings={{ bridge_id: bridge.id, revision: 1, default_runtime: { provider: bridge.provider, provider_profile: bridge.provider_profile || bridge.provider, model: bridge.model }, overrides: bridge.overrides.map((o) => ({ agent_id: o.id, runtime: { provider: o.provider, provider_profile: o.provider_profile || o.provider, model: o.model } })) }} catalog={bridge.catalog || []} agents={bridge.availableAgents || []} />;
}
export function FleetWidget({ resource: supplied, load }: { resource?: WidgetResource<FleetBridge[]>; load?: WidgetLoader<FleetBridge[]> } = {}) {
  const fixture = Boolean(supplied || load);
  const query = useGetHomeFleetQuery(undefined, { skip: fixture });
  const endpointResource: WidgetResource<FleetBridge[]> = query.isError ? { status: 'error', message: 'Unable to load fleet' } : query.data ? { status: 'ready', data: query.data } : { status: 'loading' };
  const custom = useWidgetData(load || (async () => []), supplied || (load ? undefined : endpointResource));
  const { resource } = custom;
  const bridges = resource.status === 'ready' ? resource.data : [];
  return <section data-debug-id="home-widget-fleet" className="home-fleet" aria-labelledby="home-fleet-title">
    <WidgetHeading id="home-fleet-title" title="Fleet"><Text role="body-sm" tone="muted">{bridges.length} bridges</Text><Link variant="standalone" href="#/settings/bridges" data-debug-id="home-fleet-add-bridge">Add bridge</Link></WidgetHeading>
    <Text role="body-sm" tone="muted" className="home-fleet-description">Each bridge has a default provider and model. Add an override when one chain agent should use something else.</Text>
    <div className="home-card">{resource.status !== 'ready' ? <WidgetState status={resource.status} name="Fleet" message={resource.status === 'error' ? resource.message : undefined} onRetry={load ? custom.retry : () => void query.refetch()} />
      : !bridges.length ? <div className="home-widget-state"><Text role="body-sm" tone="muted">No bridges yet</Text></div>
      : bridges.map((bridge, index) => fixture ? <FixtureFleetBridge key={bridge.id} bridge={bridge} initiallyExpanded={index === 0} /> : <LiveFleetBridge key={`${getExpectedUserId()}:${bridge.id}`} bridge={bridge} initiallyExpanded={index === 0} />)}</div>
  </section>;
}
export default FleetWidget;
