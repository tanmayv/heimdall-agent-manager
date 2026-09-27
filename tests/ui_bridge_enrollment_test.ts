// REQ-BRG-1: Unit Tests for Bridge Readiness Badge and Pending Enrollment Ghosting Prevention
//
// RUN: node --test tests/ui_bridge_enrollment_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  isPendingEnrollment,
  bridgeReady,
  statusLabel,
} from '../src/ui/components/settings/bridgeEnrollment.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// ---------------------------------------------------------------------------
// 1. isPendingEnrollment: Status & Consumed Flag Variants
// ---------------------------------------------------------------------------

test('isPendingEnrollment returns false for null or undefined enrollment', () => {
  assert.equal(isPendingEnrollment(null), false);
  assert.equal(isPendingEnrollment(undefined), false);
});

test('isPendingEnrollment returns false for consumed status variants', () => {
  assert.equal(isPendingEnrollment({ status: 'consumed' }), false);
  assert.equal(isPendingEnrollment({ status: 'CONSUMED' }), false);
  assert.equal(isPendingEnrollment({ state: 'consumed' }), false);
});

test('isPendingEnrollment returns false for revoked and expired status variants', () => {
  assert.equal(isPendingEnrollment({ status: 'revoked' }), false);
  assert.equal(isPendingEnrollment({ status: 'REVOKED' }), false);
  assert.equal(isPendingEnrollment({ status: 'expired' }), false);
  assert.equal(isPendingEnrollment({ status: 'EXPIRED' }), false);
  assert.equal(isPendingEnrollment({ state: 'revoked' }), false);
});

test('isPendingEnrollment returns false when consumed_at is present, even with pending/created/active status', () => {
  assert.equal(isPendingEnrollment({ status: 'pending', consumed_at: '2026-09-27T12:00:00Z' }), false);
  assert.equal(isPendingEnrollment({ status: 'created', consumed_at: '2026-09-27T12:00:00Z' }), false);
  assert.equal(isPendingEnrollment({ status: 'active', consumed_at: '2026-09-27T12:00:00Z' }), false);
  assert.equal(isPendingEnrollment({ consumed_at: '2026-09-27T12:00:00Z' }), false);
});

test('isPendingEnrollment returns false when revoked_at is present, even with pending/created/active status', () => {
  assert.equal(isPendingEnrollment({ status: 'pending', revoked_at: '2026-09-27T12:00:00Z' }), false);
  assert.equal(isPendingEnrollment({ status: 'created', revoked_at: '2026-09-27T12:00:00Z' }), false);
  assert.equal(isPendingEnrollment({ status: 'active', revoked_at: '2026-09-27T12:00:00Z' }), false);
  assert.equal(isPendingEnrollment({ revoked_at: '2026-09-27T12:00:00Z' }), false);
});

test('isPendingEnrollment returns false when consumed_by_bridge_id matches an enrolled bridge', () => {
  const enrolledBridges = new Set(['brg_123', 'brg_456']);

  assert.equal(
    isPendingEnrollment({ status: 'pending', consumed_by_bridge_id: 'brg_123' }, enrolledBridges),
    false,
  );
  assert.equal(
    isPendingEnrollment({ status: 'active', consumed_by_bridge_id: 'brg_456' }, enrolledBridges),
    false,
  );
  assert.equal(
    isPendingEnrollment({ consumed_by_bridge_id: 'brg_123' }, enrolledBridges),
    false,
  );
});

test('isPendingEnrollment returns false for any enrollment that has consumed_by_bridge_id without set provided', () => {
  assert.equal(isPendingEnrollment({ status: 'pending', consumed_by_bridge_id: 'brg_999' }), false);
  assert.equal(isPendingEnrollment({ consumed_by_bridge_id: 'brg_999' }), false);
});

test('isPendingEnrollment returns true for active unconsumed pending enrollments', () => {
  assert.equal(isPendingEnrollment({ status: 'pending' }), true);
  assert.equal(isPendingEnrollment({ status: 'PENDING' }), true);
  assert.equal(isPendingEnrollment({ status: 'created' }), true);
  assert.equal(isPendingEnrollment({ status: 'CREATED' }), true);
  assert.equal(isPendingEnrollment({ status: 'active' }), true);
  assert.equal(isPendingEnrollment({ status: 'ACTIVE' }), true);
  assert.equal(isPendingEnrollment({ state: 'pending' }), true);
  assert.equal(isPendingEnrollment({}), true);
});

// ---------------------------------------------------------------------------
// 2. bridgeReady and statusLabel predicates
// ---------------------------------------------------------------------------

test('statusLabel correctly extracts bridge status or defaults to offline', () => {
  assert.equal(statusLabel({ status: 'online' }), 'online');
  assert.equal(statusLabel({ runtime_status: 'online' }), 'online');
  assert.equal(statusLabel({ status: 'REVOKED' }), 'revoked');
  assert.equal(statusLabel({}), 'offline');
  assert.equal(statusLabel(null), 'offline');
});

test('bridgeReady returns true for online or connected bridges regardless of capabilities', () => {
  assert.equal(bridgeReady({ status: 'online' }), true);
  assert.equal(bridgeReady({ status: 'connected' }), true);
  assert.equal(bridgeReady({ runtime_status: 'online' }), true);

  // Online bridge with 0 capabilities reports ready
  assert.equal(bridgeReady({ status: 'online', capabilities: [] }), true);
  assert.equal(bridgeReady({ status: 'online', provider_profiles: [] }), true);
});

test('bridgeReady returns false for offline or revoked bridges', () => {
  assert.equal(bridgeReady({ status: 'offline' }), false);
  assert.equal(bridgeReady({ status: 'revoked' }), false);
  assert.equal(bridgeReady({ status: 'disconnected' }), false);
  assert.equal(bridgeReady({}), false);
});

// ---------------------------------------------------------------------------
// 3. BridgesPanel.tsx Source Invariants (REQ-BRG-1)
// ---------------------------------------------------------------------------

test('BridgesPanel.tsx implements REQ-BRG-1 requirements', () => {
  const panelFile = path.join(REPO_ROOT, 'src/ui/components/settings/BridgesPanel.tsx');
  assert.ok(fs.existsSync(panelFile), 'BridgesPanel.tsx must exist');

  const content = fs.readFileSync(panelFile, 'utf8');

  // Acceptance Criterion 1 & 2: isPendingEnrollment checks terminal and consumed states first
  assert.match(content, /isPendingEnrollment/, 'isPendingEnrollment must be defined');
  assert.match(content, /enrolledBridgeIds/, 'enrolledBridgeIds must be computed for bridges');

  // Acceptance Criterion 3: Enrolled, online bridge with 0 capabilities shows ready and no providers configured tag
  assert.match(content, /settings-bridge-ready-\$\{id\}/, 'Bridge ready badge must retain debug id');
  assert.match(content, /settings-bridge-no-providers-\$\{id\}/, 'Informational no providers tag must have debug id');
  assert.match(content, /no providers configured/, 'Tag must state "no providers configured"');
  assert.match(content, /#settings\/providers\?bridge=/, 'Tag must link to #settings/providers?bridge=${id}');

  // Green tone for ready state
  assert.match(content, /border-success\/30 bg-success-soft text-success/, 'Ready badge must use success tone');
});
