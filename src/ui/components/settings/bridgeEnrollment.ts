// REQ-BRG-1: Bridge enrollment and readiness predicates.
// Disentangles bridge connection health from capability population
// and eliminates ghosting of consumed/revoked enrollments.

export function isPendingEnrollment(
  enrollment: any,
  enrolledBridgeIds?: Set<string> | string[]
): boolean {
  if (!enrollment) return false;

  const status = String(enrollment?.status || enrollment?.state || '').toLowerCase();

  // Terminal and consumed states take precedence: never show as pending.
  if (status === 'consumed' || status === 'revoked' || status === 'expired') {
    return false;
  }
  if (enrollment?.consumed_at || enrollment?.revoked_at) {
    return false;
  }
  if (enrollment?.consumed_by_bridge_id) {
    if (enrolledBridgeIds && (enrolledBridgeIds instanceof Set || Array.isArray(enrolledBridgeIds))) {
      const isEnrolled = enrolledBridgeIds instanceof Set
        ? enrolledBridgeIds.has(enrollment.consumed_by_bridge_id)
        : enrolledBridgeIds.includes(enrollment.consumed_by_bridge_id);
      if (isEnrolled) return false;
    }
    return false;
  }

  // Active / pending states without consumed flags are pending.
  return status === 'pending' || status === 'created' || status === 'active' || (!status && !enrollment?.consumed_at);
}

export function statusLabel(bridge: any): string {
  const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
  return status || 'offline';
}

export function bridgeReady(bridge: any): boolean {
  const status = statusLabel(bridge);
  return status === 'online' || status === 'connected';
}
