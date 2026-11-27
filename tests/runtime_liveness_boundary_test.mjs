import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('..', import.meta.url));

function* productionOdin(dir) {
  for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
    const name = join(dir, entry.name);
    if (entry.isDirectory()) yield* productionOdin(name);
    else if (entry.name.endsWith('.odin') && !entry.name.endsWith('_test.odin')) yield name;
  }
}

test('Bridge runtime transitions use the single logging and reason writer', () => {
  const violations = [];
  for (const file of productionOdin('src/bridge')) {
    let proc = '';
    readFileSync(join(root, file), 'utf8').split('\n').forEach((line, index) => {
      const code = line.trim();
      if (code.startsWith('//')) return;
      proc = code.match(/^(\w+)\s*::\s*proc\(/)?.[1] ?? proc;
      // The field write or a tuple assignment beginning with that field.
      if (!/\.runtime_status\s*(?:=[^=]|,\s*\w+.*=[^=])/.test(code)) return;
      if (basename(file) === 'hub_runtime_client.odin' &&
          proc === 'bridge_runtime_set_status_with_source_locked') return;
      violations.push(file + ':' + (index + 1));
    });
  }
  assert.deepEqual(violations, [], 'status writes outside the Bridge transition writer');
});

test('Production Hub paths do not infer exits from missing roster rows or elapsed time', () => {
  const violations = [];
  const retired = /\b(reconcile_bridge_heartbeat|runtime_reconcile_digest|reap_stale_instances)\s*\(/;
  for (const file of productionOdin('src/hub')) {
    readFileSync(join(root, file), 'utf8').split('\n').forEach((line, index) => {
      if (!line.trimStart().startsWith('//') && retired.test(line)) violations.push(file + ':' + (index + 1));
    });
  }
  assert.deepEqual(violations, [], 'legacy negative-evidence path reintroduced');
});
