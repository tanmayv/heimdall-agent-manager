import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { verbsForState } from '../src/ui/components/actions/actionModel.ts';
test('Actions has no manual-run endpoint, verb or control', () => {
  const dir = new URL('../src/ui/components/actions/', import.meta.url);
  for (const name of fs.readdirSync(dir).filter(n => /\.tsx?$/.test(n))) {
    const source = fs.readFileSync(new URL(name, dir), 'utf8');
    assert.doesNotMatch(source, /runAction|useRunAction|label=["']Run\b|>\s*Run(?: now)?\s*</, name);
    assert.doesNotMatch(source, /user_stopped|needs_recovery|target_busy/, name);
  }
  assert.deepEqual(verbsForState('enabled'), ['edit', 'delete']);
  assert.deepEqual(verbsForState('disabled'), ['edit', 'delete']);
});
