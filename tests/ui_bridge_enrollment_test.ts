// REQ-BRG-1: Unit Tests for Bridge Readiness Badge and Pending Enrollment Ghosting Prevention
//
// RUN: node --test tests/ui_bridge_enrollment_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  bridgeReady,
  statusLabel,
} from '../src/ui/components/settings/bridgeEnrollment.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

// ---------------------------------------------------------------------------
// 1. isPendingEnrollment — DELETED WITH THE FEATURE IT DESCRIBED (REQ-ENROLL-9)
// ---------------------------------------------------------------------------
//
// Eight tests here exercised `isPendingEnrollment`, which decided whether a
// "pending enrollment" row should still be shown in the Bridges panel: it screened
// out consumed/revoked/expired rows and ones whose consumed_by_bridge_id already
// matched an enrolled bridge.
//
// There are no enrollment rows any more. The one-time-token endpoints that created,
// listed and revoked them are deleted, so the panel has no such list, the helper has
// no production consumer, and the helper itself is gone. These tests are deleted
// rather than inverted because there is no inverse to assert — the subject does not
// exist. Section 2 and the source invariants in section 3 are unaffected and stay.

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

  // REQ-BRG-1's criteria 1 & 2 asserted that the panel defined `isPendingEnrollment`
  // and computed `enrolledBridgeIds` to filter the pending-enrollment list. That list
  // is gone with the enrollment rows it displayed (REQ-ENROLL-9), so both assertions
  // are deleted. Asserting their ABSENCE instead is the useful replacement: it stops
  // the deleted enrollment-minting UI being reintroduced by a revert.
  assert.doesNotMatch(content, /bridge-enrollments/, 'the panel must not call the deleted bridge-enrollment endpoints');
  assert.doesNotMatch(content, /enrollment_token/, 'the panel must not handle a one-time enrollment token');
  assert.match(content, /ham-bridge enroll --ui/, 'the panel must tell the operator the device-flow command');

  // Acceptance Criterion 3: Enrolled, online bridge with 0 capabilities shows ready and no providers configured tag
  assert.match(content, /settings-bridge-ready-\$\{id\}/, 'Bridge ready badge must retain debug id');
  assert.match(content, /settings-bridge-no-providers-\$\{id\}/, 'Informational no providers tag must have debug id');
  assert.match(content, /no providers configured/, 'Tag must state "no providers configured"');
  assert.match(content, /#settings\/providers\?bridge=/, 'Tag must link to #settings/providers?bridge=${id}');

  // Green tone for ready state
  assert.match(content, /border-success\/30 bg-success-soft text-success/, 'Ready badge must use success tone');
});
