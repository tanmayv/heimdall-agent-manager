// REQ-BRG-2: Unit tests for provider duplicate and rename workflows in Providers settings
//
// RUN: node --test tests/ui_providers_duplicate_rename_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  parseProviderUrlParams,
  buildDuplicateForm,
  planSaveProvider,
  formFromProfile,
  profileFromForm,
  configuredTiers,
  providerDefault,
  shellHash,
  type ProviderForm,
} from '../src/ui/components/settings/providerManagement.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// -----------------------------------------------------------------------------
// 1. URL search param parsing for Duplicate & Bridge
// -----------------------------------------------------------------------------

test('parseProviderUrlParams extracts bridge and duplicateFrom query params', () => {
  const result = parseProviderUrlParams('?bridge=brg_123&duplicateFrom=claude');
  assert.equal(result.bridge, 'brg_123');
  assert.equal(result.duplicateFrom, 'claude');
});

test('parseProviderUrlParams decodes URL-encoded duplicateFrom and bridge', () => {
  const result = parseProviderUrlParams('?bridge=brg%20alpha&duplicateFrom=my%20claude%2Bmodel');
  assert.equal(result.bridge, 'brg alpha');
  assert.equal(result.duplicateFrom, 'my claude+model');
});

test('parseProviderUrlParams handles missing params and empty strings', () => {
  const result1 = parseProviderUrlParams('');
  assert.equal(result1.bridge, '');
  assert.equal(result1.duplicateFrom, '');

  const result2 = parseProviderUrlParams('?other=123');
  assert.equal(result2.bridge, '');
  assert.equal(result2.duplicateFrom, '');
});

// -----------------------------------------------------------------------------
// 2. buildDuplicateForm: Cloned form state with ${name}-copy and unlocked name
// -----------------------------------------------------------------------------

test('buildDuplicateForm pre-fills values from matching profile and defaults name to ${name}-copy', () => {
  const sampleProfile = {
    name: 'claude',
    source: 'store',
    enabled: true,
    command: ['anthropic', '--stream'],
    models: {
      flag: '--model',
      cheap: 'claude-3-5-haiku',
      normal: 'claude-3-5-sonnet',
      smart: 'claude-3-opus',
    },
    prompt_flags: ['--prompt'],
    yolo_flags: ['--dangerously-skip-permissions'],
    starter_prompt: 'You are running under Heimdall.',
    prompt_delivery: 'flag-injection',
    skill_dir: '.claude/skills',
    bootstrap_file_name: 'CLAUDE.md',
    startup_detection: {
      enabled: true,
      startup_probe_seconds: 30,
      capture_interval_ms: 250,
      blocked_patterns: ['Trust this folder?'],
      auto_enter_patterns: ['Press Enter to continue'],
      auto_enter_pre_keys: ['Down'],
      startup_unknown_is_blocked: true,
      sanitized_reason_mapping: ['trust_prompt=Waiting for folder trust'],
    },
    activity_detection: {
      enabled: true,
      sample_line_count: 25,
      ignore_bottom_lines: 1,
      check_interval_seconds: 3,
      min_gap_ms: 300,
      max_gap_ms: 4000,
    },
  };

  const form = buildDuplicateForm(sampleProfile, 'claude');

  // Verify name defaulted to ${name}-copy
  assert.equal(form.name, 'claude-copy');

  // Verify full profile values are cloned
  assert.equal(form.enabled, true);
  assert.deepEqual(form.command, ['anthropic', '--stream']);
  assert.equal(form.modelsFlag, '--model');
  assert.equal(form.modelsCheap, 'claude-3-5-haiku');
  assert.equal(form.modelsNormal, 'claude-3-5-sonnet');
  assert.equal(form.modelsSmart, 'claude-3-opus');
  assert.deepEqual(form.promptFlags, ['--prompt']);
  assert.deepEqual(form.yoloFlags, ['--dangerously-skip-permissions']);
  assert.equal(form.starterPrompt, 'You are running under Heimdall.');
  assert.equal(form.promptDelivery, 'flag-injection');
  assert.equal(form.skillDir, '.claude/skills');
  assert.equal(form.bootstrapFileName, 'CLAUDE.md');

  // Verify startup detection cloned
  assert.equal(form.startupEnabled, true);
  assert.equal(form.startupProbeSeconds, '30');
  assert.equal(form.startupCaptureIntervalMs, '250');
  assert.deepEqual(form.startupBlockedPatterns, ['Trust this folder?']);
  assert.deepEqual(form.startupAutoEnterPairs, [{ pattern: 'Press Enter to continue', preKey: 'Down' }]);
  assert.equal(form.startupUnknownIsBlocked, true);
  assert.deepEqual(form.startupReasonMappings, [{ key: 'trust_prompt', reason: 'Waiting for folder trust' }]);

  // Verify activity detection cloned
  assert.equal(form.activityEnabled, true);
  assert.equal(form.activitySampleLines, '25');
  assert.equal(form.activityIgnoreBottomLines, '1');
  assert.equal(form.activityCheckIntervalSeconds, '3');
  assert.equal(form.activityMinGapMs, '300');
  assert.equal(form.activityMaxGapMs, '4000');
});

