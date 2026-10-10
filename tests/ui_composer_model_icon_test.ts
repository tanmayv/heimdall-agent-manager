// REQ-COMPOSER-MODEL-ICON-33:
// Regression tests for provider icons in compact/wide composer triggers and distinct model option icons.
//
// RUN: npx tsx tests/ui_composer_model_icon_test.ts
//  OR: node --test tests/ui_composer_model_icon_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const THREAD_PAGE_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');

test('REQ-COMPOSER-MODEL-ICON-33: tierMeta defines distinct icons for cheap, normal, and smart models', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Verify tierMeta definitions
  assert.match(
    content,
    /cheap:\s*\{\s*icon:\s*['"]rocket['"],\s*blurb:\s*['"]Fast, lower cost['"]\s*\}/,
    'cheap model must map to rocket icon'
  );
  assert.match(
    content,
    /normal:\s*\{\s*icon:\s*['"]spark['"],\s*blurb:\s*['"]Balanced['"]\s*\}/,
    'normal model must map to spark icon'
  );
  assert.match(
    content,
    /smart:\s*\{\s*icon:\s*['"]zap['"],\s*blurb:\s*['"]Best reasoning['"]\s*\}/,
    'smart model must map to zap icon'
  );
});

test('REQ-COMPOSER-MODEL-ICON-33: runtimeControls renders distinct model icons for cheap, normal, and smart options', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // runtimeControls iterates modelOptions with meta.icon
  assert.ok(
    content.includes('data-debug-id={`conversation-model-option-${t}`}'),
    'runtimeControls must render conversation-model-option-${t} buttons'
  );
  assert.match(
    content,
    /<Icon\s+name=\{meta\.icon\}\s+size=\{16\}\s*\/>/,
    'runtimeControls model option buttons must render <Icon name={meta.icon} size={16} />'
  );
});

test('REQ-COMPOSER-MODEL-ICON-33: tracks small composer container width using ResizeObserver', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // isSmallComposer state
  assert.match(
    content,
    /const\s*\[isSmallComposer,\s*setIsSmallComposer\]\s*=\s*useState\(false\);?/,
    'ConversationThreadPage must declare isSmallComposer state'
  );

  // ResizeObserver effect observing composerContainerRef
  assert.ok(
    content.includes('ResizeObserver'),
    'ConversationThreadPage must use ResizeObserver'
  );
  assert.match(
    content,
    /observer\.observe\(\s*el\s*\)/,
    'ResizeObserver must observe composerContainerRef element'
  );
  assert.match(
    content,
    /setIsSmallComposer\(\s*width\s*>\s*0\s*&&\s*width\s*<\s*540\s*\)/,
    'ResizeObserver must set isSmallComposer based on width < 540 threshold'
  );
});

test('REQ-COMPOSER-MODEL-ICON-33: useCompactModelTrigger activates on mobile or small composer width', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.match(
    content,
    /const\s+useCompactModelTrigger\s*=\s*isMobile\s*\|\|\s*isSmallComposer;?/,
    'useCompactModelTrigger must be true when isMobile || isSmallComposer'
  );
});

test('composer uses the provider catalog icon in compact and wide runtime triggers', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');
  assert.ok(content.includes('const activeProvider = instanceProvider || provider;'));
  const triggers = content.slice(content.indexOf('const runtimeMenuTrigger ='), content.indexOf('return (', content.indexOf('const runtimeMenuTrigger =')));
  assert.equal((triggers.match(/<ProviderIcon provider=\{activeProvider\} size=\{16\} \/>/g) || []).length, 2);
  assert.ok(!triggers.includes("{instanceProvider || 'model'}"), 'provider name is not shown in the composer chip');
  assert.ok(triggers.includes("{instanceModel || '—'}"), 'model name remains visible');
  assert.ok(triggers.includes('title={`${activeProvider'), 'provider name remains in the tooltip');
  assert.ok(triggers.includes('aria-label={`Change provider and model: ${activeProvider'), 'provider name remains accessible');
});

test('REQ-COMPOSER-MODEL-ICON-33: mobile Row 1 pairs flex-1 agent chip with shrink-0 model button', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Agent picker in Row 1 has flex-1 min-w-0
  assert.match(
    content,
    /<div\s+className="flex-1\s+min-w-0\s+sm:flex-initial\s+sm:order-4">\s*\{!isMobile/,
    'Agent picker wrapper must have flex-1 min-w-0 on mobile'
  );

  // Model selector wrapper uses shrink-0 when useCompactModelTrigger is true
  assert.match(
    content,
    /<div\s+className=\{useCompactModelTrigger\s*\?\s*['"]shrink-0\s+sm:flex-initial\s+sm:order-6['"]\s*:\s*['"]flex-1\s+min-w-0\s+sm:flex-initial\s+sm:order-6['"]\}>/,
    'Model selector wrapper must dynamically apply shrink-0 when compact trigger is active'
  );
});

test('REQ-COMPOSER-MODEL-ICON-33: all required debug IDs and accessibility attributes are preserved', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // data-debug-id="conversation-runtime-menu-btn"
  assert.ok(
    content.includes('data-debug-id="conversation-runtime-menu-btn"'),
    'Must preserve data-debug-id="conversation-runtime-menu-btn"'
  );
  assert.ok(
    content.includes('aria-label={`Change provider and model: ${activeProvider'),
    'Must label the runtime selector with its provider and model'
  );
  assert.ok(
    content.includes('data-debug-id="conversation-runtime-mobile-sheet"'),
    'Must preserve data-debug-id="conversation-runtime-mobile-sheet"'
  );
  assert.ok(
    content.includes('data-debug-id="conversation-agent-picker-btn"'),
    'Must preserve data-debug-id="conversation-agent-picker-btn"'
  );
});
