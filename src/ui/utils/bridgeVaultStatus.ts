/**
 * REQ-BVS-3: per-bridge vault status derivation.
 *
 * The vault badge in bridge settings used to be derived from the UI client's OWN
 * vault state (`selectIsVaultUnlocked`), which made it one global value rendered
 * identically next to every bridge — it reported nothing about any bridge at all.
 * T1 added `bridges.vault_status` so each bridge reports its own state; this module
 * turns that report plus hub liveness into the five states the UI renders.
 *
 * Two rules are load-bearing and are what the truth-table test pins down:
 *
 *  1. HUB LIVENESS WINS. `vault_status` is the LAST value a bridge reported, and it
 *     is not cleared when the bridge goes away. An offline bridge whose last report
 *     said "unlocked" is NOT unlocked — nothing is holding that key any more — so an
 *     offline bridge always renders "Not running" regardless of the cached value.
 *
 *  2. UNREPORTED IS NOT UNLOCKED. Bridges on older builds emit `vault_status: ""`
 *     (the hub serializes the empty string verbatim rather than guessing). That is
 *     "Unknown" and renders NEUTRAL. Collapsing it into Unlocked would tell the user
 *     their data is protected by a bridge that never said so.
 *
 * This module is intentionally pure and free of React/Redux imports: it is the
 * single place the state table lives, and `node --test` can import it directly
 * (a `.tsx` component can only be asserted against as source text).
 */

import type { Tone } from '../components/ui/types';

/** The five states a bridge's vault can present in the UI. */
export type BridgeVaultStatus =
  | 'NotRunning'
  | 'NotConfigured'
  | 'Locked'
  | 'Unlocked'
  | 'Unknown';

/** The values `bridges.vault_status` is documented to carry (plus "" for unreported). */
export type ReportedVaultStatus = 'disabled' | 'locked' | 'unlocked' | '' | string;

export interface BridgeVaultStatusInput {
  /** `bridge.status` / `bridge.runtime_status` as reported by the hub. */
  bridgeStatus?: string | null;
  /** `bridge.vault_status` as reported by the bridge via the hub. */
  vaultStatus?: ReportedVaultStatus | null;
}

/**
 * Derives the badge state for ONE bridge. See the two rules in the module header.
 */
export function resolveBridgeVaultStatus(input: BridgeVaultStatusInput): BridgeVaultStatus {
  const online = String(input.bridgeStatus ?? '').trim().toLowerCase() === 'online';
  // Rule 1: liveness precedes any cached vault value.
  if (!online) return 'NotRunning';

  switch (String(input.vaultStatus ?? '').trim().toLowerCase()) {
    case 'disabled':
      return 'NotConfigured';
    case 'locked':
      return 'Locked';
    case 'unlocked':
      return 'Unlocked';
    default:
      // Rule 2: "" and anything unrecognised degrade to Unknown, never to Unlocked.
      return 'Unknown';
  }
}

/**
 * Pill tone. `Unknown` and `NotRunning` are deliberately NEUTRAL — never `success`.
 * Tone is here rather than in the component because "Unknown must not look unlocked"
 * is a correctness rule worth a test, not a styling preference. The visible STRINGS
 * live in the component that renders them (presentation stays in the view layer).
 */
export const BRIDGE_VAULT_STATUS_TONE: Record<BridgeVaultStatus, Tone> = {
  NotRunning: 'neutral',
  NotConfigured: 'neutral',
  Locked: 'warning',
  Unlocked: 'success',
  Unknown: 'neutral',
};

/** Lock is only meaningful while the bridge actually holds a key. */
export function canLockBridgeVault(status: BridgeVaultStatus): boolean {
  return status === 'Unlocked';
}

/** Unseal is only meaningful for an online bridge that is not already unsealed. */
export function canUnlockBridgeVault(status: BridgeVaultStatus): boolean {
  return status === 'Locked' || status === 'Unknown';
}

/** All five states, in the order the UI documents them. */
export const BRIDGE_VAULT_STATUSES: readonly BridgeVaultStatus[] = [
  'NotRunning',
  'NotConfigured',
  'Locked',
  'Unlocked',
  'Unknown',
] as const;
