// R4a: per-chain authority on Hub task-chain rows. The Hub marks every chain
// registered to an owner Bridge (migrated or native) with
// `authority:{kind:"owner",bridge_id}` in /task-chains list and detail
// (src/hub/transport/http/owner_authority.odin). Such a Hub row is never the
// live chain: for a migrated chain it is the frozen copy migration left behind.

export type ChainAuthority = { kind: 'owner'; bridgeId: string };

/** The owner authority of a Hub chain row, else undefined. Unknown kinds are ignored. */
export function parseChainAuthority(raw: unknown): ChainAuthority | undefined {
  if (!raw || typeof raw !== 'object') return undefined;
  const r = raw as Record<string, unknown>;
  if (r.kind !== 'owner') return undefined;
  return { kind: 'owner', bridgeId: String(r.bridge_id ?? r.bridgeId ?? '') };
}

/** True when the Hub row is held by an owner Bridge (a frozen copy, never the live chain). */
export function isOwnerHeldChain(c: { authority?: ChainAuthority } | null | undefined): boolean {
  return c?.authority?.kind === 'owner';
}
