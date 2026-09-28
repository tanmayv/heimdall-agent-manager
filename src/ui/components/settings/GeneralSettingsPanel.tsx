import React, { useState } from 'react';
import {
  Badge,
  Button,
  Icon,
  Kbd,
  Select,
  type SelectOption,
  Textarea,
} from '@ui';
import {
  type BrowserJsExecutionPolicyOption,
  type GeneralSettings,
  loadSettings,
  type PermissionPresetOption,
  type PlanReviewPolicyOption,
  saveSettings,
} from '../../utils/settingsPersistence';

const PERMISSION_PRESET_OPTIONS: SelectOption[] = [
  { value: 'default', label: 'Default' },
  { value: 'permissive', label: 'Permissive' },
  { value: 'strict', label: 'Strict' },
  { value: 'custom', label: 'Custom' },
];

const PLAN_REVIEW_POLICY_OPTIONS: SelectOption[] = [
  { value: 'always_ask', label: 'Always Ask' },
  { value: 'only_for_plan', label: 'Only for Plan' },
  { value: 'never_ask', label: 'Never Ask' },
];

const BROWSER_JS_EXECUTION_POLICY_OPTIONS: SelectOption[] = [
  { value: 'request_review', label: 'Request Review' },
  { value: 'automatic', label: 'Automatic' },
  { value: 'disabled', label: 'Disabled' },
];

export interface GeneralSettingsPanelProps {
  /** Optional close handler when rendered inside a modal */
  onClose?: () => void;
  className?: string;
}

