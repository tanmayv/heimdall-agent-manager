// Pure helpers for deriving the launch option lists (bridge -> provider -> tier)
// from a bridge's normalized capabilities. Extracted from AgentDetailPanel so the
// same logic backs both the agent-detail launch UI and the "Add agent to chain"
// popup, and so it can be unit-tested without React (see
// tests/ui_bridge_launch_options_test.ts).
//
// These functions are intentionally free of any RTK/query/DOM dependency: feed
// them plain bridge objects (as returned by useListBridgesQuery) and they return
// the option arrays the selects render.

import { normalizeBridgeCapabilities, type BridgeCapability } from '../api/endpoints/bridgeSupport';

// Canonical tier ordering surfaced first in every tier dropdown.
export const TIER_ORDER = ['cheap', 'normal', 'smart'];

export type LaunchBridgeRow = { bridgeId: string; bridge: any };

export function bridgeIdOf(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}

export function bridgeIsOnline(bridge: any): boolean {
  return String(bridge?.status || '').toLowerCase() === 'online';
}

export function bridgeLabel(bridge: any): string {
  return String(bridge?.label || bridge?.machine_hostname || bridgeIdOf(bridge) || '');
}

export function defaultCapability(bridge: any, provider?: string): BridgeCapability | undefined {
  const caps = normalizeBridgeCapabilities(bridge);
  if (provider) return caps.find((cap) => cap.provider === provider);
  return caps.find((cap) => cap.defaultTier) || caps[0];
}

export function capSupports(bridge: any, provider: string, tier: string): boolean {
  if (!provider || !tier) return false;
  const cap = defaultCapability(bridge, provider);
  if (!cap) return false;
  const tiers = cap.tiers?.length ? cap.tiers : (cap.defaultTier ? [cap.defaultTier] : []);
  return tiers.includes(tier);
}

// Providers a bridge advertises (sorted, de-duped).
export function launchProvidersFor(bridge: any): string[] {
  return normalizeBridgeCapabilities(bridge)
    .map((cap) => cap.provider)
    .filter(Boolean)
    .sort();
}

// Tiers valid for the given bridge + (optional) requested provider. Falls back to
// the agent/bridge default provider when none is requested. Canonical tiers first,
// then any extra advertised tiers, filtered to those the bridge actually supports.
export function launchTiersFor(bridge: any, requestedProvider: string, agent?: any): string[] {
  const provider = requestedProvider
    || String(agent?.default_provider || agent?.defaultProvider || '')
    || defaultCapability(bridge)?.provider
    || '';
  const cap = defaultCapability(bridge, provider);
  const tiers = [...(cap?.tiers || [])];
  if (cap?.defaultTier) tiers.push(cap.defaultTier);
  return TIER_ORDER.concat(tiers.filter((tier) => !TIER_ORDER.includes(tier)).sort())
    .filter((tier, index, all) => all.indexOf(tier) === index && capSupports(bridge, provider, tier));
}

// Online bridges that advertise at least one provider — the only bridges a launch
// can target. Returns { bridgeId, bridge } rows for the select.
export function launchableBridgeRows(bridges: any[]): LaunchBridgeRow[] {
  return (bridges || [])
    .filter((bridge) => bridgeIsOnline(bridge) && launchProvidersFor(bridge).length > 0)
    .map((bridge) => ({ bridgeId: bridgeIdOf(bridge), bridge }));
}
