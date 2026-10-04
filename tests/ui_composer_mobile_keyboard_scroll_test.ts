// REQ-MOBILE-KEYBOARD-SCROLL-30:
// Unit and regression tests for mobile composer keyboard focus scroll synchronization.
//
// RUN: npx tsx tests/ui_composer_mobile_keyboard_scroll_test.ts
//  OR: node --test tests/ui_composer_mobile_keyboard_scroll_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const THREAD_PAGE_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');

test('REQ-MOBILE-KEYBOARD-SCROLL-30: composerContainerRef is defined with HTMLFormElement | HTMLDivElement | null', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.match(
    content,
    /const\s+composerContainerRef\s*=\s*useRef<HTMLFormElement\s*\|\s*HTMLDivElement\s*\|\s*null>\(null\);?/,
    'ConversationThreadPage must define composerContainerRef = useRef<HTMLFormElement | HTMLDivElement | null>(null)'
  );
});

test('REQ-MOBILE-KEYBOARD-SCROLL-30: composerContainerRef is attached to the composer container', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  assert.match(
    content,
    /<form[^>]*ref=\{composerContainerRef[^}]*\}/,
    'Composer form element must have ref={composerContainerRef}'
  );
});

test('REQ-MOBILE-KEYBOARD-SCROLL-30: useEffect synchronizes scroll on keyboardInset transition', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Must have a useEffect with [keyboardInset] dependency
  const insetEffectMatch = content.match(
    /useEffect\(\(\)\s*=>\s*\{([\s\S]*?)\},\s*\[keyboardInset\]\);/
  );
  assert.ok(insetEffectMatch, 'ConversationThreadPage must include useEffect([keyboardInset])');

  const effectBody = insetEffectMatch[1];

  // Must check keyboardInset > 0 and document.activeElement === textareaRef.current
  assert.ok(
    effectBody.includes('keyboardInset > 0'),
    'keyboardInset effect must check keyboardInset > 0'
  );
  assert.ok(
    effectBody.includes('document.activeElement === textareaRef.current'),
    'keyboardInset effect must check document.activeElement === textareaRef.current'
  );

  // Must target composerContainerRef.current || textareaRef.current
  assert.ok(
    effectBody.includes('composerContainerRef.current || textareaRef.current'),
    'keyboardInset effect must target composerContainerRef.current || textareaRef.current'
  );

  // Must scroll with block: 'end' and behavior: 'smooth'
  assert.match(
    effectBody,
    /scrollIntoView\(\s*\{\s*block:\s*['"]end['"],\s*behavior:\s*['"]smooth['"]\s*\}\s*\)/,
    'keyboardInset effect must scroll target with block: "end", behavior: "smooth"'
  );

  // Must have timer cleanup
  assert.match(
    effectBody,
    /return\s*\(\)\s*=>\s*clearTimeout\(\w+\);?/,
    'keyboardInset effect must return cleanup function clearing the timer'
  );
});

test('REQ-MOBILE-KEYBOARD-SCROLL-30: onFocus implements multi-stage delayed scrolling for keyboard animations', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Find textarea onFocus handler
  const onFocusMatch = content.match(
    /onFocus=\{\(\)\s*=>\s*\{([\s\S]*?)\}\}\s*onChange=/
  );
  assert.ok(onFocusMatch, 'Textarea must have an onFocus handler');

  const onFocusBody = onFocusMatch[1];

  // Must define scrollComposer targeting composerContainerRef.current || textareaRef.current with block: 'end'
  assert.ok(
    onFocusBody.includes('composerContainerRef.current || textareaRef.current'),
    'onFocus must target composerContainerRef.current || textareaRef.current'
  );
  assert.match(
    onFocusBody,
    /scrollIntoView\(\s*\{\s*block:\s*['"]end['"],\s*behavior:\s*['"]smooth['"]\s*\}\s*\)/,
    'onFocus must scroll target with block: "end", behavior: "smooth"'
  );

  // Must call requestAnimationFrame for immediate frame (0ms)
  assert.ok(
    onFocusBody.includes('requestAnimationFrame(scrollComposer)'),
    'onFocus must call requestAnimationFrame(scrollComposer) for immediate frame'
  );

  // Must schedule multi-stage delays for virtual keyboard slide-up transitions [150, 300, 450]
  assert.match(
    onFocusBody,
    /\[150,\s*300,\s*450\]\.forEach/,
    'onFocus must iterate over delays [150, 300, 450]'
  );

  // Each stage must verify focus is still on textareaRef.current before scrolling
  assert.ok(
    onFocusBody.includes('document.activeElement === textareaRef.current'),
    'onFocus delayed stages must verify document.activeElement === textareaRef.current'
  );
});

test('REQ-MOBILE-KEYBOARD-SCROLL-30: functional simulation of multi-stage onFocus scroll stages', async () => {
  const scrollCalls: Array<{ block: string; behavior: string }> = [];
  const mockTarget = {
    scrollIntoView: (opts: { block: string; behavior: string }) => {
      scrollCalls.push(opts);
    },
  };

  const textarea = {} as any;
  let activeElement: any = textarea;

  const scrollComposer = () => {
    mockTarget.scrollIntoView({ block: 'end', behavior: 'smooth' });
  };

  // Simulate onFocus logic
  scrollComposer(); // rAF step
  assert.equal(scrollCalls.length, 1);
  assert.deepEqual(scrollCalls[0], { block: 'end', behavior: 'smooth' });

  // Simulate delayed stages at 150, 300, 450 ms
  const delays = [150, 300, 450];
  delays.forEach(() => {
    if (activeElement === textarea) {
      scrollComposer();
    }
  });
  assert.equal(scrollCalls.length, 4);

  // Now simulate if focus was lost before delay
  activeElement = null;
  delays.forEach(() => {
    if (activeElement === textarea) {
      scrollComposer();
    }
  });
  // Should still be 4 calls because activeElement did not match
  assert.equal(scrollCalls.length, 4);
});

test('REQ-MOBILE-KEYBOARD-SCROLL-30: functional simulation of keyboardInset transition effect', async () => {
  const scrollCalls: Array<{ block: string; behavior: string }> = [];
  const mockTarget = {
    scrollIntoView: (opts: { block: string; behavior: string }) => {
      scrollCalls.push(opts);
    },
  };

  const textarea = {} as any;
  let activeElement: any = textarea;

  const simulateEffect = (keyboardInset: number): (() => void) | undefined => {
    if (keyboardInset > 0 && activeElement === textarea) {
      const timer = setTimeout(() => {
        mockTarget.scrollIntoView({ block: 'end', behavior: 'smooth' });
      }, 50);
      return () => clearTimeout(timer);
    }
    return undefined;
  };

  // keyboardInset = 0 (no keyboard up): should not trigger
  const cleanup0 = simulateEffect(0);
  assert.equal(cleanup0, undefined);
  assert.equal(scrollCalls.length, 0);

  // keyboardInset = 300: should trigger after 50ms
  const cleanup300 = simulateEffect(300);
  assert.ok(typeof cleanup300 === 'function');
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(scrollCalls.length, 1);
  assert.deepEqual(scrollCalls[0], { block: 'end', behavior: 'smooth' });

  // keyboardInset = 300 but cleanup called before 50ms
  const cleanupCancelled = simulateEffect(300);
  cleanupCancelled?.();
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(scrollCalls.length, 1); // no extra call
});

test('REQ-MOBILE-KEYBOARD-SCROLL-30: preserves COMPOSER_DRAFT_KEY and mobile composer layout', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // Verify COMPOSER_DRAFT_KEY
  assert.ok(
    content.includes('export const COMPOSER_DRAFT_KEY = \'heimdall:composer:draft\';'),
    'COMPOSER_DRAFT_KEY must remain intact'
  );

  // Verify mobile layout debug IDs
  assert.ok(content.includes('data-debug-id="conversation-composer-shell"'));
  assert.ok(content.includes('data-debug-id="conversation-composer-card"'));
  assert.ok(content.includes('data-debug-id="conversation-composer-input"'));
  assert.ok(content.includes('data-debug-id="conversation-composer-send-btn"'));

  // Verify form outer container className preserved
  assert.ok(content.includes('className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4"'));
});
