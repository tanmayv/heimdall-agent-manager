// REQ-SET-3, REQ-SET-6: Unit tests for GeneralSettingsPanel & settingsPersistence
//
// RUN: node --test tests/ui_general_settings_test.ts

import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SETTINGS_STORAGE_KEY,
  DEFAULT_GENERAL_SETTINGS,
  loadSettings,
  saveSettings,
  type GeneralSettings,
} from '../src/ui/utils/settingsPersistence.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// In-memory mock localStorage
class MockStorage {
  private store = new Map<string, string>();

  getItem(key: string): string | null {
    return this.store.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.store.set(key, String(value));
  }

  removeItem(key: string): void {
    this.store.delete(key);
  }

  clear(): void {
    this.store.clear();
  }

  get length(): number {
    return this.store.size;
  }

  key(index: number): string | null {
    return Array.from(this.store.keys())[index] ?? null;
  }
}

// ---------------------------------------------------------------------------
// 1. settingsPersistence: Defaults and Fallbacks
// ---------------------------------------------------------------------------

test('DEFAULT_GENERAL_SETTINGS specifies correct default values', () => {
  assert.equal(DEFAULT_GENERAL_SETTINGS.queuedMessages, 'queue');
  assert.equal(DEFAULT_GENERAL_SETTINGS.permissionPreset, 'default');
  assert.equal(DEFAULT_GENERAL_SETTINGS.planReviewPolicy, 'always_ask');
  assert.equal(DEFAULT_GENERAL_SETTINGS.browserJsExecutionPolicy, 'request_review');
  assert.ok(DEFAULT_GENERAL_SETTINGS.commandSetupScript.includes('source ~/.jetski_shell_setup'));
  assert.equal(DEFAULT_GENERAL_SETTINGS.advancedExpanded, true);
});

test('loadSettings returns defaults when localStorage is empty', () => {
  (globalThis as any).window = {
    localStorage: new MockStorage(),
  };

  const settings = loadSettings();
  assert.deepEqual(settings, DEFAULT_GENERAL_SETTINGS);
});

// ---------------------------------------------------------------------------
// 2. settingsPersistence: Save & Load Round-Trip
// ---------------------------------------------------------------------------

test('saveSettings persists modified values to localStorage under heimdall:settings:general', () => {
  const mockStorage = new MockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage,
  };

  saveSettings({
    queuedMessages: 'send_immediately',
    permissionPreset: 'strict',
    planReviewPolicy: 'never_ask',
    browserJsExecutionPolicy: 'disabled',
    commandSetupScript: 'echo "hello world"',
    advancedExpanded: false,
  });

  const raw = mockStorage.getItem(SETTINGS_STORAGE_KEY);
  assert.ok(raw !== null, 'Item should be written to storage key');
  const parsed = JSON.parse(raw);
  assert.equal(parsed.queuedMessages, 'send_immediately');
  assert.equal(parsed.permissionPreset, 'strict');
  assert.equal(parsed.planReviewPolicy, 'never_ask');
  assert.equal(parsed.browserJsExecutionPolicy, 'disabled');
  assert.equal(parsed.commandSetupScript, 'echo "hello world"');
  assert.equal(parsed.advancedExpanded, false);

  // loadSettings should return the persisted values
  const loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately');
  assert.equal(loaded.permissionPreset, 'strict');
  assert.equal(loaded.planReviewPolicy, 'never_ask');
  assert.equal(loaded.browserJsExecutionPolicy, 'disabled');
  assert.equal(loaded.commandSetupScript, 'echo "hello world"');
  assert.equal(loaded.advancedExpanded, false);
});

test('saveSettings supports partial updates without wiping other settings', () => {
  const mockStorage = new MockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage,
  };

  saveSettings({ queuedMessages: 'send_immediately' });
  let loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately');
  assert.equal(loaded.permissionPreset, 'default'); // Default preserved

  saveSettings({ permissionPreset: 'custom' });
  loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately'); // Previously saved preserved
  assert.equal(loaded.permissionPreset, 'custom');
});

// ---------------------------------------------------------------------------
// 3. GeneralSettingsPanel: Static Verification & Design Tokens
// ---------------------------------------------------------------------------

