import React, { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  Badge,
  Button,
  Icon,
  Kbd,
  Select,
  type SelectOption,
  Textarea,
} from '@ui';
import { useDialogA11y } from '../ui/composites/useDialogA11y';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { withApiBase } from '../../api/apiBase';

import AppearanceSettings from './AppearanceSettings';
import NotificationsPanel from './NotificationsPanel';
import { ProvidersPanel } from './ProvidersPanel';
import BridgesPanel from './BridgesPanel';
import ExperimentalPanel from './ExperimentalPanel';
import VaultPanel from './VaultPanel';
import LspPanel from './LspPanel';
import UserTokensPanel from './UserTokensPanel';
import TemplatesPanel from './TemplatesPanel';

export interface SettingsCategory {
  id: string;
  label: string;
  title: string;
  description: string;
}

export const SETTINGS_CATEGORIES: SettingsCategory[] = [
  {
    id: 'appearance',
    label: 'Appearance',
    title: 'Appearance',
    description: 'Select a theme to customize the dashboard color palette, syntax highlighting, and terminal colors.',
  },
  {
    id: 'notifications',
    label: 'Notifications',
    title: 'Notifications',
    description: 'Configure desktop notifications, push alerts, and sound preferences.',
  },
  {
    id: 'models',
    label: 'Models',
    title: 'Models & Providers',
    description: 'Configure AI model providers, API endpoints, tokens, and active reasoning models.',
  },
  {
    id: 'browser',
    label: 'Browser',
    title: 'Browser',
    description: 'Configure the browser automation subagent, Chrome execution policy, and actuation rules.',
  },
  {
    id: 'workspace',
    label: 'Workspace Settings',
    title: 'Workspace Settings',
    description: 'Manage host machines, connected local/remote bridges, and agent runtimes.',
  },
  {
    id: 'vault',
    label: 'User Vault',
    title: 'User Vault',
    description: 'Zero-Knowledge User Vault management, recovery words, and unlock keys.',
  },
  {
    id: 'lsp',
    label: 'Language Servers',
    title: 'Language Servers (LSP)',
    description: 'Configure Language Server Protocol servers and diagnostics.',
  },
  {
    id: 'user-tokens',
    label: 'User Tokens',
    title: 'User Tokens',
    description: 'Manage user access tokens for Heimdall CLI and external integrations.',
  },
  {
    id: 'templates',
    label: 'Templates',
    title: 'Templates',
    description: 'Manage agent templates and reusable personas.',
  },
  {
    id: 'experimental',
    label: 'Experimental',
    title: 'Experimental Flags',
    description: 'Preview and enable experimental capabilities, developer tools, and cutting-edge workflows.',
  },
];

export function getVisibleSettingsCategories(lspEnabled: boolean): SettingsCategory[] {
  return SETTINGS_CATEGORIES.filter((category) => category.id !== 'lsp' || lspEnabled);
}

export const EXTRA_SECTIONS: Record<string, { title: string; description: string }> = {
  shortcuts: {
    title: 'Shortcuts',
    description: 'Keyboard shortcuts and global navigation hotkeys.',
  },
  feedback: {
    title: 'Provide Feedback',
    description: 'Send diagnostics, report bugs, or submit suggestions to the Heimdall engineering team.',
  },
};

export function normalizeSettingsTab(tab?: string): string {
  if (!tab || tab === 'general') return 'appearance';
  if (tab === 'bridges') return 'workspace';
  if (tab === 'providers') return 'models';
  if (tab === 'labs') return 'experimental';
  return tab;
}

export interface SettingsUser {
  user_id?: string;
  name?: string;
  display_name?: string;
  email?: string;
  avatar_url?: string;
}

export interface SettingsModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initialTab?: string;
  user?: SettingsUser;
  className?: string;
}

// ---------------------------------------------------------------------------
// Structured Placeholder Panels for Secondary Tabs
// ---------------------------------------------------------------------------

