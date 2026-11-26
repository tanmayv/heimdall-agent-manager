import { useId, useLayoutEffect, useRef, useState } from 'react';
import { Button, Icon, IconButton, StatusPill, Text } from '@ui';
import { HomeSelect as Select } from './HomeSelect';
import { usePreviewBridgeFleetQuery, type FleetApplication, type FleetApplyInput, type FleetRuntime, type FleetSettings } from '../../api/endpoints/bridgeFleet';
import { apiErrorText } from '../../api/cookieFetch';
import { getRouteSearch } from '../../utils/appLocation';
import type { FleetProviderCapability } from '../tasks/fleetSelection';
import { catalogRuntime, fleetApplyInput, fleetDraftKey, initialFleetDraft, validFleetDraft } from './fleetDraft';
import type { FleetBridge } from './widgetData';

function ProviderModel({ id, label, runtime, catalog, disabled, onChange }: {
  id: string; label: string; runtime: FleetRuntime; catalog: FleetProviderCapability[]; disabled: boolean; onChange: (runtime: FleetRuntime) => void;
}) {
  const profile = runtime.provider_profile || runtime.provider;
  const selected = catalog.find((c) => c.provider === runtime.provider && (c.profile_id || c.provider) === profile);
  const models = selected?.models || [];
  const options = catalog.filter((c) => c.models.length);
  const key = (c: FleetProviderCapability) => JSON.stringify([c.provider, c.profile_id || c.provider]);
  const value = JSON.stringify([runtime.provider, profile]);
  return <>
    <div className="home-provider-control"><Text role="caption" tone="muted" className="home-mobile-select-label">Provider</Text>
      <Select size="sm" value={value} disabled={disabled} aria-label={`${label} provider`} data-debug-id={`${id}-provider`} onChange={(next) => {
        const capability = options.find((c) => key(c) === next);
        if (capability) onChange(catalogRuntime(capability));
      }}>
        {!selected && <option value={value} disabled>{profile || 'Select provider'}{profile ? ' (unavailable)' : ''}</option>}
        {options.map((c) => <option key={key(c)} value={key(c)}>{c.label || c.profile_id || c.provider}</option>)}
      </Select></div>
    <div className="home-model-control"><Text role="caption" tone="muted" className="home-mobile-select-label">Model</Text>
      <Select size="sm" className="home-model-select" value={runtime.model} disabled={disabled || !selected} aria-label={`${label} model`} data-debug-id={`${id}-model`} onChange={(model) => onChange({ ...runtime, model })}>
        {!models.includes(runtime.model) && <option value={runtime.model} disabled>{runtime.model || 'Select model'}{runtime.model ? ' (unavailable)' : ''}</option>}
        {models.map((model) => <option key={model} value={model}>{model}</option>)}
      </Select></div>
  </>;
}

function PreviewApply({ bridgeId, draft, valid, busy, dirty, replay, onApply }: {
  bridgeId: string; draft: FleetSettings; valid: boolean; busy: boolean; dirty: boolean; replay: boolean; onApply: () => void;
}) {
  const { request_id: _id, ...body } = fleetApplyInput(draft, '');
  const preview = usePreviewBridgeFleetQuery({ bridgeId, draft: body }, { skip: !valid || replay });
  // currentData belongs to THIS complete draft; data may be a previous response.
  const count = preview.currentData?.affected_instances;
  return <div className="home-fleet-apply">
    <Text role="caption" tone="muted" data-debug-id={`home-fleet-scope-${bridgeId}`} aria-live="polite">
      Saves this bridge’s default and overrides for coordinators, workers and reviewers across all chains.
      {' '}{replay ? 'Previous Apply result is unknown. Retry the same request to recover it.'
        : !valid ? 'Choose available providers and models.' : preview.isError ? 'Affected count unavailable. Your draft is kept.'
        : count === undefined || preview.isFetching ? 'Checking affected running chain agents…'
        : `${count} running chain ${count === 1 ? 'agent' : 'agents'} would restart now. Apply checks again.`}
    </Text>
    {valid && !replay && <Button size="sm" variant="ghost" disabled={busy || preview.isFetching} data-debug-id={`home-fleet-preview-retry-${bridgeId}`} onClick={() => void preview.refetch()}>{preview.isError ? 'Retry count' : 'Refresh count'}</Button>}
    <Button size="sm" variant="primary" data-debug-id={`home-fleet-apply-${bridgeId}`} disabled={busy || (!replay && (!valid || preview.isFetching || preview.isError || count === undefined || (!dirty && count === 0)))} onClick={onApply}>{busy ? 'Applying…' : replay ? 'Recover Apply result' : 'Apply'}</Button>
  </div>;
}

