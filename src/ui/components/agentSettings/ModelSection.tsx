/**
 * ModelSection — section 3 "Model" of the Agent settings panel (see DESIGN.md).
 *
 * Scoped to the DRAFT bridge: a provider radiogroup (mark, name, "Installed · v<ver>"
 * or "Not installed on <bridge>", disabled), then a full-width Select "Model for
 * <Provider> on <bridge>" listing that provider's discovered models ("default" reads
 * "default (provider picks)"). The header's ghost "Refresh · checked <time>" button
 * re-runs model discovery on the draft bridge (refreshBridgeModels) and shows
 * "Checking models…" with a spinner while it runs. Edits the draft only.
 */
import React, { useId } from 'react';
import { Button, Icon, Select, Text } from '@ui';
import { AgentPanelSection } from './AgentSettingsPanel';
import { modelOptionLabel, providerStatusLine, type ProviderOption } from './agentSettingsDraft';
import { radioGroupKeyDown, radioTabStop } from './radioGroup';

export interface ModelSectionProps {
  providers: ProviderOption[];
  /** Provider status for the draft bridge has answered (or failed). */
  loaded: boolean;
  /** The draft's provider (profile id). */
  selectedProvider: string;
  selectedModel: string;
  bridgeLabel: string;
  onSelectProvider: (id: string) => void;
  onSelectModel: (model: string) => void;
  onRefresh: () => void;
  refreshing: boolean;
  /** ISO time of the last model check on this bridge. */
  checkedAt: string | null;
  /** The last refresh failed: the hub's message. */
  refreshError?: string;
  disabled?: boolean;
  touch?: boolean;
}

// Row marks for the known providers (Codex and Claude Code would both read "C");
// any other provider shows the first letter of its name.
const PROVIDER_MARKS: Record<string, string> = { claude: 'C', codex: 'X', gemini: 'G', copilot: 'P', opencode: 'O' };

export function providerMark(option: Pick<ProviderOption, 'provider' | 'label'>): string {
  return PROVIDER_MARKS[option.provider] || option.label.charAt(0).toUpperCase() || '?';
}

/** "7:30 PM" in the viewer's locale ('' for an unknown time). */
export function formatCheckedTime(iso: string | null | undefined): string {
  const ms = Date.parse(String(iso || ''));
  if (!Number.isFinite(ms)) return '';
  return new Date(ms).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

export function ModelSection(props: ModelSectionProps) {
  const { providers, selectedProvider, selectedModel, bridgeLabel, disabled = false, touch = false } = props;
  const selectId = useId();
  const items = providers.map((p) => ({ value: p.id, disabled: disabled || !p.installed }));
  const tabStop = radioTabStop(items, selectedProvider);
  const select = (id: string) => {
    const item = items.find((i) => i.value === id);
    if (item && !item.disabled && id !== selectedProvider) props.onSelectProvider(id);
  };
  const current = providers.find((p) => p.id === selectedProvider);
  const providerName = current?.label || selectedProvider || 'the provider';
  const models = current?.models || [];
  // The draft's model stays listed even when this bridge did not report it (e.g. the
  // running model before discovery), so the Select never shows a blank value.
  const modelValues = selectedModel && !models.includes(selectedModel) ? [selectedModel, ...models] : models;
  const checked = formatCheckedTime(props.checkedAt);

  const refresh = (
    <Button
      variant="ghost"
      size="sm"
      data-debug-id="agent-panel-model-refresh"
      className={touch ? 'min-h-11' : ''}
      leading={props.refreshing ? undefined : <Icon name="refresh" size="sm" />}
      loading={props.refreshing}
      disabled={disabled || !bridgeLabel}
      onClick={props.onRefresh}
    >
      {props.refreshing ? 'Checking models…' : checked ? `Refresh · checked ${checked}` : 'Refresh'}
    </Button>
  );

  return (
    <AgentPanelSection id="model" label="Model" trailing={refresh}>
      {providers.length === 0 ? (
        <Text role="body-sm" tone="muted" data-debug-id="agent-panel-model-empty" className="rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-4">
          {props.loaded ? `No providers found on ${bridgeLabel}.` : 'Checking providers…'}
        </Text>
      ) : (
        <div
          role="radiogroup"
          aria-label={`Provider on ${bridgeLabel}`}
          onKeyDown={radioGroupKeyDown(items, selectedProvider, select)}
          className="overflow-hidden rounded-[var(--radius-lg)] border border-subtle bg-surface-raised"
        >
          {providers.map((option, index) => {
            const isChecked = option.id === selectedProvider;
            const rowDisabled = disabled || !option.installed;
            return (
              <div
                key={option.id}
                role="radio"
                aria-checked={isChecked}
                aria-disabled={rowDisabled || undefined}
                tabIndex={option.id === tabStop ? 0 : -1}
                data-radio-value={option.id}
                data-debug-id={`agent-panel-model-provider-${option.id}`}
                onClick={() => select(option.id)}
                onKeyDown={(event) => {
                  if (event.key === ' ' || event.key === 'Enter') {
                    event.preventDefault();
                    select(option.id);
                  }
                }}
                className={[
                  'flex items-center gap-3 px-4 py-3 outline-none focus-visible:shadow-focus',
                  touch ? 'min-h-11' : '',
                  index > 0 ? 'border-t border-subtle' : '',
                  isChecked ? 'bg-surface-overlay' : '',
                  rowDisabled ? 'cursor-not-allowed opacity-[0.45]' : 'cursor-pointer',
                ].filter(Boolean).join(' ')}
              >
                <span
                  aria-hidden="true"
                  className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-[var(--radius-sm)] bg-neutral-soft text-[length:var(--text-body-sm-size)] font-semibold text-primary"
                >
                  {providerMark(option)}
                </span>
                <div className="min-w-0 flex-1">
                  <Text as="div" role="body" className="truncate text-primary">{option.label}</Text>
                  <Text as="div" role="body-sm" tone="muted" className="truncate">{providerStatusLine(option, bridgeLabel)}</Text>
                </div>
                {isChecked ? <Icon name="check" size="sm" className="shrink-0 text-accent" /> : null}
              </div>
            );
          })}
        </div>
      )}
      {current ? (
        <div className="mt-2 flex flex-col gap-1.5">
          <Text as="label" role="body-sm" tone="muted" id={`${selectId}-label`}>
            Model for {providerName} on <Text as="span" role="code-sm">{bridgeLabel}</Text>
          </Text>
          <Select
            aria-labelledby={`${selectId}-label`}
            data-debug-id="agent-panel-model-select"
            width="full"
            size={touch ? 'lg' : 'md'}
            mobileSheet={touch}
            className={touch ? 'font-mono [&>button]:min-h-11' : 'font-mono'}
            value={selectedModel}
            disabled={disabled || modelValues.length === 0}
            placeholder="No models discovered"
            options={modelValues.map((model) => ({ value: model, label: modelOptionLabel(model) }))}
            onChange={(model) => props.onSelectModel(model)}
          />
        </div>
      ) : null}
      {props.refreshError ? (
        <Text role="caption" className="text-danger" data-debug-id="agent-panel-model-refresh-error">{props.refreshError}</Text>
      ) : null}
    </AgentPanelSection>
  );
}

export default ModelSection;
