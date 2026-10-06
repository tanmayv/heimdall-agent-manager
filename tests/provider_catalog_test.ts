// REQ-BRG-3: Unit tests for supported provider catalog and flag/model autocomplete
//
// RUN: node --test tests/provider_catalog_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SUPPORTED_PROVIDER_PRESETS,
  PRESET_OPTIONS,
  getProviderPreset,
  getModelSuggestions,
  getFlagSuggestions,
  formFromPreset,
  type ProviderPreset,
} from '../src/ui/components/settings/providerCatalog.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// -----------------------------------------------------------------------------
// 1. Canonical provider catalog definitions
// -----------------------------------------------------------------------------

test('SUPPORTED_PROVIDER_PRESETS defines canonical presets for all 5 required providers', () => {
  const expectedKeys = ['claude', 'jetski', 'antigravity', 'codex', 'copilot'];
  const actualKeys = Object.keys(SUPPORTED_PROVIDER_PRESETS);

  for (const key of expectedKeys) {
    assert.ok(actualKeys.includes(key), `Preset '${key}' must be defined in SUPPORTED_PROVIDER_PRESETS`);
    const preset = SUPPORTED_PROVIDER_PRESETS[key];
    assert.equal(preset.name, key, `Preset name must match key '${key}'`);
    assert.ok(preset.label.length > 0, `Preset '${key}' must have a non-empty label`);
    assert.ok(preset.defaultCommand.length > 0, `Preset '${key}' must have defaultCommand`);
    assert.ok(preset.modelsFlag === '--model' || preset.modelsFlag === '-m', `Preset '${key}' must have valid modelsFlag`);
    assert.ok(Array.isArray(preset.availableModels) && preset.availableModels.length > 0, `Preset '${key}' must have availableModels`);
    assert.ok(Array.isArray(preset.promptFlags), `Preset '${key}' must have promptFlags array`);
    assert.ok(Array.isArray(preset.yoloFlags), `Preset '${key}' must have yoloFlags array`);
    assert.ok(preset.starterPrompt.length > 0, `Preset '${key}' must have starterPrompt`);
    assert.ok(preset.promptDelivery === 'flag-injection' || preset.promptDelivery === 'positional', `Preset '${key}' must have promptDelivery`);
    assert.ok(preset.skillDir.length > 0, `Preset '${key}' must have skillDir`);
    assert.ok(preset.bootstrapFileName === 'CLAUDE.md' || preset.bootstrapFileName === 'AGENTS.md', `Preset '${key}' must have bootstrapFileName`);

    // Ensure default tiers are all members of availableModels
    assert.ok(preset.availableModels.includes(preset.defaultTiers.cheap), `Preset '${key}' cheap tier must be in availableModels`);
    assert.ok(preset.availableModels.includes(preset.defaultTiers.normal), `Preset '${key}' normal tier must be in availableModels`);
    assert.ok(preset.availableModels.includes(preset.defaultTiers.smart), `Preset '${key}' smart tier must be in availableModels`);
  }
});

test('PRESET_OPTIONS includes Custom followed by all supported providers', () => {
  const keys = PRESET_OPTIONS.map((opt) => opt.key);
  assert.deepEqual(keys, ['custom', 'claude', 'jetski', 'antigravity', 'codex', 'copilot']);
});

test('Specific provider preset parameters match system architecture', () => {
  // Claude
  const claude = SUPPORTED_PROVIDER_PRESETS.claude;
  assert.equal(claude.bootstrapFileName, 'CLAUDE.md');
  assert.deepEqual(claude.promptFlags, ['--prompt', '-p']);
  assert.deepEqual(claude.yoloFlags, ['--dangerously-skip-permissions']);

  // Codex
  const codex = SUPPORTED_PROVIDER_PRESETS.codex;
  assert.equal(codex.modelsFlag, '-m');
  assert.deepEqual(codex.yoloFlags, ['--approval-policy=never', '--yolo']);

  // Antigravity
  const antigravity = SUPPORTED_PROVIDER_PRESETS.antigravity;
  assert.deepEqual(antigravity.defaultCommand, ['agy']);
  assert.deepEqual(antigravity.promptFlags, ['--prompt-interactive', '-i']);
  assert.deepEqual(antigravity.yoloFlags, ['--dangerously-skip-permissions']);

  // Copilot
  const copilot = SUPPORTED_PROVIDER_PRESETS.copilot;
  assert.deepEqual(copilot.promptFlags, ['-i']);
  assert.deepEqual(copilot.yoloFlags, ['--yolo']);
});