export function FleetBridgeEditor({ bridge, settings, catalog, agents, initiallyExpanded = false, application, applicationError, onRefreshApplication, onRetry, onApply, restoredInput, replay = false }: {
  bridge: FleetBridge; settings: FleetSettings; catalog: FleetProviderCapability[]; agents: { agent_id: string; name: string }[];
  initiallyExpanded?: boolean; application?: FleetApplication; applicationError?: string; onRefreshApplication?: () => void;
  onRetry?: () => Promise<unknown>; onApply?: (draft: FleetSettings) => Promise<unknown>; restoredInput?: FleetApplyInput; replay?: boolean;
}) {
  const focus = new URLSearchParams(getRouteSearch());
  const focused = focus.get('widget') === 'fleet' && (!focus.get('bridge') || focus.get('bridge') === bridge.id);
  const focusAgent = focus.get('agent');
  const [expanded, setExpanded] = useState(initiallyExpanded || focused);
  const [edited, setEdited] = useState<FleetSettings | null>(() => restoredInput ? { bridge_id: bridge.id, revision: restoredInput.expected_revision, default_runtime: restoredInput.default_runtime, overrides: restoredInput.overrides } : null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const lock = useRef(false);
  const root = useRef<HTMLDivElement>(null);
  const toggle = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const panelId = useId();
  const pendingRouteFocus = useRef(false);
  const draft = edited || initialFleetDraft(settings, catalog);
  const dirty = !settings.revision || fleetDraftKey(draft) !== fleetDraftKey(settings);
  const stale = draft.revision !== settings.revision;
  const running = application?.state === 'pending' || application?.state === 'restarting';
  const disabled = busy || running || replay;
  const available = agents.filter((a) => !draft.overrides.some((o) => o.agent_id === a.agent_id));
  const name = (id: string) => agents.find((a) => a.agent_id === id)?.name || id;
  const change = (next: FleetSettings) => { setEdited(next); setError(''); };
  useLayoutEffect(() => {
    if (!focused) return;
    pendingRouteFocus.current = true;
    setExpanded(true);
  }, [focused, focusAgent]);
  useLayoutEffect(() => {
    const body = panel.current;
    if (!body) return;
    if (!expanded && body.contains(document.activeElement)) toggle.current?.focus();
    // React 18 does not forward boolean inert; set the native attribute before paint.
    body.toggleAttribute('inert', !expanded);
  }, [expanded]);
  useLayoutEffect(() => {
    if (!expanded || !pendingRouteFocus.current) return;
    pendingRouteFocus.current = false;
    const target = focusAgent ? root.current?.querySelector<HTMLElement>(`[data-agent-id="${CSS.escape(focusAgent)}"] [role="combobox"]`) : null;
    (target || root.current)?.focus();
    root.current?.scrollIntoView({ block: 'nearest' });
  }, [expanded, focused, focusAgent]);
  const run = async (operation: () => Promise<unknown>, applied = false) => {
    if (lock.current) return;
    lock.current = true; setBusy(true); setError('');
    try { await operation(); if (applied) setEdited(null); }
    catch (err) { setError(apiErrorText(err, 'Could not apply Fleet settings')); }
    finally { lock.current = false; setBusy(false); }
  };
  return <div className="home-fleet-bridge" ref={root} tabIndex={-1} data-debug-id={`home-fleet-bridge-${bridge.id}`}>
    <div className="home-fleet-bridge-header">
      <Button ref={toggle} id={`${panelId}-toggle`} variant="ghost" className="home-fleet-bridge-toggle" aria-expanded={expanded} aria-controls={panelId} data-debug-id={`home-fleet-expand-${bridge.id}`} onClick={() => {
        // Override Selects use body portals. Return focus before their transient
        // popup state is cleared by the overrides key below.
        if (expanded && panel.current?.contains(document.activeElement)) toggle.current?.focus();
        setExpanded((open) => !open);
      }}>
        <Icon name={expanded ? 'chevron-down' : 'chevron-right'} size="sm" /><span className="home-device-icon"><Icon name="device" /></span>
        <span className="home-fleet-bridge-info"><span className="home-fleet-name"><Text role="code-sm">{bridge.label}</Text><StatusPill tone={bridge.online ? 'success' : 'neutral'}>{bridge.online ? 'Online' : 'Offline'}</StatusPill></span>
          <Text as="span" role="body-sm" tone="muted">{bridge.os} · {draft.overrides.length ? `${draft.overrides.length} overrides` : 'no overrides'}</Text>
        </span>
      </Button>
      <div className="home-fleet-defaults"><Text role="caption" tone="muted">Default</Text><ProviderModel key={String(expanded)} id={`home-fleet-default-${bridge.id}`} label={`${bridge.label} default`} runtime={draft.default_runtime} catalog={catalog} disabled={disabled} onChange={(default_runtime) => change({ ...draft, default_runtime })} /></div>
    </div>
    <div ref={panel} id={panelId} role="region" aria-labelledby={`${panelId}-toggle`} aria-hidden={!expanded} className="home-fleet-body" data-expanded={expanded} data-debug-id={`home-fleet-body-${bridge.id}`}>
      <div className="home-fleet-body-content">
        {/* Only transient Select popup state resets; draft and application state stay owned above. */}
        <div className="home-fleet-overrides" key={String(expanded)}>
          <Text role="overline" tone="muted">Agent overrides</Text>
          {!draft.overrides.length && <Text role="body-sm" tone="muted" className="home-no-overrides">No overrides. Every chain agent on this bridge inherits the default.</Text>}
          {draft.overrides.map((o) => <div className="home-fleet-override" key={o.agent_id} data-agent-id={o.agent_id}>
            <Select value={o.agent_id} size="sm" disabled={disabled} aria-label={`${bridge.label} override agent ${name(o.agent_id)}`} data-debug-id={`home-fleet-override-${bridge.id}-${o.agent_id}-agent`} onChange={(agent_id) => change({ ...draft, overrides: draft.overrides.map((other) => other === o ? { ...o, agent_id } : other) })}>
              {!agents.some((a) => a.agent_id === o.agent_id) && <option value={o.agent_id} disabled>{name(o.agent_id)} (unavailable)</option>}
              {agents.filter((a) => a.agent_id === o.agent_id || available.includes(a)).map((a) => <option key={a.agent_id} value={a.agent_id}>{a.name}</option>)}
            </Select>
            <ProviderModel id={`home-fleet-override-${bridge.id}-${o.agent_id}`} label={`${bridge.label} ${name(o.agent_id)} override`} runtime={o.runtime} catalog={catalog} disabled={disabled} onChange={(runtime) => change({ ...draft, overrides: draft.overrides.map((other) => other === o ? { ...o, runtime } : other) })} />
            <IconButton icon="close" label={`Remove ${name(o.agent_id)} override on ${bridge.label}`} size="sm" disabled={disabled} data-debug-id={`home-fleet-remove-${bridge.id}-${o.agent_id}`} onClick={() => change({ ...draft, overrides: draft.overrides.filter((other) => other !== o) })} />
          </div>)}
          <Button size="sm" variant="secondary" leading={<Icon name="plus" size="sm" />} disabled={disabled || !available.length} data-debug-id={`home-fleet-add-override-${bridge.id}`} onClick={() => change({ ...draft, overrides: [...draft.overrides, { agent_id: available[0].agent_id, runtime: { ...draft.default_runtime } }] })}>Add override</Button>
        </div>
        {onApply && <div className="home-fleet-footer">
          {!settings.revision && <Text role="caption" tone="muted">Not configured yet. Existing chain settings stay in use until the first Apply.</Text>}
          {stale && <Text role="caption" tone="warning" data-debug-id={`home-fleet-conflict-${bridge.id}`}>Settings changed elsewhere. Your draft is kept. Reset to load the latest saved settings.</Text>}
          <PreviewApply bridgeId={bridge.id} draft={draft} dirty={dirty} valid={!stale && validFleetDraft(draft, catalog) && draft.overrides.every((o) => agents.some((a) => a.agent_id === o.agent_id))} busy={busy || !!running} replay={replay} onApply={() => void run(() => onApply(draft), true)} />
          <Button size="sm" variant="ghost" data-debug-id={`home-fleet-reset-${bridge.id}`} disabled={disabled || (!edited && !dirty)} onClick={() => { setEdited(null); setError(''); }}>Reset</Button>
        </div>}
        {(error || applicationError) && <div className="home-fleet-result" role="alert" data-debug-id={`home-fleet-error-${bridge.id}`}>{error || applicationError}
          {applicationError && <Button size="sm" variant="ghost" data-debug-id={`home-fleet-status-refresh-${bridge.id}`} onClick={onRefreshApplication}>Refresh result</Button>}
        </div>}
        {application && <div className="home-fleet-result" aria-live="polite" data-debug-id={`home-fleet-result-${bridge.id}`}>
          <Text role="body-sm">{application.settings_saved ? 'Settings saved.' : 'Settings not saved.'} {application.cancelled ? 'Application cancelled.' : application.state === 'ready' ? 'All affected agents ready.' : application.state === 'partial_failure' ? 'Some agents could not restart.' : 'Waiting for agents to become ready…'}</Text>
          <Text role="caption" tone="muted">Saved revision {application.settings_revision} · {application.targets.filter((t) => t.state === 'ready').length} ready · {application.targets.filter((t) => t.state === 'pending' || t.state === 'restarting').length} pending · {application.targets.filter((t) => t.state === 'failed').length} failed</Text>
          {application.targets.map((t) => <div key={t.agent_instance_id} data-debug-id={`home-fleet-target-${t.agent_instance_id}`}><Text role="caption">{name(t.agent_id)} · {t.agent_instance_id} · {t.state}{t.error_message ? ` — ${t.error_message}` : ''}</Text></div>)}
          {onRetry && !application.cancelled && application.targets.some((t) => t.state === 'failed' && t.retryable) && <Button size="sm" variant="secondary" disabled={busy || !!running} data-debug-id={`home-fleet-retry-${bridge.id}`} onClick={() => void run(onRetry)}>Retry failed restarts</Button>}
        </div>}
      </div>
    </div>
  </div>;
}