function BrowserSettingsPlaceholder() {
  const [headless, setHeadless] = useState(true);
  const [timeoutSec, setTimeoutSec] = useState('30');
  const [policy, setPolicy] = useState('request_review');

  const policyOptions: SelectOption[] = [
    { value: 'request_review', label: 'Request Review' },
    { value: 'automatic', label: 'Automatic' },
    { value: 'disabled', label: 'Disabled' },
  ];

  return (
    <div data-debug-id="browser-settings-panel" className="space-y-6 text-left">
      <div className="rounded-xl border border-subtle bg-surface p-4 space-y-3">
        <div className="flex items-center justify-between">
          <div className="text-sm font-semibold text-primary">Google Chrome Integration</div>
          <Badge tone="success">Ready</Badge>
        </div>
        <p className="text-xs text-muted">
          The browser subagent uses your local Chrome instance for web extraction and testing.
          Invoke anytime with <Kbd>/browser</Kbd> in chat.
        </p>
      </div>

      <div className="space-y-2">
        <h3 className="text-sm font-medium text-primary">Automation Policies</h3>
        <div className="rounded-xl border border-subtle bg-surface p-4 space-y-4">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <div className="text-sm font-medium text-primary">JavaScript Execution Policy</div>
              <div className="text-xs text-muted">Controls whether the agent can run custom JavaScript.</div>
            </div>
            <div className="w-48">
              <Select options={policyOptions} value={policy} onChange={setPolicy} />
            </div>
          </div>

          <div className="flex items-center justify-between border-t border-subtle pt-3">
            <div>
              <div className="text-sm font-medium text-primary">Headless Mode</div>
              <div className="text-xs text-muted">Run browser sessions in background without opening window.</div>
            </div>
            <button
              type="button"
              onClick={() => setHeadless(!headless)}
              className={`relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors focus-visible:outline-none ${
                headless ? 'bg-accent' : 'bg-surface-raised'
              }`}
            >
              <span
                className={`pointer-events-none inline-block h-5 w-5 transform rounded-full bg-primary shadow ring-0 transition duration-200 ease-in-out ${
                  headless ? 'translate-x-5' : 'translate-x-0'
                }`}
              />
            </button>
          </div>

          <div className="flex items-center justify-between border-t border-subtle pt-3">
            <div>
              <div className="text-sm font-medium text-primary">Page Load Timeout (seconds)</div>
              <div className="text-xs text-muted">Maximum time allowed before aborting navigation.</div>
            </div>
            <input
              type="number"
              min="5"
              max="120"
              value={timeoutSec}
              onChange={(e) => setTimeoutSec(e.target.value)}
              className="w-20 rounded-lg border border-subtle bg-surface-raised px-2.5 py-1 text-sm text-primary text-right focus:outline-none focus:border-accent"
            />
          </div>
        </div>
      </div>
    </div>
  );
}


