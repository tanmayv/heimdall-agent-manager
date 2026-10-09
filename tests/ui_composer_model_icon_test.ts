// REQ-COMPOSER-MODEL-ICON-33:
// Unit and regression tests for model/provider selector icon button on mobile & small composer width with distinct model icons.
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

test('REQ-COMPOSER-MODEL-ICON-33: compact model trigger renders as an h-9 w-9 icon button with activeModelIcon', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Active model icon resolution
  assert.match(
    content,
    /const\s+activeModel\s*=\s*model\s*\|\|\s*instanceModel\s*\|\|\s*['"]normal['"];?/,
    'activeModel must resolve from model, instanceModel, or default to normal'
  );
  assert.match(
    content,
    /const\s+activeModelIcon\s*=\s*activeModelMeta\.icon;?/,
    'activeModelIcon must resolve from activeModelMeta.icon'
  );

  // Compact button rendering
  assert.match(
    content,
    /grid\s+h-9\s+w-9\s+shrink-0\s+place-items-center\s+rounded-xl\s+border\s+border-subtle\s+bg-surface-raised\s+text-primary\s+hover:bg-neutral-soft/,
    'Compact trigger must have h-9 w-9 shrink-0 place-items-center styling'
  );
  assert.match(
    content,
    /<Icon\s+name=\{activeModelIcon\}\s+size=\{16\}\s*\/>/,
    'Compact trigger must render <Icon name={activeModelIcon} size={16} />'
  );
});

test('REQ-COMPOSER-MODEL-ICON-33: wide model trigger renders active model icon with text labels and chevron', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.match(
    content,
    /<Icon\s+name=\{activeModelIcon\}\s+size=\{14\}\s+className="shrink-0\s+text-muted"\s*\/>/,
    'Wide trigger must render activeModelIcon prefix'
  );
  assert.ok(
    content.includes('instanceProvider || \'model\''),
    'Wide trigger must display instanceProvider'
  );
  assert.ok(
    content.includes('instanceModel || \'—\''),
    'Wide trigger must display instanceModel'
  );
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
    content.includes('aria-label="Change provider and model"'),
    'Must preserve aria-label="Change provider and model"'
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
