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

test('Hub scheduling and start policy do not read the runtime projection directly', () => {
  const violations = [];
  const startFile = 'src/hub/service/agent/start_begin.odin';
  const files = [...productionOdin('src/hub/service/taskv2'), startFile];
  for (const file of files) {
    let proc = '';
    readFileSync(join(root, file), 'utf8').split('\n').forEach((line, index) => {
      const code = line.trim();
      if (code.startsWith('//')) return;
      proc = code.match(/^(\w+)\s*::\s*proc\(/)?.[1] ?? proc;
      if (!/\.runtime_status\b/.test(code)) return;
      // The writer initializes the projection after choosing a generation.
      if (file === startFile && proc === 'start_begin_impl' &&
          code === 'next.runtime_status = "launching"') return;
      // A stale UI label is harmless when it is only formatting an explanation.
      if (file.endsWith('/matcher.odin') && proc === 'instance_failure_reason' &&
          code.startsWith('reason := fmt.tprintf(')) return;
      if (file.endsWith('/dispatch.odin') && proc === 'agent_not_running_in_uow' &&
          (code.startsWith('detail = fmt.tprintf(') || code.startsWith('} else if inst.runtime_status =='))) return;
      violations.push(file + ':' + (index + 1));
    });
  }
  assert.deepEqual(violations, [], 'runtime projection used as scheduler or start evidence');
});