function ShortcutsSettingsPlaceholder() {
  const shortcuts = [
    { key: 'Cmd/Ctrl + K', action: 'Open Command Palette' },
    { key: 'Cmd/Ctrl + ,', action: 'Open Settings Modal' },
    { key: 'Esc', action: 'Close Modal or Drawer' },
    { key: 'Cmd/Ctrl + /', action: 'Toggle Sidebar' },
    { key: 'Cmd/Ctrl + Shift + F', action: 'Global Search' },
    { key: 'Enter', action: 'Send Chat Message' },
    { key: 'Shift + Enter', action: 'Insert Newline in Chat' },
  ];

  return (
    <div data-debug-id="shortcuts-settings-panel" className="space-y-4 text-left">
      <div className="rounded-xl border border-subtle bg-surface overflow-hidden">
        <div className="divide-y divide-subtle">
          {shortcuts.map((sc) => (
            <div key={sc.key} className="flex items-center justify-between px-4 py-3">
              <span className="text-sm text-primary">{sc.action}</span>
              <Kbd>{sc.key}</Kbd>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function FeedbackSettingsPlaceholder() {
  const [feedbackText, setFeedbackText] = useState('');
  const [submitted, setSubmitted] = useState(false);

  return (
    <div data-debug-id="feedback-settings-panel" className="space-y-4 text-left">
      <div className="rounded-xl border border-subtle bg-surface p-4 space-y-4">
        {submitted ? (
          <div className="p-4 text-center space-y-2">
            <div className="text-sm font-semibold text-primary">Thank you for your feedback!</div>
            <p className="text-xs text-muted">Your report has been recorded.</p>
            <Button size="sm" variant="ghost" onClick={() => setSubmitted(false)}>
              Send another note
            </Button>
          </div>
        ) : (
          <>
            <div>
              <label className="block text-sm font-medium text-primary mb-1">
                Share your feedback or bug report
              </label>
              <Textarea
                rows={4}
                value={feedbackText}
                onChange={(val) => setFeedbackText(val)}
                placeholder="Describe your issue or suggestion..."
              />
            </div>
            <div className="flex items-center justify-between">
              <span className="text-xs text-muted">Includes anonymized diagnostic logs.</span>
              <Button
                variant="primary"
                size="sm"
                disabled={!feedbackText.trim()}
                onClick={() => setSubmitted(true)}
              >
                Submit Feedback
              </Button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main SettingsModal Component
// ---------------------------------------------------------------------------

export function SettingsModal({
  open,
  onOpenChange,
  initialTab,
  user,
  className,
}: SettingsModalProps) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const [activeTab, setActiveTab] = useState<string>(() => initialTab || 'appearance');
  const [mobileSection, setMobileSection] = useState<string | null>(() => initialTab || null);
  const [currentUser, setCurrentUser] = useState<SettingsUser | null>(() => user || null);

  const close = useCallback(() => onOpenChange(false), [onOpenChange]);
  useDialogA11y(open, close, panelRef);

  // Fetch experiments to gate LSP
  const experimentsQuery = useFetchExperimentsQuery();
  const lspEnabled = Boolean(experimentsQuery.data?.flags?.find((f) => f.key === 'lsp')?.enabled);

  const categories = useMemo(() => {
    return getVisibleSettingsCategories(lspEnabled);
  }, [lspEnabled]);

  // Sync initialTab when opening
  useEffect(() => {
    if (initialTab) {
      setActiveTab(initialTab);
      setMobileSection(initialTab);
    } else {
      setMobileSection(null);
    }
  }, [initialTab, open]);

  // Populate user data if not passed
  useEffect(() => {
    if (user) {
      setCurrentUser(user);
      return;
    }
    let cancelled = false;
    fetch(withApiBase('/api/v1/me'), { credentials: 'include' })
      .then((res) => (res.ok ? res.json() : null))
      .then((body) => {
        if (!cancelled && body?.data) {
          setCurrentUser(body.data);
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [user]);

  // User display helpers
  const userDisplayName = currentUser?.display_name || currentUser?.name || 'Tanmay Vijayvargiya';
  const userEmail = currentUser?.email || 'tanmayvijay@google.com';
  const avatarInitial = (userDisplayName || 'U')[0].toUpperCase();

  // Find info for current tab
  const currentTabInfo = useMemo(() => {
    const effectiveTab = normalizeSettingsTab(activeTab);
    const category = categories.find((c) => c.id === activeTab || c.id === effectiveTab)
      || SETTINGS_CATEGORIES.find((c) => c.id === activeTab || c.id === effectiveTab);
    if (category) return category;
    if (EXTRA_SECTIONS[activeTab] || EXTRA_SECTIONS[effectiveTab]) {
      const extra = EXTRA_SECTIONS[activeTab] || EXTRA_SECTIONS[effectiveTab];
      return {
        id: activeTab,
        label: extra.title,
        title: extra.title,
        description: extra.description,
      };
    }
    return {
      id: activeTab,
      label: activeTab,
      title: activeTab.charAt(0).toUpperCase() + activeTab.slice(1),
      description: '',
    };
  }, [activeTab, categories]);

  if (!open) return null;

  function renderTabContent(tabId: string) {
    const effectiveTab = normalizeSettingsTab(tabId);
    switch (effectiveTab) {
      case 'appearance':
        return (
          <div className="[&>div>div:first-child]:hidden">
            <AppearanceSettings />
          </div>
        );
      case 'notifications':
        return <NotificationsPanel />;
      case 'models':
      case 'providers':
        return <ProvidersPanel />;
      case 'browser':
        return <BrowserSettingsPlaceholder />;
      case 'workspace':
      case 'bridges':
        return <BridgesPanel />;
      case 'vault':
        return <VaultPanel />;
      case 'lsp':
        return lspEnabled ? (
          <LspPanel />
        ) : (
          <div className="[&>div>div:first-child]:hidden">
            <AppearanceSettings />
          </div>
        );
      case 'user-tokens':
        return <UserTokensPanel />;
      case 'templates':
        return <TemplatesPanel />;
      case 'experimental':
      case 'labs':
        return <ExperimentalPanel />;
      case 'shortcuts':
        return <ShortcutsSettingsPlaceholder />;
      case 'feedback':
        return <FeedbackSettingsPlaceholder />;
      default:
        return (
          <div className="[&>div>div:first-child]:hidden">
            <AppearanceSettings />
          </div>
        );
    }
  }

  return createPortal(
    <div
      data-debug-id="settings-modal-overlay"
      className="fixed inset-0 z-modal bg-surface-overlay/80 backdrop-blur-sm flex items-center justify-center p-0 md:p-4"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) {
          close();
        }
      }}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label="Settings"
        tabIndex={-1}
        data-debug-id="settings-modal-container"
        className={`relative flex flex-col w-full h-full md:flex-row md:rounded-2xl md:border md:border-subtle bg-surface md:shadow-overlay overflow-hidden md:max-w-5xl md:h-[calc(var(--app-viewport-height)*0.85)] md:max-h-[820px] outline-none ${
          className ?? ''
        }`}
      >
        {/* =============================================================== */}
        {/* 2. Desktop / Tablet 2-Pane Layout (md:flex)                     */}
        {/* =============================================================== */}
        <div className="hidden md:flex flex-row w-full h-full overflow-hidden">
          {/* Left Navigation Pane (w-64 border-r border-subtle bg-surface-raised/40) */}
          <aside
            data-debug-id="settings-desktop-sidebar"
            className="w-64 border-r border-subtle flex flex-col bg-surface-raised/40 shrink-0 h-full overflow-hidden"
            aria-label="Settings sidebar"
          >
            {/* Header: Settings */}
            <div className="px-5 pt-5 pb-2 shrink-0">
              <div className="text-[11px] font-semibold uppercase tracking-wider text-faint">
                Settings
              </div>
            </div>

            {/* Scrollable Categories */}
            <div className="flex-1 overflow-y-auto px-3 py-1">
              {/* Settings Categories */}
              <nav className="space-y-0.5" aria-label="Settings categories">
                {categories.map((category) => {
                  const isActive = activeTab === category.id || normalizeSettingsTab(activeTab) === category.id;
                  return (
                    <button
                      key={category.id}
                      type="button"
                      data-debug-id={`settings-nav-item-${category.id}`}
                      onClick={() => setActiveTab(category.id)}
                      className={`w-full flex items-center px-3 py-1.5 rounded-lg text-sm text-left transition-colors ${
                        isActive
                          ? 'bg-surface-raised text-primary font-medium shadow-sm'
                          : 'text-muted hover:text-primary hover:bg-surface-raised/60'
                      }`}
                    >
                      <span className="truncate">{category.label}</span>
                    </button>
                  );
                })}
              </nav>
            </div>

            {/* Footer: Shortcuts, Provide Feedback, User Profile Card */}
            <div className="shrink-0 border-t border-subtle p-3 space-y-1 bg-surface-raised/30">
              <button
                type="button"
                data-debug-id="settings-nav-item-shortcuts"
                onClick={() => setActiveTab('shortcuts')}
                className={`w-full flex items-center px-3 py-1.5 rounded-lg text-sm text-left transition-colors ${
                  activeTab === 'shortcuts'
                    ? 'bg-surface-raised text-primary font-medium'
                    : 'text-muted hover:text-primary hover:bg-surface-raised/60'
                }`}
              >
                <span className="truncate">Shortcuts</span>
              </button>
              <button
                type="button"
                data-debug-id="settings-nav-item-feedback"
                onClick={() => setActiveTab('feedback')}
                className={`w-full flex items-center px-3 py-1.5 rounded-lg text-sm text-left transition-colors ${
                  activeTab === 'feedback'
                    ? 'bg-surface-raised text-primary font-medium'
                    : 'text-muted hover:text-primary hover:bg-surface-raised/60'
                }`}
              >
                <span className="truncate">Provide Feedback</span>
              </button>

              {/* User Profile Card */}
              <div
                data-debug-id="settings-user-profile-card"
                className="flex items-center gap-2.5 rounded-xl p-2 bg-surface/60 border border-subtle/60 mt-2"
              >
                <div className="h-8 w-8 rounded-full bg-neutral-soft text-primary font-bold text-xs flex items-center justify-center shrink-0 border border-subtle">
                  {currentUser?.avatar_url ? (
                    <img
                      src={currentUser.avatar_url}
                      alt={userDisplayName}
                      className="h-full w-full rounded-full object-cover"
                    />
                  ) : (
                    avatarInitial
                  )}
                </div>
                <div className="min-w-0 flex-1">
                  <div
                    data-debug-id="settings-user-display-name"
                    className="truncate text-xs font-semibold text-primary"
                  >
                    {userDisplayName}
                  </div>
                  <div
                    data-debug-id="settings-user-email"
                    className="truncate text-[10.5px] text-muted"
                  >
                    {userEmail}
                  </div>
                </div>
              </div>
            </div>
          </aside>

          {/* Right Content Pane (flex-1 flex flex-col overflow-hidden bg-surface) */}
          <main
            data-debug-id="settings-desktop-content"
            className="flex-1 flex flex-col overflow-hidden bg-surface h-full"
          >
            {/* Header: title, description, and Close button (X) */}
            <div className="flex items-start justify-between px-8 pt-7 pb-4 shrink-0">
              <div className="min-w-0 flex-1">
                <h2 className="text-xl font-semibold text-primary tracking-tight">
                  {currentTabInfo.title}
                </h2>
                {currentTabInfo.description && (
                  <p className="mt-1 text-sm text-muted">
                    {currentTabInfo.description}
                  </p>
                )}
              </div>
              <button
                type="button"
                onClick={close}
                data-debug-id="settings-modal-close-button"
                data-testid="settings-modal-close-button"
                aria-label="Close"
                className="rounded-lg p-1.5 text-muted transition-colors hover:bg-surface-raised hover:text-primary focus-visible:outline-none focus-visible:shadow-focus shrink-0 ml-4"
              >
                <Icon name="close" size="md" />
              </button>
            </div>

            {/* Body: scrollable container rendering the active tab content */}
            <div className="flex-1 overflow-y-auto px-8 pb-8 pt-2">
              {renderTabContent(activeTab)}
            </div>
          </main>
        </div>

        {/* =============================================================== */}
        {/* 3. Mobile Presentation (<768px): Full viewport Master-Detail    */}
        {/* =============================================================== */}
        <div className="flex md:hidden flex-col w-full h-full overflow-hidden">
          {mobileSection === null ? (
            /* Master View: Full-screen list of all categories and projects */
            <div
              data-debug-id="settings-mobile-master-view"
              className="flex flex-col h-full w-full bg-surface overflow-hidden"
            >
              {/* Sticky top header with Settings title and close X button */}
              <div className="sticky top-0 z-10 flex h-14 items-center justify-between border-b border-subtle bg-surface px-4 shrink-0">
                <h1 className="text-lg font-semibold text-primary">Settings</h1>
                <button
                  type="button"
                  onClick={close}
                  data-debug-id="btn-close-mobile-settings-master"
                  aria-label="Close"
                  className="flex h-11 w-11 items-center justify-center rounded-lg text-muted hover:bg-surface-raised hover:text-primary focus-visible:outline-none focus-visible:shadow-focus"
                >
                  <Icon name="close" size="md" />
                </button>
              </div>

              {/* Scrollable list with chevron icons, touch targets >= 44px */}
              <div className="flex-1 overflow-y-auto px-4 py-3 space-y-4">
                {/* Categories */}
                <div className="space-y-1">
                  {categories.map((category) => (
                    <button
                      key={category.id}
                      type="button"
                      data-debug-id={`mobile-nav-item-${category.id}`}
                      onClick={() => {
                        setActiveTab(category.id);
                        setMobileSection(category.id);
                      }}
                      className="flex min-h-[44px] w-full items-center justify-between rounded-xl px-3 py-2.5 text-left text-sm font-medium text-primary hover:bg-surface-raised active:bg-surface-raised transition-colors"
                    >
                      <span>{category.label}</span>
                      <Icon name="chevron-right" size="sm" className="text-muted shrink-0" />
                    </button>
                  ))}
                </div>


                {/* Footer secondary items */}
                <div className="space-y-1 pt-2 border-t border-subtle">
                  <button
                    type="button"
                    data-debug-id="mobile-nav-item-shortcuts"
                    onClick={() => {
                      setActiveTab('shortcuts');
                      setMobileSection('shortcuts');
                    }}
                    className="flex min-h-[44px] w-full items-center justify-between rounded-xl px-3 py-2.5 text-left text-sm font-medium text-primary hover:bg-surface-raised active:bg-surface-raised transition-colors"
                  >
                    <span>Shortcuts</span>
                    <Icon name="chevron-right" size="sm" className="text-muted shrink-0" />
                  </button>
                  <button
                    type="button"
                    data-debug-id="mobile-nav-item-feedback"
                    onClick={() => {
                      setActiveTab('feedback');
                      setMobileSection('feedback');
                    }}
                    className="flex min-h-[44px] w-full items-center justify-between rounded-xl px-3 py-2.5 text-left text-sm font-medium text-primary hover:bg-surface-raised active:bg-surface-raised transition-colors"
                  >
                    <span>Provide Feedback</span>
                    <Icon name="chevron-right" size="sm" className="text-muted shrink-0" />
                  </button>
                </div>

                {/* User profile card at bottom */}
                <div
                  data-debug-id="mobile-user-profile-card"
                  className="flex items-center gap-3 rounded-xl p-3 bg-surface-raised/40 border border-subtle mt-4"
                >
                  <div className="h-10 w-10 rounded-full bg-neutral-soft text-primary font-bold text-sm flex items-center justify-center shrink-0 border border-subtle">
                    {currentUser?.avatar_url ? (
                      <img
                        src={currentUser.avatar_url}
                        alt={userDisplayName}
                        className="h-full w-full rounded-full object-cover"
                      />
                    ) : (
                      avatarInitial
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-sm font-semibold text-primary">
                      {userDisplayName}
                    </div>
                    <div className="truncate text-xs text-muted">
                      {userEmail}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          ) : (
            /* Detail View: Category settings view with sticky top header (< Back, title, close X) */
            <div
              data-debug-id="settings-mobile-detail-view"
              className="flex flex-col h-full w-full bg-surface overflow-hidden"
            >
              <div className="sticky top-0 z-10 flex h-14 items-center justify-between border-b border-subtle bg-surface px-3 shrink-0">
                <button
                  type="button"
                  onClick={() => setMobileSection(null)}
                  data-debug-id="btn-back-mobile-settings"
                  className="flex min-h-[44px] items-center gap-1.5 rounded-lg px-2 text-sm font-medium text-muted hover:text-primary focus-visible:outline-none focus-visible:shadow-focus transition-colors"
                >
                  <Icon name="chevron-left" size="md" />
                  <span>Back</span>
                </button>
                <h2 className="text-base font-semibold text-primary truncate max-w-[180px] text-center">
                  {currentTabInfo.title}
                </h2>
                <button
                  type="button"
                  onClick={close}
                  data-debug-id="btn-close-mobile-settings-detail"
                  aria-label="Close"
                  className="flex h-11 w-11 items-center justify-center rounded-lg text-muted hover:bg-surface-raised hover:text-primary focus-visible:outline-none focus-visible:shadow-focus"
                >
                  <Icon name="close" size="md" />
                </button>
              </div>

              {/* Detail Content Body */}
              <div className="flex-1 overflow-y-auto p-4">
                {renderTabContent(mobileSection)}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>,
    document.body,
  );
}

export default SettingsModal;
