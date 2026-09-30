// REQ-MODELS-UI-1, REQ-MODELS-UI-2, REQ-MODELS-UI-3, REQ-MODELS-UI-4:
// Unit tests for route-aware Provider Editor rendering in Settings Models & Providers.
//
// RUN: node --test tests/ui_providers_routing_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  resolveProviderPanelView,
  parseProviderUrlParams,
  shellHash,
} from '../src/ui/components/settings/providerManagement.ts';
import {
  getRoutePathname,
  getRouteSearch,
} from '../src/ui/utils/appLocation.ts';
import {
  resolveSettingsTab,
  normalizeSettingsTab,
} from '../src/ui/utils/settingsRouting.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const PROVIDERS_PANEL_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/settings/ProvidersPanel.tsx',
);

function setMockWindowHash(hash: string): void {
  (globalThis as any).window = {
    location: {
      hash,
      pathname: '/',
      search: '',
    },
  };
}

// -----------------------------------------------------------------------------
// 1. Route Detection for New Provider, Edit Provider, and Base List (REQ-MODELS-UI-1)
// -----------------------------------------------------------------------------

test('resolveProviderPanelView detects /settings/providers/new and /settings/models/new for ProviderEditorPage', () => {
  assert.deepEqual(resolveProviderPanelView('/settings/providers/new'), {
    mode: 'new',
    providerName: '',
  });
  assert.deepEqual(resolveProviderPanelView('/settings/models/new'), {
    mode: 'new',
    providerName: '',
  });
});

test('resolveProviderPanelView detects /settings/providers/:name/edit and /settings/models/:name/edit with decoded providerName', () => {
  assert.deepEqual(resolveProviderPanelView('/settings/providers/claude/edit'), {
    mode: 'edit',
    providerName: 'claude',
  });
  assert.deepEqual(resolveProviderPanelView('/settings/models/jetski/edit'), {
    mode: 'edit',
    providerName: 'jetski',
  });

  // URL-encoded provider names
  assert.deepEqual(
    resolveProviderPanelView('/settings/providers/my%20custom%2Bprovider/edit'),
    {
      mode: 'edit',
      providerName: 'my custom+provider',
    },
  );
  assert.deepEqual(
    resolveProviderPanelView('/settings/models/claude%2Fsonnet/edit'),
    {
      mode: 'edit',
      providerName: 'claude/sonnet',
    },
  );
});

test('resolveProviderPanelView returns list mode for /settings/providers and /settings/models', () => {
  assert.deepEqual(resolveProviderPanelView('/settings/providers'), {
    mode: 'list',
    providerName: '',
  });
  assert.deepEqual(resolveProviderPanelView('/settings/models'), {
    mode: 'list',
    providerName: '',
  });
  assert.deepEqual(resolveProviderPanelView('/home'), {
    mode: 'list',
    providerName: '',
  });
});

// -----------------------------------------------------------------------------
// 2. End-to-End Hash Navigation: Add, Edit, Duplicate, and Cancel/Save (REQ-MODELS-UI-1, REQ-MODELS-UI-2)
// -----------------------------------------------------------------------------

test('Clicking Add provider, Edit, Duplicate, and Cancel/Save transitions routes while keeping Settings modal open', () => {
  // 1. Start on the base providers list in Settings
  setMockWindowHash(shellHash('/settings/providers'));
  assert.equal(getRoutePathname(), '/settings/providers');
  assert.deepEqual(resolveProviderPanelView(getRoutePathname()), {
    mode: 'list',
    providerName: '',
  });
  assert.equal(normalizeSettingsTab(resolveSettingsTab(getRoutePathname())), 'models');

  // 2. Click "+ Add provider" -> #/settings/providers/new?bridge=brg_123
  const addHref = shellHash(`/settings/providers/new?bridge=${encodeURIComponent('brg_123')}`);
  setMockWindowHash(addHref);
  assert.equal(getRoutePathname(), '/settings/providers/new');
  assert.deepEqual(resolveProviderPanelView(getRoutePathname()), {
    mode: 'new',
    providerName: '',
  });
  assert.deepEqual(parseProviderUrlParams(getRouteSearch()), {
    bridge: 'brg_123',
    duplicateFrom: '',
  });
  // Settings modal remains on the Models tab
  assert.equal(normalizeSettingsTab(resolveSettingsTab(getRoutePathname())), 'models');

  // 3. Click "Edit" on a provider row -> #/settings/providers/claude/edit?bridge=brg_123
  const editHref = shellHash(
    `/settings/providers/${encodeURIComponent('claude')}/edit?bridge=${encodeURIComponent('brg_123')}`,
  );
  setMockWindowHash(editHref);
  assert.equal(getRoutePathname(), '/settings/providers/claude/edit');
  assert.deepEqual(resolveProviderPanelView(getRoutePathname()), {
    mode: 'edit',
    providerName: 'claude',
  });
  assert.deepEqual(parseProviderUrlParams(getRouteSearch()), {
    bridge: 'brg_123',
    duplicateFrom: '',
  });
  assert.equal(normalizeSettingsTab(resolveSettingsTab(getRoutePathname())), 'models');

  // 4. Click "Duplicate" -> #/settings/providers/new?bridge=brg_123&duplicateFrom=claude
  const duplicateHref = shellHash(
    `/settings/providers/new?bridge=${encodeURIComponent('brg_123')}&duplicateFrom=${encodeURIComponent('claude')}`,
  );
  setMockWindowHash(duplicateHref);
  assert.equal(getRoutePathname(), '/settings/providers/new');
  assert.deepEqual(resolveProviderPanelView(getRoutePathname()), {
    mode: 'new',
    providerName: '',
  });
  assert.deepEqual(parseProviderUrlParams(getRouteSearch()), {
    bridge: 'brg_123',
    duplicateFrom: 'claude',
  });
  assert.equal(normalizeSettingsTab(resolveSettingsTab(getRoutePathname())), 'models');

  // 5. Click "Cancel" or complete "Save provider" -> #/settings/providers
  const cancelOrSaveHref = shellHash('/settings/providers');
  setMockWindowHash(cancelOrSaveHref);
  assert.equal(getRoutePathname(), '/settings/providers');
  assert.deepEqual(resolveProviderPanelView(getRoutePathname()), {
    mode: 'list',
    providerName: '',
  });
  // Settings modal stays open on the Models tab instead of closing
  assert.ok(getRoutePathname().startsWith('/settings'));
  assert.equal(normalizeSettingsTab(resolveSettingsTab(getRoutePathname())), 'models');
});