// -----------------------------------------------------------------------------
// 2. Preset lookup via getProviderPreset
// -----------------------------------------------------------------------------

test('getProviderPreset resolves canonical presets by exact name', () => {
  assert.equal(getProviderPreset('claude')?.name, 'claude');
  assert.equal(getProviderPreset('jetski')?.name, 'jetski');
  assert.equal(getProviderPreset('antigravity')?.name, 'antigravity');
  assert.equal(getProviderPreset('codex')?.name, 'codex');
  assert.equal(getProviderPreset('copilot')?.name, 'copilot');
});

test('getProviderPreset is case-insensitive and trims whitespace', () => {
  assert.equal(getProviderPreset('  Claude  ')?.name, 'claude');
  assert.equal(getProviderPreset('JETSKI')?.name, 'jetski');
  assert.equal(getProviderPreset('AntiGravity')?.name, 'antigravity');
  assert.equal(getProviderPreset('CoDeX')?.name, 'codex');
});

test('getProviderPreset resolves by command executable or binary path', () => {
  // agy is the binary for antigravity
  assert.equal(getProviderPreset('agy')?.name, 'antigravity');
  assert.equal(getProviderPreset('/usr/local/bin/agy')?.name, 'antigravity');
  assert.equal(getProviderPreset('/usr/bin/claude')?.name, 'claude');
  assert.equal(getProviderPreset('/opt/homebrew/bin/copilot')?.name, 'copilot');
});

test('getProviderPreset resolves duplicated provider names', () => {
  assert.equal(getProviderPreset('claude-copy')?.name, 'claude');
  assert.equal(getProviderPreset('jetski-copy-2')?.name, 'jetski');
  assert.equal(getProviderPreset('codex-copy')?.name, 'codex');
});

test('getProviderPreset returns null for custom or unknown providers', () => {
  assert.equal(getProviderPreset('custom'), null);
  assert.equal(getProviderPreset('Custom'), null);
  assert.equal(getProviderPreset('my-custom-llm'), null);
  assert.equal(getProviderPreset('ollama'), null);
  assert.equal(getProviderPreset('local-model'), null);
  assert.equal(getProviderPreset(''), null);
  assert.equal(getProviderPreset('   '), null);
  assert.equal(getProviderPreset(null as any), null);
  assert.equal(getProviderPreset(undefined as any), null);
});

// -----------------------------------------------------------------------------
// 3. Suggestion retrieval helpers
// -----------------------------------------------------------------------------

test('getModelSuggestions returns available models for supported presets', () => {
  const claudeModels = getModelSuggestions('claude');
  assert.ok(claudeModels.length > 0);
  assert.ok(claudeModels.includes('claude-3-7-sonnet-latest'));
  assert.ok(claudeModels.includes('claude-3-5-haiku-latest'));

  const jetskiModels = getModelSuggestions('jetski');
  assert.ok(jetskiModels.includes('Gemini 3.5 Flash'));
  assert.ok(jetskiModels.includes('Gemini 3.1 Pro'));

  const antigravityModels = getModelSuggestions(SUPPORTED_PROVIDER_PRESETS.antigravity);
  assert.ok(antigravityModels.includes('Gemini 3.5 Flash (Medium)'));
});

test('getModelSuggestions returns empty array for custom or unknown providers', () => {
  assert.deepEqual(getModelSuggestions('custom'), []);
  assert.deepEqual(getModelSuggestions('unknown-provider'), []);
  assert.deepEqual(getModelSuggestions(null), []);
});

test('getFlagSuggestions returns model and CLI flags for supported presets', () => {
  const claudeFlags = getFlagSuggestions('claude');
  assert.ok(claudeFlags.modelsFlag.includes('--model'));
  assert.ok(claudeFlags.modelsFlag.includes('-m'));
  assert.deepEqual(claudeFlags.promptFlags, ['--prompt', '-p']);
  assert.deepEqual(claudeFlags.yoloFlags, ['--dangerously-skip-permissions']);

  const codexFlags = getFlagSuggestions('codex');
  assert.ok(codexFlags.modelsFlag.includes('-m'));
  assert.deepEqual(codexFlags.yoloFlags, ['--approval-policy=never', '--yolo']);

  const agyFlags = getFlagSuggestions('agy');
  assert.deepEqual(agyFlags.promptFlags, ['--prompt-interactive', '-i']);
  assert.deepEqual(agyFlags.yoloFlags, ['--dangerously-skip-permissions']);
});

