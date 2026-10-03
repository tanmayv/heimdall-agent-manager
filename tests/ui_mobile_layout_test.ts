import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  keyboardInsetFrom,
  KEYBOARD_INSET_MIN,
  MOBILE_MAX,
  type KeyboardInsetReading,
} from '../src/ui/components/ui/hooks/useViewport.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const INDEX_HTML_FILE = path.join(REPO_ROOT, 'index.html');
const APP_SHELL_FILE = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');
const THREAD_PAGE_FILE = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');

test('REQ-MOBILE-KEYBOARD-COMPOSER-26: index.html viewport meta tag contains interactive-widget=resizes-content', () => {
  const content = fs.readFileSync(INDEX_HTML_FILE, 'utf8');
  assert.ok(
    content.includes('interactive-widget=resizes-content'),
    'index.html viewport meta tag must include interactive-widget=resizes-content'
  );
  assert.match(
    content,
    /<meta\s+name=["']viewport["']\s+content=["'][^"']*interactive-widget=resizes-content[^"']*["']\s*\/?>/,
    'index.html must define valid viewport meta tag with interactive-widget=resizes-content'
  );
});

test('REQ-MOBILE-SIDEBAR-WIDTH-25: AppShell uses 25% reduced mobile collapsed sidebar width (w-12) and adjusted padding', () => {
  const content = fs.readFileSync(APP_SHELL_FILE, 'utf8');

  // Spacer div on mobile uses w-12 (48px, 25% reduction from w-16)
  assert.ok(
    content.includes('isMobile ? <div className="w-12 shrink-0 md:hidden pointer-events-none" aria-hidden="true" /> : null'),
    'AppShell must use w-12 spacer div on mobile to match the 48px collapsed sidebar'
  );
  assert.ok(
    !content.includes('isMobile ? <div className="w-16 shrink-0 md:hidden pointer-events-none"'),
    'AppShell must not use w-16 spacer div on mobile'
  );

  // Aside collapsed width uses w-12 on mobile and w-16 on desktop/tablet
  assert.ok(
    content.includes("isEffectiveCollapsed ? (isMobile ? 'w-12' : 'w-16') : 'w-80 max-w-[calc(100vw-1rem)]'"),
    'AppShell aside width must collapse to w-12 on mobile and w-16 on desktop'
  );

  // Top header, nav scroll container, and footer areas reduce padding to p-1.5 when mobile and collapsed
  assert.ok(
    content.includes("isMobile && isEffectiveCollapsed ? 'p-1.5' : 'p-3'"),
    'AppShell must reduce padding from p-3 to p-1.5 when collapsed on mobile'
  );

  // Search button adjusts padding to px-1.5 on mobile collapsed
  assert.ok(
    content.includes("isMobile && isEffectiveCollapsed ? 'px-1.5' : 'px-3'"),
    'AppShell search button must adjust horizontal padding to px-1.5 on mobile collapsed'
  );

  // Collapse toggle button adjusts dimensions on mobile collapsed to avoid clipping
  assert.ok(
    content.includes("isMobile && isEffectiveCollapsed") &&
      content.includes("'h-9 w-9 min-h-9 min-w-9'") &&
      content.includes("'h-10 w-10 min-h-11 min-w-11'"),
    'AppShell sidebar collapse toggle button must size cleanly for w-12 without clipping'
  );

  // NavItem centers icons when collapsed
  assert.ok(
    content.includes("collapsed ? 'justify-center' : ''"),
    'NavItem must center icons when collapsed to prevent overflow'
  );
});

test('REQ-MOBILE-KEYBOARD-COMPOSER-26: ConversationThreadPage wires keyboardInset and scrolls textarea on focus', () => {
  const content = fs.readFileSync(THREAD_PAGE_FILE, 'utf8');

  // useKeyboardInset hook import
  assert.ok(
    content.includes("import { useKeyboardInset } from '../ui/hooks/useViewport';"),
    'ConversationThreadPage must import useKeyboardInset from ../ui/hooks/useViewport'
  );

  // Hook invocation
  assert.ok(
    content.includes('const keyboardInset = useKeyboardInset();'),
    'ConversationThreadPage must invoke useKeyboardInset hook'
  );

  // ChatMessageList footer container applies dynamic paddingBottom when keyboard is active
  assert.ok(
    content.includes('style={keyboardInset > 0 ? { paddingBottom: `${keyboardInset + 8}px` } : undefined}'),
    'ChatMessageList footer container must apply paddingBottom: keyboardInset + 8px when keyboardInset > 0'
  );

  // Composer textarea scrolls into view on focus
  assert.ok(
    content.includes("onFocus={() => {") &&
      content.includes("requestAnimationFrame(() => textareaRef.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }));"),
    'Composer textarea must call requestAnimationFrame scrollIntoView onFocus'
  );
});

test('REQ-MOBILE-KEYBOARD-COMPOSER-26: keyboardInset calculation drives composer bottom padding', () => {
  const sampleMobileReading: KeyboardInsetReading = {
    innerWidth: 390,
    innerHeight: 844,
    visualHeight: 544,
    visualOffsetTop: 0,
  };
  const inset = keyboardInsetFrom(sampleMobileReading);
  assert.equal(inset, 300, 'keyboardInsetFrom should calculate 300px keyboard gap');

  // Verify the resulting padding formula
  const paddingBottomStyle = inset > 0 ? `${inset + 8}px` : undefined;
  assert.equal(paddingBottomStyle, '308px', 'Padding bottom style should be keyboardInset + 8px (308px)');

  // When no keyboard is open
  const noKeyboardReading: KeyboardInsetReading = {
    innerWidth: 390,
    innerHeight: 844,
    visualHeight: 844,
    visualOffsetTop: 0,
  };
  const zeroInset = keyboardInsetFrom(noKeyboardReading);
  assert.equal(zeroInset, 0);
  const inactivePadding = zeroInset > 0 ? `${zeroInset + 8}px` : undefined;
  assert.equal(inactivePadding, undefined);
});
