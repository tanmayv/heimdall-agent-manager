export const BRIDGE_HOME_REDIRECT_DELAY_MS = 3000;

export function nextAvailableBridgeLabel(
  hostname: string,
  bridges: Array<{ label?: string }> | null | undefined,
): string {
  const base = hostname.trim() || 'bridge';
  const existing = new Set(
    (bridges || [])
      .map((bridge) => String(bridge?.label || '').trim().toLowerCase())
      .filter(Boolean),
  );
  if (!existing.has(base.toLowerCase())) return base;

  let count = 2;
  while (existing.has(`${base}-${count}`.toLowerCase())) count += 1;
  return `${base}-${count}`;
}

/**
 * A successful approval only mints a credential. Completion means the exact
 * bridge that received that credential has authenticated and joined the Hub.
 */
export function approvedBridgeIsOnline(rows: unknown, bridgeId: string): boolean {
  if (!bridgeId || !Array.isArray(rows)) return false;

  return rows.some((row: any) => {
    const id = String(row?.bridge_id || row?.bridgeId || row?.id || '');
    const status = String(row?.status || row?.runtime_status || '')
      .trim()
      .toLowerCase();
    return id === bridgeId && (status === 'online' || status === 'connected');
  });
}

export function navigateEnrollmentHome(): void {
  window.location.hash = '#/home';
}
