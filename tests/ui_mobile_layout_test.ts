import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const APP_SHELL_FILE = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');

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