export function GeneralSettingsPanel({ onClose, className }: GeneralSettingsPanelProps) {
  const [settings, setSettings] = useState<GeneralSettings>(() => loadSettings());
  const [advancedOpen, setAdvancedOpen] = useState<boolean>(() => settings.advancedExpanded ?? true);

  function updateSetting<K extends keyof GeneralSettings>(key: K, value: GeneralSettings[K]) {
    setSettings((prev) => {
      const next = { ...prev, [key]: value };
      saveSettings(next);
      return next;
    });
  }

  function toggleAdvanced() {
    const next = !advancedOpen;
    setAdvancedOpen(next);
    updateSetting('advancedExpanded', next);
  }

  return (
    <div
      data-debug-id="general-settings-panel"
      className={`space-y-6 text-left ${className ?? ''}`}
    >
      {/* 1. Header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-xl font-semibold text-primary">General</h2>
          <p className="mt-1 text-sm text-muted">
            Configure agent execution, queued message delivery, and permissions.
          </p>
        </div>
        {onClose && (
          <button
            type="button"
            onClick={onClose}
            data-debug-id="btn-close-general-settings"
            aria-label="Close"
            className="rounded-lg p-1.5 text-muted transition-colors hover:bg-surface-raised hover:text-primary focus-visible:outline-none focus-visible:shadow-focus"
          >
            <Icon name="close" size="md" />
          </button>
        )}
      </div>

      {/* 2. Execution */}
      <div className="space-y-2">
        <h3 className="text-sm font-medium text-primary">Execution</h3>
        <div className="rounded-xl border border-subtle bg-surface p-4">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div className="min-w-0 flex-1">
              <div className="text-sm font-semibold text-primary">Queued Messages</div>
              <p className="mt-0.5 text-xs text-muted">
                Configure when follow-up messages are sent.
              </p>
              <div className="mt-1 flex items-center gap-1 text-xs text-muted">
                <span>Keyboard shortcuts</span>
                <span
                  title="Shortcuts: Shift+Enter queues a message without sending immediately"
                  className="inline-flex cursor-help items-center"
                >
                  <Icon name="info" size="sm" className="text-muted hover:text-primary" />
                </span>
              </div>
            </div>

            {/* Segmented toggle: [ Queue | Send Immediately ] */}
            <div
              role="radiogroup"
              aria-label="Queued Messages mode"
              className="inline-flex shrink-0 items-center rounded-lg border border-subtle bg-surface-raised p-0.5"
            >
              <button
                type="button"
                role="radio"
                aria-checked={settings.queuedMessages === 'queue'}
                data-debug-id="toggle-queued-messages-queue"
                onClick={() => updateSetting('queuedMessages', 'queue')}
                className={`rounded-md px-3 py-1.5 text-xs font-medium transition-colors ${
                  settings.queuedMessages === 'queue'
                    ? 'border border-subtle bg-surface text-primary shadow-sm'
                    : 'text-muted hover:text-primary'
                }`}
              >
                Queue
              </button>
              <button
                type="button"
                role="radio"
                aria-checked={settings.queuedMessages === 'send_immediately'}
                data-debug-id="toggle-queued-messages-send-immediately"
                onClick={() => updateSetting('queuedMessages', 'send_immediately')}
                className={`rounded-md px-3 py-1.5 text-xs font-medium transition-colors ${
                  settings.queuedMessages === 'send_immediately'
                    ? 'border border-subtle bg-surface text-primary shadow-sm'
                    : 'text-muted hover:text-primary'
                }`}
              >
                Send Immediately
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* 3. Global Permissions */}
      <div className="space-y-2">
        <div>
          <h3 className="text-sm font-medium text-primary">Global Permissions</h3>
          <p className="mt-0.5 text-xs text-muted">
            Configure global allowed and denied resource permissions.{' '}
            <a
              href="https://developers.google.com"
              target="_blank"
              rel="noreferrer"
              className="text-accent hover:underline"
            >
              Learn more
            </a>
            .
          </p>
        </div>

        <div className="divide-y divide-subtle rounded-xl border border-subtle bg-surface">
          {/* Row 1: Permission Preset */}
          <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="text-sm font-semibold text-primary">Permission Preset</div>
              <p className="mt-0.5 text-xs text-muted">Controls the actions the agent can take.</p>
            </div>
            <Select
              value={settings.permissionPreset}
              onChange={(val) => updateSetting('permissionPreset', val as PermissionPresetOption)}
              options={PERMISSION_PRESET_OPTIONS}
              size="sm"
              className="w-36 shrink-0"
              data-debug-id="select-permission-preset"
            />
          </div>

          {/* Row 2: Tool Permissions */}
          <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="flex items-center gap-2">
                <span className="text-sm font-semibold text-primary">Tool Permissions</span>
                <Badge tone="neutral" emphasis="soft">
                  81
                </Badge>
              </div>
              <p className="mt-0.5 text-xs text-muted">
                Modify permissions for file, terminal, and MCP tools.
              </p>
            </div>
            <Button
              variant="secondary"
              size="sm"
              className="shrink-0"
              data-debug-id="btn-open-tool-permissions"
            >
              Open
            </Button>
          </div>

          {/* Row 3: Network Access Rules */}
          <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="text-sm font-semibold text-primary">Network Access Rules</div>
              <p className="mt-0.5 text-xs text-muted">
                Configure allowed and denied URLs for reading.
              </p>
            </div>
            <Button
              variant="secondary"
              size="sm"
              className="shrink-0"
              data-debug-id="btn-open-network-access-rules"
            >
              Open
            </Button>
          </div>
        </div>
      </div>

      {/* 4. Agent Behavior */}
      <div className="space-y-2">
        <h3 className="text-sm font-medium text-primary">Agent Behavior</h3>
        <div className="space-y-3 rounded-xl border border-subtle bg-surface p-4">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="text-sm font-semibold text-primary">Plan Review Policy</div>
              <p className="mt-0.5 text-xs text-muted">
                Whether the agent asks you to review its documents.
              </p>
            </div>
            <Select
              value={settings.planReviewPolicy}
              onChange={(val) => updateSetting('planReviewPolicy', val as PlanReviewPolicyOption)}
              options={PLAN_REVIEW_POLICY_OPTIONS}
              size="sm"
              className="w-36 shrink-0"
              data-debug-id="select-plan-review-policy"
            />
          </div>

          <div className="flex items-center gap-1.5 text-xs text-muted">
            <Icon name="info" size="sm" className="shrink-0 text-muted" />
            <span>
              Type <Kbd>/</Kbd> and select <Kbd>plan</Kbd> to have the agent generate a plan.
            </span>
          </div>
        </div>
      </div>

      {/* 5. Browser */}
      <div className="space-y-2">
        <div>
          <h3 className="text-sm font-medium text-primary">Browser</h3>
          <p className="mt-0.5 text-xs text-muted">
            Configure the browser subagent. It requires{' '}
            <a
              href="https://www.google.com/chrome/"
              target="_blank"
              rel="noreferrer"
              className="text-accent hover:underline"
            >
              Google Chrome
            </a>{' '}
            to be installed. The browser subagent can be invoked by typing /browser in the
            conversation input box.
          </p>
        </div>

        <div className="divide-y divide-subtle rounded-xl border border-subtle bg-surface">
          {/* Row 1: Browser Javascript Execution Policy */}
          <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="text-sm font-semibold text-primary">
                Browser Javascript Execution Policy
              </div>
              <p className="mt-0.5 text-xs text-muted">
                Controls whether the agent can run custom JavaScript to automate complex browser
                actions.
              </p>
            </div>
            <Select
              value={settings.browserJsExecutionPolicy}
              onChange={(val) =>
                updateSetting('browserJsExecutionPolicy', val as BrowserJsExecutionPolicyOption)
              }
              options={BROWSER_JS_EXECUTION_POLICY_OPTIONS}
              size="sm"
              className="w-40 shrink-0"
              data-debug-id="select-browser-js-execution-policy"
            />
          </div>

          {/* Row 2: Browser Actuation Rules */}
          <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="text-sm font-semibold text-primary">Browser Actuation Rules</div>
              <p className="mt-0.5 text-xs text-muted">
                Configure allowed and denied URLs for browser actuation.
              </p>
            </div>
            <Button
              variant="secondary"
              size="sm"
              className="shrink-0"
              data-debug-id="btn-edit-browser-actuation-rules"
            >
              Edit
            </Button>
          </div>
        </div>
      </div>

      {/* 6. Advanced (collapsible with chevron) */}
      <div className="space-y-3">
        <button
          type="button"
          onClick={toggleAdvanced}
          data-debug-id="toggle-advanced-section"
          className="flex items-center gap-1.5 text-sm font-medium text-primary transition-colors hover:text-accent focus-visible:outline-none focus-visible:shadow-focus"
        >
          <span>Advanced</span>
          <Icon
            name={advancedOpen ? 'chevron-up' : 'chevron-down'}
            size="sm"
            className="text-muted"
          />
        </button>

        {advancedOpen && (
          <div className="space-y-3 pt-1">
            <h4 className="text-sm font-medium text-primary">Terminal</h4>
            <div className="space-y-3 rounded-xl border border-subtle bg-surface p-4">
              <div>
                <div className="text-sm font-semibold text-primary">Command Setup Script</div>
                <p className="mt-0.5 text-xs text-muted">
                  A shell setup script run before every command the agent executes.
                </p>
              </div>
              <Textarea
                value={settings.commandSetupScript}
                onChange={(val) => updateSetting('commandSetupScript', val)}
                placeholder="example:&#10;source ~/.jetski_shell_setup"
                rows={3}
                width="full"
                size="sm"
                className="font-mono text-xs text-primary bg-canvas border-subtle resize-y"
                data-debug-id="textarea-command-setup-script"
                spellCheck={false}
              />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

export default GeneralSettingsPanel;
