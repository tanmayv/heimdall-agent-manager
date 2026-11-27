/**
 * acpAvailabilityCopy — the Connection section's ACP message, mapped ONLY from the
 * hub's verdict (`providers[].acp_availability {available, reason, fix}` on GET
 * /bridges/{id}/provider-status, computed by classify_acp_availability in
 * src/hub/service/provider/runtime_transport.odin). The UI never re-derives the
 * verdict: the message comes from `reason`, the action from `fix`.
 */
import type { AcpAvailability, AcpAvailabilityFix } from '../../api/endpoints/bridgeSupport';

export type AcpCopy =
  | { kind: 'ready' }
  /** An info status row with a spinner (the adapter is being installed). */
  | { kind: 'installing'; text: string }
  /**
   * A warning alert, with the fix action when the hub names one. The alert's title is
   * ACP_PROBLEM_TITLE except for not_checked, whose text already says it (`titled`).
   */
  | { kind: 'problem'; text: string; action: { fix: AcpAvailabilityFix; label: string } | null; titled?: false };

/** The warning alert's lead (design PNGs: "ACP isn't available." then the reason). */
export const ACP_PROBLEM_TITLE = "ACP isn't available.";

export const ACP_FIX_LABELS: Record<AcpAvailabilityFix, string> = {
  update_bridge: 'Update bridge',
  install_adapter: 'Install adapter',
  check_now: 'Check now',
};

/**
 * `availability` null (provider status still loading, or an older hub without the
 * verdict) reads as "not checked": the hub would refuse ACP until it has a verdict.
 */
export function acpAvailabilityCopy(
  availability: AcpAvailability | null | undefined,
  names: { provider: string; bridge: string },
): AcpCopy {
  const verdict: AcpAvailability = availability || { available: false, reason: 'not_checked', fix: 'check_now' };
  if (verdict.available) return { kind: 'ready' };
  const action = verdict.fix ? { fix: verdict.fix, label: ACP_FIX_LABELS[verdict.fix] } : null;
  switch (verdict.reason) {
    case 'installing':
      return { kind: 'installing', text: `Installing the ACP adapter on ${names.bridge}…` };
    case 'no_recipe':
      return { kind: 'problem', text: `${names.provider} has no ACP support yet. Use PTY.`, action };
    case 'unsupported_bridge':
      return { kind: 'problem', text: `${names.bridge} runs a bridge version without ACP support. Update it to the latest release.`, action };
    case 'adapter_missing_node':
      return { kind: 'problem', text: `Node.js is missing or too old on ${names.bridge}.`, action };
    case 'adapter_missing_npm':
      return { kind: 'problem', text: `npm is missing on ${names.bridge}.`, action };
    case 'adapter_missing':
    case 'adapter_outdated':
    case 'adapter_error':
      return { kind: 'problem', text: `The ${names.provider} ACP adapter isn't installed on ${names.bridge}.`, action };
    case 'not_checked':
    default:
      return { kind: 'problem', text: `ACP hasn't been checked on ${names.bridge}.`, action, titled: false };
  }
}
