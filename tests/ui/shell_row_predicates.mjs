// XM-9 predicate truth table.
// The four row-level predicates, run as REAL CODE imported from ShellsPanel, over the
// full status x port matrix. Reading a predicate and believing it is how XM-8's render
// gap survived review; running it over every case is what caught it.
import { canPreview, hasAccessAffordance, previewTitle, setPortTitle } from './panel.mjs';

const STATUSES = ['starting', 'running', 'exited', 'killed', 'failed'];
const PORTS = [0, 3000];

const row = (s) => [
  `${s.status.padEnd(9)} port=${String(s.server_port).padEnd(5)}`,
  `canPreview=${String(canPreview(s)).padEnd(5)}`,
  `affordance=${String(hasAccessAffordance(s)).padEnd(5)}`,
  `setPort=${setPortTitle(s).slice(0, 44).padEnd(44)}`,
].join(' | ');

console.log('status/port            | canPreview   | affordance   | set-port menu item title');
console.log('-'.repeat(120));
for (const status of STATUSES) {
  for (const server_port of PORTS) {
    console.log(row({ status, server_port, session_id: 'sh_x', label: 'demo', cmd: 'bash' }));
  }
}

console.log('\nWhat each row means for what the user SEES:');
console.log('  affordance=false -> no preview control rendered at all');
console.log('  affordance=true & canPreview=false -> DISABLED preview button, title says why:');
for (const status of STATUSES) {
  for (const server_port of PORTS) {
    const s = { status, server_port, session_id: 'sh_x', label: 'demo', cmd: 'bash' };
    if (hasAccessAffordance(s) && !canPreview(s)) {
      console.log(`     ${status.padEnd(9)} port=${String(server_port).padEnd(5)} -> "${previewTitle(s)}"`);
    }
  }
}

// The assertions XM-9 actually claims. A table nobody asserts against is a picture.
const A = [];
const check = (name, got, want) => A.push([name, got === want, got, want]);
const S = (status, server_port) => ({ status, server_port, session_id: 'x', label: 'd', cmd: 'b' });

check('running + port is previewable',            canPreview(S('running', 3000)), true);
check('running + no port is NOT previewable',     canPreview(S('running', 0)),    false);
check('XM-9: running + no port now GETS an affordance (transient, not permanent)',
      hasAccessAffordance(S('running', 0)), true);
check('XM-9: starting + no port gets one too',    hasAccessAffordance(S('starting', 0)), true);
check('exited + no port gets NONE (permanently unreachable)',
      hasAccessAffordance(S('exited', 0)), false);
check('killed + no port gets NONE',               hasAccessAffordance(S('killed', 0)), false);
check('failed + no port gets NONE',               hasAccessAffordance(S('failed', 0)), false);
check('XM-8 unregressed: exited WITH a port still gets a disabled button',
      hasAccessAffordance(S('exited', 3000)), true);
check('set-port offered on a running session',    setPortTitle(S('running', 0)).startsWith('Declare'), true);
check('set-port says CHANGE when one is set',     setPortTitle(S('running', 3000)).startsWith('Change'), true);
check('set-port refused-wording on an exited session',
      setPortTitle(S('exited', 0)).includes('cannot be declared'), true);
check('portless reason points at the row menu',
      previewTitle(S('running', 0)).includes('set one from the row menu'), true);

console.log('\nAssertions:');
let bad = 0;
for (const [name, ok, got, want] of A) {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  (got ${JSON.stringify(got)}, want ${JSON.stringify(want)})`}`);
  if (!ok) bad++;
}
console.log(`\n${A.length - bad} passed, ${bad} failed`);
process.exit(bad === 0 ? 0 : 1);
