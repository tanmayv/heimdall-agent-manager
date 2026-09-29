// XM-9 predicate truth table.
// The preview predicates, run as REAL CODE imported from shellModel.ts, over the full
// status x port matrix. Reading a predicate and believing it is how XM-8's render gap
// survived review; running it over every case is what caught it.
//
// REQ-SHELL-22 repointed this from ShellsPanel.tsx to shellModel.ts. ShellsPanel was
// never mounted — its copy of these predicates could not affect anything a user saw —
// so the table was asserting over dead code. These three are the ones that ship:
// `PreviewCard` in ShellDetail.tsx (:574-576) calls all three in a row to decide whether
// the preview card renders at all, whether it is enabled, and what reason it shows.
//
// The dead file also had a fourth predicate, `setPortTitle`, giving a session-dependent
// title for the set-port menu item. It has NO live counterpart — shellModel has only the
// static VERB_LABEL['set-port'] = 'Set server port…' — so its column is dropped rather
// than kept alive by inventing a predicate to satisfy a test. A session-dependent
// set-port title has never been user-visible, because the only component that rendered
// one was never mounted. If the live UI should have one, that is a product change and
// its own task.
import { canPreview, hasPreviewAffordance, previewUnavailableReason } from './panel.mjs';

const STATUSES = ['starting', 'running', 'exited', 'killed', 'failed'];
const PORTS = [0, 3000];

const row = (s) => [
  `${s.status.padEnd(9)} port=${String(s.server_port).padEnd(5)}`,
  `canPreview=${String(canPreview(s)).padEnd(5)}`,
  `affordance=${String(hasPreviewAffordance(s)).padEnd(5)}`,
].join(' | ');

console.log('status/port            | canPreview   | affordance');
console.log('-'.repeat(70));
for (const status of STATUSES) {
  for (const server_port of PORTS) {
    console.log(row({ status, server_port, session_id: 'sh_x', label: 'demo', cmd: 'bash' }));
  }
}

console.log('\nWhat each row means for what the user SEES:');
console.log('  affordance=false -> no preview card rendered at all');
console.log('  affordance=true & canPreview=false -> DISABLED preview, reason says why:');
for (const status of STATUSES) {
  for (const server_port of PORTS) {
    const s = { status, server_port, session_id: 'sh_x', label: 'demo', cmd: 'bash' };
    if (hasPreviewAffordance(s) && !canPreview(s)) {
      console.log(`     ${status.padEnd(9)} port=${String(server_port).padEnd(5)} -> "${previewUnavailableReason(s)}"`);
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
      hasPreviewAffordance(S('running', 0)), true);
check('XM-9: starting + no port gets one too',    hasPreviewAffordance(S('starting', 0)), true);
check('exited + no port gets NONE (permanently unreachable)',
      hasPreviewAffordance(S('exited', 0)), false);
check('killed + no port gets NONE',               hasPreviewAffordance(S('killed', 0)), false);
check('failed + no port gets NONE',               hasPreviewAffordance(S('failed', 0)), false);
check('XM-8 unregressed: exited WITH a port still gets a disabled control',
      hasPreviewAffordance(S('exited', 3000)), true);
// The live predicate returns '' when previewable — the reason is only rendered when the
// control is disabled, so an empty string is the correct answer, not a missing one.
check('previewable session offers NO unavailable-reason',
      previewUnavailableReason(S('running', 3000)), '');
check('portless reason points at the menu that fixes it',
      previewUnavailableReason(S('running', 0)).includes('Set one from the menu'), true);
// NOTE: the live previewUnavailableReason has two further branches this table does not
// assert — the terminal reason and the starting-with-a-port reason. They are printed in
// the matrix above but unasserted. REQ-SHELL-22 deliberately restricted itself to
// repointing the existing assertions, so that a green run proves the MOVE was clean
// rather than mixing it with new coverage. Adding them is a good follow-up.

console.log('\nAssertions:');
let bad = 0;
for (const [name, ok, got, want] of A) {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  (got ${JSON.stringify(got)}, want ${JSON.stringify(want)})`}`);
  if (!ok) bad++;
}
console.log(`\n${A.length - bad} passed, ${bad} failed`);
process.exit(bad === 0 ? 0 : 1);