test('GeneralSettingsPanel.tsx source file exists and exports GeneralSettingsPanel', () => {
  const filePath = path.join(
    REPO_ROOT,
    'src/ui/components/settings/GeneralSettingsPanel.tsx',
  );
  assert.ok(fs.existsSync(filePath), 'GeneralSettingsPanel.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf-8');
  assert.ok(
    content.includes('export function GeneralSettingsPanel') ||
      content.includes('export const GeneralSettingsPanel'),
    'Must export GeneralSettingsPanel',
  );
  assert.ok(
    content.includes('export default GeneralSettingsPanel'),
    'Must provide default export',
  );
});

test('GeneralSettingsPanel.tsx satisfies design token conventions', () => {
  const filePath = path.join(
    REPO_ROOT,
    'src/ui/components/settings/GeneralSettingsPanel.tsx',
  );
  const content = fs.readFileSync(filePath, 'utf-8');

  // Must use design tokens
  assert.ok(content.includes('border-subtle'), 'Must use border-subtle');
  assert.ok(content.includes('bg-surface'), 'Must use bg-surface');
  assert.ok(content.includes('text-primary'), 'Must use text-primary');
  assert.ok(content.includes('text-muted'), 'Must use text-muted');
  assert.ok(content.includes('rounded-xl'), 'Must use rounded-xl for cards');
});

test('GeneralSettingsPanel.tsx renders all 5 required sections and controls', () => {
  const filePath = path.join(
    REPO_ROOT,
    'src/ui/components/settings/GeneralSettingsPanel.tsx',
  );
  const content = fs.readFileSync(filePath, 'utf-8');

  // 1. Header
  assert.ok(content.includes('General'), 'Must contain General header title');
  assert.ok(
    content.includes('Configure agent execution, queued message delivery, and permissions.'),
    'Must contain General header description',
  );

  // 2. Execution
  assert.ok(content.includes('Execution'), 'Must contain Execution section title');
  assert.ok(content.includes('Queued Messages'), 'Must contain Queued Messages card title');
  assert.ok(content.includes('Configure when follow-up messages are sent.'), 'Must contain Queued Messages description');
  assert.ok(content.includes('Keyboard shortcuts'), 'Must contain Keyboard shortcuts text');
  assert.ok(content.includes('toggle-queued-messages-queue'), 'Must contain Queue toggle button');
  assert.ok(content.includes('toggle-queued-messages-send-immediately'), 'Must contain Send Immediately toggle button');

  // 3. Global Permissions
  assert.ok(content.includes('Global Permissions'), 'Must contain Global Permissions title');
  assert.ok(content.includes('Permission Preset'), 'Must contain Permission Preset row');
  assert.ok(content.includes('Tool Permissions'), 'Must contain Tool Permissions row');
  assert.ok(content.includes('81'), 'Must contain Tool Permissions badge count 81');
  assert.ok(content.includes('Network Access Rules'), 'Must contain Network Access Rules row');

  // 4. Agent Behavior
  assert.ok(content.includes('Agent Behavior'), 'Must contain Agent Behavior section');
  assert.ok(content.includes('Plan Review Policy'), 'Must contain Plan Review Policy');
  assert.ok(content.includes('Type <Kbd>/</Kbd> and select <Kbd>plan</Kbd>'), 'Must contain /plan helper text with Kbd');

  // 5. Browser
  assert.ok(content.includes('Browser'), 'Must contain Browser section');
  assert.ok(content.includes('Browser Javascript Execution Policy'), 'Must contain Browser Javascript Execution Policy');
  assert.ok(content.includes('Browser Actuation Rules'), 'Must contain Browser Actuation Rules');

  // 6. Advanced / Terminal
  assert.ok(content.includes('Advanced'), 'Must contain collapsible Advanced trigger');
  assert.ok(content.includes('Terminal'), 'Must contain Terminal sub-section');
  assert.ok(content.includes('Command Setup Script'), 'Must contain Command Setup Script card');
  assert.ok(content.includes('source ~/.jetski_shell_setup'), 'Must contain initial setup script example');
});
