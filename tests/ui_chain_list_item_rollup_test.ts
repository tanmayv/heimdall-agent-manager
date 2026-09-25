// REQ-CHAIN-BACKEND-PROGRESS-1: Unit Tests for ChainListItem progress rollup and user validation fields
//
// RUN: node --test tests/ui_chain_list_item_rollup_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

test('tasks.ts defines ChainListItem with progress rollup and user validation fields', () => {
  const tasksEndpointFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts');
  assert.ok(fs.existsSync(tasksEndpointFile), 'tasks.ts endpoint must exist');

  const content = fs.readFileSync(tasksEndpointFile, 'utf8');

  // Verify ChainListItem type fields
  assert.match(content, /completedTaskCount:\s*number;/, 'ChainListItem must have completedTaskCount: number');
  assert.match(content, /userValidationCount:\s*number;/, 'ChainListItem must have userValidationCount: number');
  assert.match(content, /hasUserValidation:\s*boolean;/, 'ChainListItem must have hasUserValidation: boolean');

  // Verify normalizeChainListItem parses fields
  assert.match(content, /completedTaskCount:\s*Number\(/, 'normalizeChainListItem must parse completedTaskCount');
  assert.match(content, /userValidationCount/, 'normalizeChainListItem must parse userValidationCount');
  assert.match(content, /hasUserValidation:\s*Boolean\(/, 'normalizeChainListItem must compute hasUserValidation');
});
