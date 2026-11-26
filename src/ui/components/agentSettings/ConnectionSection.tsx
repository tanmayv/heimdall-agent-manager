/**
 * ConnectionSection — section 4 "Connection" of the Agent settings panel (see
 * DESIGN.md): PTY vs ACP for this one instance (`runtime_transport`).
 *
 * Two cards as a radiogroup. The selected card gets the overlay fill, a gold 1px
 * border and a gold check. When the DRAFT is ACP and the hub says ACP cannot run on
 * the draft bridge + provider, a warning Alert (role="alert") explains why, with the
 * hub's fix as its action; while the adapter installs, an info status row with a
 * spinner (it updates live from provider_status_changed). The copy comes from
 * `acpAvailabilityCopy` (acp_availability only).
 */
import React from 'react';
import { Alert, Button, Icon, Spinner, Text } from '@ui';
import type { AcpAvailabilityFix } from '../../api/endpoints/bridgeSupport';
import { AgentPanelSection } from './AgentSettingsPanel';
import type { AcpCopy } from './acpAvailabilityCopy';
import type { RuntimeTransport } from './agentSettingsDraft';
import { radioGroupKeyDown, radioTabStop } from './radioGroup';

export const CONNECTION_CARDS: ReadonlyArray<{ value: RuntimeTransport; name: string; kind: string; description: string }> = [
  { value: 'pty', name: 'PTY', kind: 'Terminal', description: "Runs the provider's own terminal UI. Works with every provider and bridge." },
  { value: 'acp', name: 'ACP', kind: 'Structured', description: 'Messages, tool calls and approvals as native chat. Supports Send now.' },
];

export interface ConnectionSectionProps {
  /** The draft's transport. */
  selected: RuntimeTransport;
  onSelect: (transport: RuntimeTransport) => void;
  /** The ACP verdict for the draft bridge + provider, as copy (shown only when ACP is selected). */
  acp: AcpCopy;
  onFix: (fix: AcpAvailabilityFix) => void;
  /** A fix request this client sent is in flight. */
  fixPending?: boolean;
  /** The last fix request failed: the hub's message. */
  fixError?: string;
  disabled?: boolean;
  touch?: boolean;
}

export function ConnectionSection({ selected, onSelect, acp, onFix, fixPending = false, fixError, disabled = false, touch = false }: ConnectionSectionProps) {
  const items = CONNECTION_CARDS.map((card) => ({ value: card.value, disabled }));
  const tabStop = radioTabStop(items, selected);
  const select = (value: string) => {
    if (!disabled && value !== selected) onSelect(value as RuntimeTransport);
  };
  const showAcp = selected === 'acp';

  return (
    <AgentPanelSection id="connection" label="Connection">
      <div
        role="radiogroup"
        aria-labelledby="agent-panel-connection-heading"
        onKeyDown={radioGroupKeyDown(items, selected, select)}
        className="grid grid-cols-2 gap-2"
      >
        {CONNECTION_CARDS.map((card) => {
          const checked = card.value === selected;
          const descriptionId = `agent-panel-connection-${card.value}-description`;
          return (
            <div
              key={card.value}
              role="radio"
              aria-checked={checked}
              aria-disabled={disabled || undefined}
              aria-describedby={descriptionId}
              tabIndex={card.value === tabStop ? 0 : -1}
              data-radio-value={card.value}
              data-debug-id={`agent-panel-connection-${card.value}`}
              onClick={() => select(card.value)}
              onKeyDown={(event) => {
                if (event.key === ' ' || event.key === 'Enter') {
                  event.preventDefault();
                  select(card.value);
                }
              }}
              className={[
                'flex min-w-0 flex-col gap-1.5 rounded-[var(--radius-lg)] border p-4 outline-none focus-visible:shadow-focus',
                touch ? 'min-h-11' : '',
                checked ? 'border-accent bg-surface-overlay' : 'border-subtle bg-surface-raised',
                disabled ? 'cursor-not-allowed opacity-[0.45]' : 'cursor-pointer',
              ].filter(Boolean).join(' ')}
            >
              <div className="flex items-baseline gap-2">
                <Text as="span" role="title" className="text-primary">{card.name}</Text>
                <Text as="span" role="body-sm" tone="muted" className="min-w-0 flex-1 truncate">{card.kind}</Text>
                {checked ? <Icon name="check" size="sm" className="shrink-0 self-center text-accent" /> : null}
              </div>
              <Text as="p" role="body-sm" tone="muted" id={descriptionId}>{card.description}</Text>
            </div>
          );
        })}
      </div>

      {showAcp && acp.kind === 'installing' ? (
        <Alert tone="info" icon={null} data-debug-id="agent-panel-connection-installing">
          <span className="flex items-center gap-2">
            {/* Decorative: the row's text is the announcement (the Alert is role=status). */}
            <span aria-hidden="true" className="inline-flex"><Spinner size="sm" label="" /></span>
            {acp.text}
          </span>
        </Alert>
      ) : null}
      {showAcp && acp.kind === 'problem' ? (
        <Alert tone="warning" role="alert" data-debug-id="agent-panel-connection-acp-alert">
          {/* Lead in the warning ink, the hub-mapped reason in primary ink (design PNGs). */}
          <p data-debug-id="agent-panel-connection-acp-alert-text">
            <span className="font-semibold">ACP isn&apos;t available.</span>{' '}
            <span className="text-primary">{acp.text}</span>
          </p>
          {acp.action ? (
            <Button
              variant="secondary"
              size="sm"
              className={`mt-2 ${touch ? 'min-h-11' : ''}`}
              data-debug-id={`agent-panel-connection-fix-${acp.action.fix}`}
              loading={fixPending}
              disabled={disabled}
              onClick={() => onFix(acp.action!.fix)}
            >
              {acp.action.label}
            </Button>
          ) : null}
          {fixError ? (
            <p className="mt-1 text-danger" data-debug-id="agent-panel-connection-fix-error">{fixError}</p>
          ) : null}
        </Alert>
      ) : null}
    </AgentPanelSection>
  );
}

export default ConnectionSection;
