// REQ-TEL-1: Unit Tests for UI BridgesPanel Telemetry preferences and toggles
//
// RUN: node --test tests/ui_bridges_panel_telemetry_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const BRIDGES_PANEL_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/settings/BridgesPanel.tsx',
);
const BRIDGE_SUPPORT_API_PATH = path.join(
  REPO_ROOT,
  'src/ui/api/endpoints/bridgeSupport.ts',
);
const SETTINGS_API_PATH = path.join(
  REPO_ROOT,
  'src/ui/api/endpoints/settings.ts',
);

test('BridgesPanel.tsx source invariants for REQ-TEL-1', () => {
  assert.ok(fs.existsSync(BRIDGES_PANEL_PATH), 'BridgesPanel.tsx must exist');
  const content = fs.readFileSync(BRIDGES_PANEL_PATH, 'utf8');

  // Global toggle
  assert.match(
    content,
    /data-debug-id="settings-bridges-global-telemetry"/,
    'Global telemetry container must exist',
  );
  assert.match(
    content,
    /data-debug-id="settings-global-telemetry-toggle"/,
    'Global telemetry toggle must exist',
  );

  // Per-bridge toggle
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-telemetry-toggle-\$\{id\}`\}/,
    'Per-bridge telemetry toggle container must exist',
  );
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-telemetry-inherit-\$\{id\}`\}/,
    'Per-bridge inherit button must exist',
  );
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-telemetry-enabled-\$\{id\}`\}/,
    'Per-bridge enabled button must exist',
  );
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-telemetry-disabled-\$\{id\}`\}/,
    'Per-bridge disabled button must exist',
  );

  assert.ok(
    content.includes('Inherit Global'),
    'Should include "Inherit Global" label',
  );
  assert.ok(
    content.includes('Enabled'),
    'Should include "Enabled" label',
  );
  assert.ok(
    content.includes('Disabled'),
    'Should include "Disabled" label',
  );
});

test('bridgeSupport.ts invariants for REQ-TEL-1', () => {
  assert.ok(fs.existsSync(BRIDGE_SUPPORT_API_PATH), 'bridgeSupport.ts must exist');
  const content = fs.readFileSync(BRIDGE_SUPPORT_API_PATH, 'utf8');

  assert.match(
    content,
    /telemetry_enabled\?:/,
    'Bridge interface must have telemetry_enabled field',
  );
  assert.match(
    content,
    /updateBridgeTelemetry:/,
    'updateBridgeTelemetry mutation must exist',
  );
  assert.match(
    content,
    /useUpdateBridgeTelemetryMutation/,
    'useUpdateBridgeTelemetryMutation must be exported',
  );
});

test('settings.ts invariants for REQ-TEL-1', () => {
  assert.ok(fs.existsSync(SETTINGS_API_PATH), 'settings.ts must exist');
  const content = fs.readFileSync(SETTINGS_API_PATH, 'utf8');

  assert.match(
    content,
    /telemetry\.default_enabled/,
    'telemetry.default_enabled preference key must exist',
  );
  assert.match(
    content,
    /fetchTelemetryDefaultEnabled:/,
    'fetchTelemetryDefaultEnabled query must exist',
  );
  assert.match(
    content,
    /saveTelemetryDefaultEnabled:/,
    'saveTelemetryDefaultEnabled mutation must exist',
  );
  assert.match(
    content,
    /useFetchTelemetryDefaultEnabledQuery/,
    'useFetchTelemetryDefaultEnabledQuery must be exported',
  );
  assert.match(
    content,
    /useSaveTelemetryDefaultEnabledMutation/,
    'useSaveTelemetryDefaultEnabledMutation must be exported',
  );
});