// -----------------------------------------------------------------------------
// 3. planSaveProvider: Save, Duplicate, and Rename Decision Planning
// -----------------------------------------------------------------------------

test('planSaveProvider handles new duplicate provider saving (not a rename)', () => {
  const profile = { name: 'claude-copy', models: { cheap: 'h', normal: 'n' } };
  const plan = planSaveProvider({
    isEdit: false,
    providerName: '',
    formName: 'claude-copy',
    currentProfile: undefined,
    providersData: { default_provider: 'claude', default_tier: 'normal' },
    providersList: [{ name: 'claude', models: { normal: 'n' } }],
    profile,
  });

  assert.equal(plan.isRenamed, false);
  assert.equal(plan.newName, 'claude-copy');
  assert.equal(plan.shouldDeleteOld, false);
  assert.equal(plan.shouldUpdateDefault, false);
});

test('planSaveProvider handles editing provider without changing name (not a rename)', () => {
  const profile = { name: 'claude', models: { cheap: 'h', normal: 'n' } };
  const plan = planSaveProvider({
    isEdit: true,
    providerName: 'claude',
    formName: 'claude',
    currentProfile: { name: 'claude', source: 'store' },
    providersData: { default_provider: 'claude', default_tier: 'normal' },
    providersList: [{ name: 'claude', models: { normal: 'n' } }],
    profile,
  });

  assert.equal(plan.isRenamed, false);
  assert.equal(plan.newName, 'claude');
  assert.equal(plan.shouldDeleteOld, false);
  assert.equal(plan.shouldUpdateDefault, false);
});

test('planSaveProvider renames store-persisted provider that is NOT default', () => {
  const profile = { name: 'pi-renamed', models: { normal: 'n' } };
  const plan = planSaveProvider({
    isEdit: true,
    providerName: 'pi',
    formName: 'pi-renamed',
    currentProfile: { name: 'pi', source: 'store' },
    providersData: { default_provider: 'claude', default_tier: 'normal' },
    providersList: [
      { name: 'claude', models: { normal: 'n' } },
      { name: 'pi', source: 'store', models: { normal: 'n' } },
    ],
    profile,
  });

  assert.equal(plan.isRenamed, true);
  assert.equal(plan.oldName, 'pi');
  assert.equal(plan.newName, 'pi-renamed');
  assert.equal(plan.shouldDeleteOld, true, 'Store provider must have old entry deleted on rename');
  assert.equal(plan.shouldUpdateDefault, false, 'Non-default provider rename must not update default');
});

test('planSaveProvider renames store-persisted provider that IS the default provider', () => {
  const profile = { name: 'claude-v2', models: { smart: 'opus' } };
  const plan = planSaveProvider({
    isEdit: true,
    providerName: 'claude',
    formName: 'claude-v2',
    currentProfile: { name: 'claude', source: 'store' },
    providersData: { default_provider: 'claude', default_tier: 'smart' },
    providersList: [
      { name: 'claude', source: 'store', models: { smart: 'opus' } },
    ],
    profile,
  });

  assert.equal(plan.isRenamed, true);
  assert.equal(plan.oldName, 'claude');
  assert.equal(plan.newName, 'claude-v2');
  assert.equal(plan.shouldDeleteOld, true, 'Store provider must have old entry deleted on rename');
  assert.equal(plan.shouldUpdateDefault, true, 'Default provider rename must update default');
  assert.equal(plan.defaultTier, 'smart', 'Should preserve matching configured tier for default');
});

test('planSaveProvider renames config-persisted provider without issuing DELETE on old entry', () => {
  const profile = { name: 'config-renamed', models: { normal: 'n' } };
  const plan = planSaveProvider({
    isEdit: true,
    providerName: 'config-base',
    formName: 'config-renamed',
    currentProfile: { name: 'config-base', source: 'config' },
    providersData: { default_provider: 'config-base', default_tier: 'normal' },
    providersList: [
      { name: 'config-base', source: 'config', models: { normal: 'n' } },
    ],
    profile,
  });

  assert.equal(plan.isRenamed, true);
  assert.equal(plan.oldName, 'config-base');
  assert.equal(plan.newName, 'config-renamed');
  assert.equal(plan.shouldDeleteOld, false, 'Config-persisted provider must NOT issue DELETE on rename');
  assert.equal(plan.shouldUpdateDefault, true, 'Default provider rename must still update default');
  assert.equal(plan.defaultTier, 'normal');
});