test('getFlagSuggestions returns empty arrays for custom or unknown providers', () => {
  const customFlags = getFlagSuggestions('custom');
  assert.deepEqual(customFlags.modelsFlag, []);
  assert.deepEqual(customFlags.promptFlags, []);
  assert.deepEqual(customFlags.yoloFlags, []);

  const nullFlags = getFlagSuggestions(null);
  assert.deepEqual(nullFlags.modelsFlag, []);
  assert.deepEqual(nullFlags.promptFlags, []);
  assert.deepEqual(nullFlags.yoloFlags, []);
});

// -----------------------------------------------------------------------------
// 4. formFromPreset pre-populates form state correctly
// -----------------------------------------------------------------------------

test('formFromPreset converts preset into full ProviderForm', () => {
  const claudeForm = formFromPreset(SUPPORTED_PROVIDER_PRESETS.claude);
  assert.equal(claudeForm.name, 'claude');
  assert.equal(claudeForm.enabled, true);
  assert.deepEqual(claudeForm.command, ['claude']);
  assert.equal(claudeForm.modelsFlag, '--model');
  assert.equal(claudeForm.modelsCheap, 'claude-3-5-haiku-latest');
  assert.equal(claudeForm.modelsNormal, 'claude-3-5-sonnet-latest');
  assert.equal(claudeForm.modelsSmart, 'claude-3-7-sonnet-latest');
  assert.deepEqual(claudeForm.promptFlags, ['--prompt', '-p']);
  assert.deepEqual(claudeForm.yoloFlags, ['--dangerously-skip-permissions']);
  assert.equal(claudeForm.bootstrapFileName, 'CLAUDE.md');
  assert.equal(claudeForm.promptDelivery, 'flag-injection');
  assert.equal(claudeForm.skillDir, '.claude/skills');

  const codexForm = formFromPreset(SUPPORTED_PROVIDER_PRESETS.codex);
  assert.equal(codexForm.modelsFlag, '-m');
  assert.equal(codexForm.modelsCheap, 'gpt-4o-mini');
  assert.equal(codexForm.bootstrapFileName, 'AGENTS.md');
});

// -----------------------------------------------------------------------------
// 5. ProvidersPanel.tsx integration and UI contracts
// -----------------------------------------------------------------------------