// -----------------------------------------------------------------------------
// 3. ProvidersPanel.tsx Component Routing, Debug IDs, and Static Markers (REQ-MODELS-UI-1..4)
// -----------------------------------------------------------------------------

test('ProvidersPanel.tsx implements route-aware ProviderEditorPage rendering and preserves all debug IDs', () => {
  assert.ok(fs.existsSync(PROVIDERS_PANEL_PATH), 'ProvidersPanel.tsx must exist');
  const content = fs.readFileSync(PROVIDERS_PANEL_PATH, 'utf-8');

  // 1. Tracks route with getRoutePathname() and listens to hashchange and popstate
  assert.match(
    content,
    /import\s*\{[^}]*getRoutePathname[^}]*\}\s*from\s*'\.\.\/\.\.\/utils\/appLocation'/,
    'ProvidersPanel.tsx must import getRoutePathname from ../../utils/appLocation',
  );
  assert.match(
    content,
    /useState\(\(\)\s*=>\s*getRoutePathname\(\)\)/,
    'ProvidersPanel must initialize route state from getRoutePathname()',
  );
  assert.match(
    content,
    /window\.addEventListener\('hashchange'/,
    'ProvidersPanel must listen to hashchange events',
  );
  assert.match(
    content,
    /window\.addEventListener\('popstate'/,
    'ProvidersPanel must listen to popstate events',
  );

  // 2. Detects new provider routes (/settings/providers/new and /settings/models/new) and renders <ProviderEditorPage />
  assert.ok(
    content.includes("route === '/settings/providers/new' || route === '/settings/models/new'"),
    'ProvidersPanel must detect /settings/providers/new and /settings/models/new',
  );
  assert.ok(
    content.includes('return <ProviderEditorPage />;'),
    'ProvidersPanel must render <ProviderEditorPage /> when in new mode',
  );

  // 3. Detects edit provider routes (/settings/providers/:name/edit and /settings/models/:name/edit) and renders <ProviderEditorPage providerName={providerName} />
  assert.ok(
    content.includes("(route.startsWith('/settings/providers/') && route.endsWith('/edit'))") &&
      content.includes("(route.startsWith('/settings/models/') && route.endsWith('/edit'))"),
    'ProvidersPanel must detect /settings/providers/:name/edit and /settings/models/:name/edit',
  );
  assert.ok(
    content.includes("decodeURIComponent(route.slice(prefix.length, -'/edit'.length))"),
    'ProvidersPanel must decode providerName between prefix and /edit using decodeURIComponent',
  );
  assert.ok(
    content.includes('return <ProviderEditorPage providerName={providerName} />;'),
    'ProvidersPanel must render <ProviderEditorPage providerName={providerName} /> when in edit mode',
  );

  // 4. Preserves all required debug IDs and navigation targets
  assert.ok(
    content.includes('data-debug-id="providers-add-btn"'),
    'Must preserve providers-add-btn debug ID',
  );
  assert.ok(
    content.includes('data-debug-id={`providers-edit-btn-${name}`}'),
    'Must preserve providers-edit-btn-${name} debug ID',
  );
  assert.ok(
    content.includes('data-debug-id={`providers-duplicate-btn-${name}`}'),
    'Must preserve providers-duplicate-btn-${name} debug ID',
  );
  assert.ok(
    content.includes('data-debug-id="providers-editor-header-cancel-btn"'),
    'Must preserve providers-editor-header-cancel-btn debug ID',
  );
  assert.ok(
    content.includes('data-debug-id="providers-editor-footer-cancel-btn"'),
    'Must preserve providers-editor-footer-cancel-btn debug ID',
  );
  assert.ok(
    content.includes('data-debug-id="providers-editor-save-btn"'),
    'Must preserve providers-editor-save-btn debug ID',
  );
  assert.ok(
    content.includes("window.location.hash = shellHash('/settings/providers')"),
    'Save provider must navigate back to #/settings/providers',
  );

  // 5. Preserves static markers checked by tests/test_bridge_bootstrap_skill_dir_static.py
  for (const marker of [
    'skillDir: string;',
    'skillDir: String(profile.skill_dir',
    'skill_dir: form.skillDir.trim()',
    'providers-editor-skill-dir-input',
  ]) {
    assert.ok(
      content.includes(marker),
      `ProvidersPanel.tsx must preserve static skill_dir marker: ${marker}`,
    );
  }
});