test('planSaveProvider falls back to first available tier when previous default tier is not configured', () => {
  const profile = { name: 'claude-cheap-only', models: { cheap: 'haiku' } };
  const plan = planSaveProvider({
    isEdit: true,
    providerName: 'claude',
    formName: 'claude-cheap-only',
    currentProfile: { name: 'claude', source: 'store' },
    providersData: { default_provider: 'claude', default_tier: 'smart' },
    providersList: [
      { name: 'claude', source: 'store', models: { cheap: 'haiku', smart: 'opus' } },
    ],
    profile,
  });

  assert.equal(plan.isRenamed, true);
  assert.equal(plan.shouldUpdateDefault, true);
  assert.equal(plan.defaultTier, 'cheap', 'Fallback to cheap tier since smart is no longer configured');
});

// -----------------------------------------------------------------------------
// 4. Source Verification: ProvidersPanel.tsx UI contracts & Debug IDs
// -----------------------------------------------------------------------------

test('ProvidersPanel.tsx satisfies REQ-BRG-2 UI requirements and debug IDs', () => {
  const filePath = path.join(REPO_ROOT, 'src/ui/components/settings/ProvidersPanel.tsx');
  assert.ok(fs.existsSync(filePath), 'ProvidersPanel.tsx must exist');

  const content = fs.readFileSync(filePath, 'utf8');

  // Acceptance Criterion 1: Each provider row has a working 'Duplicate' button next to 'Edit'
  assert.match(
    content,
    /data-debug-id=\{`providers-duplicate-btn-\$\{name\}`\}/,
    'Provider row must include Duplicate button with data-debug-id="providers-duplicate-btn-${name}"'
  );
  assert.match(
    content,
    /href=\{shellHash\(`\/settings\/providers\/new\?bridge=\$\{encodeURIComponent\(selectedId\)\}&duplicateFrom=\$\{encodeURIComponent\(name\)\}`\)\}/,
    'Duplicate button must navigate to #settings/providers/new?bridge=${selectedId}&duplicateFrom=${encodeURIComponent(name)}'
  );

  // Acceptance Criterion 2: ProviderEditorPage header has 'Duplicate' button when editing an existing provider
  assert.match(
    content,
    /data-debug-id="providers-editor-header-duplicate-btn"/,
    'ProviderEditorPage header must have Duplicate button with data-debug-id="providers-editor-header-duplicate-btn"'
  );
  assert.match(
    content,
    /href=\{shellHash\(`\/settings\/providers\/new\?bridge=\$\{encodeURIComponent\(selectedId\)\}&duplicateFrom=\$\{encodeURIComponent\(providerName\)\}`\)\}/,
    'Header Duplicate button must navigate to new provider with duplicateFrom=${providerName}'
  );

  // Acceptance Criterion 3: Provider name can be edited/renamed (nameLocked is false)
  assert.match(
    content,
    /<ProviderFormFields form=\{form\} setForm=\{setForm\} nameLocked=\{false\} \/>/,
    'ProviderFormFields must receive nameLocked={false} to allow editing the provider name'
  );

  // Acceptance Criterion 4: duplicateFrom is read from routeSearch / search params
  assert.match(
    content,
    /duplicateFrom = searchParams\.get\('duplicateFrom'\)/,
    'ProviderEditorPage must read duplicateFrom from URL search params'
  );

  // Acceptance Criterion 5: RTK Query mutations & cache tags invalidation
  assert.match(
    content,
    /upsertProvider\(\{\s*bridgeId:\s*selectedId,\s*name:\s*newName,\s*profile\s*\}\)/,
    'saveProvider must issue upsertProvider (PUT)'
  );
  assert.match(
    content,
    /deleteProvider\(\{\s*bridgeId:\s*selectedId,\s*name:\s*plan\.oldName\s*\}\)/,
    'saveProvider must issue deleteProvider (DELETE) for store provider'
  );
  assert.match(
    content,
    /setDefaults\(\{\s*bridgeId:\s*selectedId,\s*provider:\s*newName,\s*tier:\s*plan\.defaultTier\s*\}\)/,
    'saveProvider must update default_provider via setDefaults (POST)'
  );
  assert.match(
    content,
    /bridgeSupportApi\.util\.invalidateTags/,
    'saveProvider must invalidate RTK Query cache tags'
  );
});
