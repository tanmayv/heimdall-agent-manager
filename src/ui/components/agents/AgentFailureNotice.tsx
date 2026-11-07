import React from 'react';
import { Text } from '@ui';
import { agentFailureSummary } from '../../utils/agentStatus';
import {LocalLaunchSurface,pendingLaunchDraft} from './LocalLaunchApproval';

// REQ-ERR-PROTO-A: a failed instance's typed last_error, worded by its class
// ("Needs attention" / "Retrying automatically" / "Failed") with its cause.
export function AgentFailureNotice({ runtimeStatus, lastError, instanceId }: { runtimeStatus: string; lastError: unknown; instanceId?:string }) {
  const failure = runtimeStatus.toLowerCase() === 'failed' ? agentFailureSummary(lastError) : null;
  const pending = pendingLaunchDraft(lastError);
  const configurationMessage = failure?.detail.includes('directory_selection_required')
    ? 'Ask the host operator to configure one unambiguous protected workspace, then retry the launch.'
    : failure?.detail.includes('slot_selection_required')
      ? 'Ask the host operator to configure an available finite slot for this provider profile, then retry the launch.'
      : null;
  if (!failure && !instanceId) return null;
  return <>
    {failure && <Text as="div" role="caption" tone="muted" className="mt-1" data-debug-id="live-instance-last-error" title={pending ? 'Review and approve the exact launch below.' : configurationMessage ?? failure.detail}>
      {pending ? 'Launch approval required. Review the configuration below.' : configurationMessage ?? `${failure.label}: ${failure.detail}`}
    </Text>}
    {instanceId && <LocalLaunchSurface instanceId={instanceId} lastError={lastError} />}
  </>;
}