test('ProvidersPanel.tsx satisfies REQ-BRG-3 preset picker and autocomplete contracts', () => {
  const panelPath = path.join(REPO_ROOT, 'src/ui/components/settings/ProvidersPanel.tsx');
  assert.ok(fs.existsSync(panelPath), 'ProvidersPanel.tsx must exist');

  const content = fs.readFileSync(panelPath, 'utf-8');

  // Acceptance Criterion 1: Imports from providerCatalog.ts
  assert.match(
    content,
    /from '\.\/providerCatalog\.ts'/,
    'ProvidersPanel.tsx must import from providerCatalog.ts'
  );

  // Acceptance Criterion 2: Preset picker rendered for new provider
  assert.match(
    content,
    /data-debug-id="providers-preset-picker"/,
    'ProvidersPanel.tsx must render preset picker container'
  );
  assert.match(
    content,
    /data-debug-id="providers-preset-select"/,
    'ProvidersPanel.tsx must render preset select dropdown'
  );
  assert.match(
    content,
    /data-debug-id="providers-preset-chips"/,
    'ProvidersPanel.tsx must render preset quick-select chips'
  );

  // Acceptance Criterion 3: Model inputs offer datalist autocomplete suggestions
  assert.match(
    content,
    /data-debug-id="providers-models-datalist"/,
    'ProvidersPanel.tsx must provide datalist for model suggestions'
  );
  assert.match(
    content,
    /id="models-list"/,
    'ProvidersPanel.tsx must wire models-list datalist id'
  );
  assert.match(
    content,
    /list=\{matchedPreset \? "models-list" : undefined\}/,
    'Cheap, normal, and smart model inputs must wire list="models-list" when matchedPreset is present'
  );

  // Acceptance Criterion 4: Flag inputs offer suggestions / quick-add chips
  assert.match(
    content,
    /data-debug-id="providers-editor-models-flag-suggestions"/,
    'ProvidersPanel.tsx must offer models flag suggestions'
  );
  assert.match(
    content,
    /data-debug-id=\{`\$\{prefix\}-suggestions`\}/,
    'ChipListInput must render suggestions container when suggestions are provided'
  );
  assert.match(
    content,
    /data-debug-id=\{`\$\{prefix\}-insert-recommended-btn`\}/,
    'ChipListInput must offer "Insert recommended flags" action'
  );

  // Acceptance Criterion 5: Custom providers allow unrestricted freeform text entry
  assert.match(
    content,
    /const matchedPreset = useMemo\(\(\) => getProviderPreset\(form\.command\[0\] \|\| form\.name\)/,
    'ProviderFormFields must resolve matchedPreset dynamically, returning null for custom providers'
  );
});

// -----------------------------------------------------------------------------
// 6. REQ-PROVIDER-ADDITIVE-1: Simplified built-in editor and detected CLIs bar
// -----------------------------------------------------------------------------

test('ProvidersPanel.tsx satisfies REQ-PROVIDER-ADDITIVE-1 built-in simplified model-only view and custom provider flow', () => {
  const panelPath = path.join(REPO_ROOT, 'src/ui/components/settings/ProvidersPanel.tsx');
  assert.ok(fs.existsSync(panelPath), 'ProvidersPanel.tsx must exist');

  const content = fs.readFileSync(panelPath, 'utf-8');

  // Acceptance Criterion: Detected CLIs Quick-Action Bar with one-click enable
  assert.match(
    content,
    /data-debug-id="detected-providers-bar"/,
    'ProvidersPanel.tsx must render detected-providers-bar'
  );
  assert.match(
    content,
    /data-debug-id=\{`detected-provider-chip-\$\{cli\.name\}`\}/,
    'ProvidersPanel.tsx must render detected provider chips'
  );
  assert.match(
    content,
    /data-debug-id=\{`enable-detected-\$\{cli\.name\}-btn`\}/,
    'ProvidersPanel.tsx must render enable button for detected providers'
  );
  assert.match(
    content,
    /data-debug-id="enable-all-detected-btn"/,
    'ProvidersPanel.tsx must render enable-all-detected-btn'
  );

  // Acceptance Criterion: "Add Custom Provider" button/mode
  assert.match(
    content,
    /data-debug-id="providers-add-custom-btn"/,
    'ProvidersPanel.tsx must offer "Add Custom Provider" action button'
  );
  assert.match(
    content,
    /Add Custom Provider/,
    'ProvidersPanel.tsx must include text "Add Custom Provider"'
  );

  // Acceptance Criterion: BUILTIN_PROVIDERS defined for curated CLIs
  assert.match(
    content,
    /BUILTIN_PROVIDERS/,
    'ProvidersPanel.tsx must define or export BUILTIN_PROVIDERS'
  );

  // Acceptance Criterion: Simplified built-in editor page
  assert.match(
    content,
    /data-debug-id="providers-builtin-editor"/,
    'ProviderEditorPage must render simplified providers-builtin-editor for built-in providers'
  );
  assert.match(
    content,
    /data-debug-id="providers-editor-default-tier-selector"/,
    'ProviderEditorPage must render default tier selector for built-in providers'
  );

  // Acceptance Criterion: Built-in editor exposes cheap, normal, and smart model inputs
  assert.match(
    content,
    /id="providers-editor-models-cheap-input"/,
    'ProviderEditorPage must expose Cheap model input'
  );
  assert.match(
    content,
    /id="providers-editor-models-normal-input"/,
    'ProviderEditorPage must expose Normal model input'
  );
  assert.match(
    content,
    /id="providers-editor-models-smart-input"/,
    'ProviderEditorPage must expose Smart model input'
  );
});

test('bridgeSupport.ts exports useGetDetectedBridgeProvidersQuery and useEnableBridgeProvidersMutation', () => {
  const bridgeSupportPath = path.join(REPO_ROOT, 'src/ui/api/endpoints/bridgeSupport.ts');
  assert.ok(fs.existsSync(bridgeSupportPath), 'bridgeSupport.ts must exist');

  const content = fs.readFileSync(bridgeSupportPath, 'utf-8');
  assert.match(content, /getDetectedBridgeProviders/, 'bridgeSupport.ts must define getDetectedBridgeProviders endpoint');
  assert.match(content, /enableBridgeProviders/, 'bridgeSupport.ts must define enableBridgeProviders endpoint');
  assert.match(content, /useGetDetectedBridgeProvidersQuery/, 'bridgeSupport.ts must export useGetDetectedBridgeProvidersQuery');
  assert.match(content, /useEnableBridgeProvidersMutation/, 'bridgeSupport.ts must export useEnableBridgeProvidersMutation');
  assert.match(content, /\/bridges\/\$\{encodeURIComponent\(bridgeId\)\}\/detected-providers/, 'must call /bridges/{bridgeId}/detected-providers');
  assert.match(content, /\/bridges\/\$\{encodeURIComponent\(bridgeId\)\}\/providers\/enable-detected/, 'must call /bridges/{bridgeId}/providers/enable-detected');
});
