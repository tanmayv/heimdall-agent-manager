import { useRef, useState } from 'react';
import { Button, Icon, IconButton, Link, Select, StatusPill, Text } from '@ui';
import { loadMockFleet, MOCK_AGENTS, MOCK_PROVIDERS, type FleetBridge, type FleetOverride, type WidgetLoader, type WidgetResource } from './widgetData';
import { useWidgetData, WidgetHeading, WidgetState } from './WidgetShared';

function ProviderModel({ id, label, provider, model, onChange }: { id: string; label: string; provider: string; model: string; onChange: (provider: string, model: string) => void }) {
  const models = MOCK_PROVIDERS.find((item) => item.id === provider)?.models || [];
  return <>
    <Select size="sm" value={provider} aria-label={`${label} provider`} data-debug-id={`${id}-provider`} onChange={(next) => onChange(next, MOCK_PROVIDERS.find((item) => item.id === next)!.models[0])}>
      {MOCK_PROVIDERS.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}
    </Select>
    <Select size="sm" className="home-model-select" value={model} aria-label={`${label} model`} data-debug-id={`${id}-model`} onChange={(next) => onChange(provider, next)}>
      {models.map((item) => <option key={item} value={item}>{item}</option>)}
    </Select>
  </>;
}
function FleetBridgeRow({ initial, initiallyExpanded }: { initial: FleetBridge; initiallyExpanded: boolean }) {
  const [bridge, setBridge] = useState(initial);
  const [expanded, setExpanded] = useState(initiallyExpanded);
  const nextId = useRef(0);
  const updateOverride = (id: string, change: Partial<FleetOverride>) => setBridge((value) => ({ ...value, overrides: value.overrides.map((item) => item.id === id ? { ...item, ...change } : item) }));
  const available = MOCK_AGENTS.filter((agent) => !bridge.overrides.some((item) => item.agent === agent));
  const overridesId = `home-fleet-overrides-${bridge.id}`;
  return <div className="home-fleet-bridge">
    <div className="home-fleet-bridge-header">
      <Button variant="ghost" className="home-fleet-bridge-toggle" aria-expanded={expanded} aria-controls={overridesId} data-debug-id={`home-fleet-expand-${bridge.id}`} onClick={() => setExpanded(!expanded)}>
        <Icon name={expanded ? 'chevron-down' : 'chevron-right'} size="sm" /><span className="home-device-icon"><Icon name="device" /></span>
        <span className="home-fleet-bridge-info"><span className="home-fleet-name"><Text role="code-sm">{bridge.label}</Text><StatusPill tone={bridge.online ? 'success' : 'neutral'}>{bridge.online ? 'Online' : 'Offline'}</StatusPill></span>
          <Text as="span" role="body-sm" tone="muted">{bridge.os} · {bridge.agents} {bridge.agents === 1 ? 'agent' : 'agents'} · {bridge.overrides.length ? `${bridge.overrides.length} overrides` : 'no overrides'}</Text>
        </span>
      </Button>
      <div className="home-fleet-defaults"><Text role="caption" tone="muted">Default</Text><ProviderModel id={`home-fleet-default-${bridge.id}`} label={`${bridge.label} default`} provider={bridge.provider} model={bridge.model} onChange={(provider, model) => setBridge((value) => ({ ...value, provider, model }))} /></div>
    </div>
    {expanded && <div className="home-fleet-overrides" id={overridesId}>
      <Text role="overline" tone="muted">Agent overrides</Text>
      {!bridge.overrides.length && <Text role="body-sm" tone="muted" className="home-no-overrides">No agent overrides. All agents use the bridge default.</Text>}
      {bridge.overrides.map((item) => <div className="home-fleet-override" key={item.id}>
        <Select value={item.agent} size="sm" aria-label={`${bridge.label} override agent ${item.agent}`} data-debug-id={`home-fleet-override-${item.id}-agent`} onChange={(agent) => updateOverride(item.id, { agent })}>
          {MOCK_AGENTS.filter((agent) => agent === item.agent || available.includes(agent)).map((agent) => <option key={agent} value={agent}>{agent}</option>)}
        </Select>
        <ProviderModel id={`home-fleet-override-${item.id}`} label={`${bridge.label} ${item.agent} override`} provider={item.provider} model={item.model} onChange={(provider, model) => updateOverride(item.id, { provider, model })} />
        <IconButton icon="close" label={`Remove ${item.agent} override on ${bridge.label}`} size="sm" data-debug-id={`home-fleet-remove-${item.id}`} onClick={() => setBridge((value) => ({ ...value, overrides: value.overrides.filter((other) => other.id !== item.id) }))} />
      </div>)}
      <Button size="sm" variant="secondary" leading={<Icon name="plus" size="sm" />} disabled={!available.length} data-debug-id={`home-fleet-add-override-${bridge.id}`} onClick={() => setBridge((value) => ({ ...value, overrides: [...value.overrides, { id: `${bridge.id}-local-${++nextId.current}`, agent: available[0], provider: value.provider, model: value.model }] }))}>Add override</Button>
    </div>}
  </div>;
}
export function FleetWidget({ resource: supplied, load = loadMockFleet }: { resource?: WidgetResource<FleetBridge[]>; load?: WidgetLoader<FleetBridge[]> } = {}) {
  const { resource, retry } = useWidgetData(load, supplied);
  const bridges = resource.status === 'ready' ? resource.data : [];
  return <section data-debug-id="home-widget-fleet" className="home-fleet" aria-labelledby="home-fleet-title">
    <WidgetHeading id="home-fleet-title" title="Fleet"><Text role="body-sm" tone="muted">{bridges.length} bridges · {bridges.reduce((sum, bridge) => sum + bridge.agents, 0)} agents</Text><Link variant="standalone" href="#/settings/bridges" data-debug-id="home-fleet-add-bridge">Add bridge</Link></WidgetHeading>
    <Text role="body-sm" tone="muted" className="home-fleet-description">Each bridge has a default provider and model. Add an override when one agent should use something else.</Text>
    <div className="home-card">{resource.status !== 'ready' ? <WidgetState status={resource.status} name="Fleet" message={resource.status === 'error' ? resource.message : undefined} onRetry={retry} />
      : !bridges.length ? <div className="home-widget-state"><Text role="body-sm" tone="muted">No bridges yet</Text></div>
      : bridges.map((bridge, index) => <FleetBridgeRow key={bridge.id} initial={bridge} initiallyExpanded={index === 0} />)}</div>
  </section>;
}
export default FleetWidget;
