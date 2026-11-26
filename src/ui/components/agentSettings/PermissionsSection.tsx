/**
 * PermissionsSection — section 5 "Permissions" of the Agent settings panel (see
 * DESIGN.md). A card with the @ui Toggle (role="switch") "Bypass permissions" for
 * this running instance only (no save-as-default), its description, and a second line
 * that follows the DRAFT (bypass on; off + ACP; off + PTY). Edits the draft only.
 */
import React from 'react';
import { Text, Toggle } from '@ui';
import { AgentPanelSection } from './AgentSettingsPanel';
import { PERMISSIONS_DESCRIPTION, permissionsDetail, type RuntimeTransport } from './agentSettingsDraft';

export interface PermissionsSectionProps {
  /** The draft's bypass. */
  bypass: boolean;
  /** The draft's transport. */
  transport: RuntimeTransport;
  /** Display name of the draft's provider ("Claude Code"). */
  providerLabel: string;
  onChange: (bypass: boolean) => void;
  disabled?: boolean;
  touch?: boolean;
}

export function PermissionsSection({ bypass, transport, providerLabel, onChange, disabled = false, touch = false }: PermissionsSectionProps) {
  return (
    <AgentPanelSection id="permissions" label="Permissions">
      <div className="flex items-start gap-4 rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-4">
        <div className="min-w-0 flex-1">
          <Text as="div" role="body" id="agent-panel-permissions-label" className="font-medium text-primary">
            Bypass permissions
          </Text>
          <Text as="p" role="body-sm" tone="muted" id="agent-panel-permissions-description" className="mt-0.5">
            {PERMISSIONS_DESCRIPTION}
          </Text>
          <Text as="p" role="body-sm" tone="muted" id="agent-panel-permissions-detail" data-debug-id="agent-panel-permissions-detail">
            {permissionsDetail({ bypass, transport }, providerLabel)}
          </Text>
        </div>
        <span className={`inline-flex shrink-0 items-center ${touch ? 'min-h-11' : ''}`}>
          <Toggle
            checked={bypass}
            onChange={onChange}
            disabled={disabled}
            size={touch ? 'lg' : 'md'}
            // Touch: the 28px track gets an 8px invisible margin, a 44px hit target.
            className={touch ? "relative after:absolute after:-inset-2 after:content-['']" : undefined}
            aria-labelledby="agent-panel-permissions-label"
            aria-describedby="agent-panel-permissions-description agent-panel-permissions-detail"
            data-debug-id="agent-panel-permissions-toggle"
          />
        </span>
      </div>
    </AgentPanelSection>
  );
}

export default PermissionsSection;
