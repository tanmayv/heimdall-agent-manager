// R4a: ordinary ham-ctl verbs on an owner chain, against the disposable
// enrollment harness's real Hub, Bridge, CLI and synthetic PTY children.
// Run with HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1
// HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_TRANSPARENT_ONLY=1.
// The agents never see lease JSON, capabilities or owner documents.
import { prepareOwnerOperation, sendOwnerOperation, ownerId } from '../../src/ui/api/ownerLocalClient.ts';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

export async function ownerTransparentFlow({ session, bridgeId, hub, http, expect, launchChild, prepareGit }: any) {
  const send = async (body: unknown) => {
    const r = await http(hub, 'POST', '/api/v1/owner-local/relay', { body });
    if (r.status !== 200) throw new Error(r.raw);
    return r.data;
  };
  const cid = ownerId('chain_');
  const git = prepareGit('unused', false, true);
  const worker = await launchChild(git.repository), reviewer = await launchChild(), coordinator = await launchChild(), outsider = await launchChild();
  const human = async (method: string, input: any) => sendOwnerOperation(session, await prepareOwnerOperation(session, bridgeId, method, { chainId: cid, taskId: '', ...input }), send);
  const chainRevision = async () => JSON.parse((await human('chain.read', { expectedRevision: '0' })).body).revision;
  const fixtureGit = (cwd: string, ...args: string[]) => {
    const r = spawnSync('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', '-C', cwd, ...args], { encoding: 'utf8', timeout: 15000 });
    if (r.status !== 0) throw new Error('fixture git ' + args.join(' ') + ': ' + r.stderr);
    return r.stdout.trim();
  };
  try {
    // The human sets up only the chain: its repository, target branch and
    // members. Granting membership stays human-only.
    await human('chain.create', { expectedRevision: '0', title: 'transparent-private-chain', description: 'transparent-private-description' });
    const directoryId = ownerId('dir_'), now = new Date().toISOString();
    await human('chain.directory.set', { expectedRevision: await chainRevision(), directoryId, body: JSON.stringify({ directory_id: directoryId, chain_id: cid, owner_user_id: session.identity.userId, path: git.repository, bridge_id: bridgeId, vcs_kind: 'git', vcs_info_json: '{}', created_at: now, updated_at: now }) });
    await human('chain.defaults.set', { expectedRevision: await chainRevision(), body: JSON.stringify({ target_branch: git.targetBranch }) });
    for (const [child, role] of [[worker, 'worker'], [reviewer, 'reviewer'], [coordinator, 'coordinator']] as const) {
      await human('chain.member.set', { expectedRevision: await chainRevision(), instanceId: child.instanceId, agentId: child.agentId, memberRole: role });
    }

    // The coordinator creates and assigns the work (no human task setup).
    const created = coordinator.ctl(['task', 'create', '--chain', cid, '--title', 'transparent-private-task', '--description', 'transparent-private-body', '--goal', 'transparent-private-goal', '--acceptance', 'transparent-private-acceptance', '--priority', 'p0', '--assignee', worker.agentId, '--reviewer', reviewer.agentId]);
    expect(created.ok && created.data?.task_id, 'coordinator task create with assignee, reviewer, brief and priority: ' + JSON.stringify(created.reply));
    const tid = created.data.task_id;
    const later = coordinator.ctl(['task', 'create', '--chain', cid, '--title', 'transparent-dependent-task', '--goal', 'follow-up', '--acceptance', 'done', '--priority', 'p0', '--depends-on', tid, '--assignee', worker.agentId, '--reviewer', reviewer.agentId]);
    expect(later.ok && later.data?.task_id, 'coordinator creates a dependent task: ' + JSON.stringify(later.reply));
    // H1: an assignment is validated before anything is written, so an invalid
    // one creates no task (it used to fail only after task.create/fleet.edit).
    const taskCount = () => coordinator.ctl(['task-chain', 'show', cid]).data?.tasks?.length;
    const countBefore = taskCount();
    const misplaced = coordinator.ctl(['task', 'create', '--chain', cid, '--title', 'misplaced-worker-task', '--goal', 'g', '--acceptance', 'a', '--assignee', reviewer.agentId, '--reviewer', coordinator.agentId]);
    expect(!misplaced.ok && JSON.stringify(misplaced.reply).includes('invalid_scope') && JSON.stringify(misplaced.reply).includes('chain repository') && JSON.stringify(misplaced.reply).includes('no task created'),
      'a worker launched outside the chain repository is refused before the task exists: ' + JSON.stringify(misplaced.reply));
    const reviewerOnly = coordinator.ctl(['task', 'create', '--chain', cid, '--title', 'reviewer-without-worker', '--reviewer', reviewer.agentId]);
    expect(!reviewerOnly.ok && JSON.stringify(reviewerOnly.reply).includes('worker_required'), 'a reviewer without a worker is refused before the task exists: ' + JSON.stringify(reviewerOnly.reply));
    const shownAfter = coordinator.ctl(['task-chain', 'show', cid]);
    expect(typeof countBefore === 'number' && taskCount() === countBefore && !JSON.stringify(shownAfter.data).includes('misplaced-worker-task') && !JSON.stringify(shownAfter.data).includes('reviewer-without-worker'),
      'an invalid assignment creates no task: ' + JSON.stringify(shownAfter.data?.tasks));
    const outsiderAssign = coordinator.ctl(['task', 'update', later.data.task_id, '--assignee', outsider.agentId]);
    expect(!outsiderAssign.ok && JSON.stringify(outsiderAssign.reply).includes('invalid_scope'), 'assigning an agent that is not a member of this chain is refused: ' + JSON.stringify(outsiderAssign.reply));
    // The coordinator may add and remove the user-approval gate; a removal
    // needs --reason (audited on the owner).
    const gated = coordinator.ctl(['task', 'update', later.data.task_id, '--require-user-approval']);
    expect(gated.ok, 'a coordinator may add --require-user-approval on an owner chain: ' + JSON.stringify(gated.reply));
    const unreasoned = coordinator.ctl(['task', 'update', later.data.task_id, '--no-require-user-approval']);
    expect(!unreasoned.ok && JSON.stringify(unreasoned.reply).includes('needs --reason'), 'removing the user-approval gate needs a reason: ' + JSON.stringify(unreasoned.reply));
    const ungated = coordinator.ctl(['task', 'update', later.data.task_id, '--no-require-user-approval', '--reason', 'the user waived their review']);
    expect(ungated.ok, 'a coordinator may remove the user-approval gate with a reason: ' + JSON.stringify(ungated.reply));
    const unsupported = coordinator.ctl(['task', 'update', tid, '--title', 'x', '--request-id', 'transparent-unsupported']);
    expect(!unsupported.ok && JSON.stringify(unsupported.reply).includes('unsupported_on_owner_chain'), 'an unsupported flag is a typed error, never a silent success');
    const workerCreate = worker.ctl(['task', 'create', '--chain', cid, '--title', 'not-allowed']);
    expect(!workerCreate.ok, 'a worker cannot create tasks');
    git.worktree = git.repository + '/.heimdall/worktrees/' + tid;
    git.sourceBranch = 'heimdall/' + tid;
    expect(!existsSync(git.worktree), 'no task worktree exists before the claim');

    // Hub: Hub chain routes are gone (410 hub_chains_removed); the owner
    // registry names the chain's owner Bridge.
    const detail = await http(hub, 'GET', '/api/v1/task-chains/' + cid);
    const detailError = JSON.parse(detail.raw).error;
    expect(detail.status === 410 && detailError?.code === 'hub_chains_removed', 'Hub chain detail answers 410 hub_chains_removed: ' + detail.raw);
    let routed = false;
    for (let i = 0; i < 20 && !routed; i++) {
      const rows = await http(hub, 'GET', '/api/v1/owner-local/chains?chain_id=' + encodeURIComponent(cid));
      routed = rows.status === 200 && (rows.data ?? []).some((r: any) => r.chain_id === cid && r.owner_bridge_id === bridgeId);
      if (!routed) await new Promise((r) => setTimeout(r, 500));
    }
    expect(routed, 'the owner registry names the owner Bridge');

    // Unrelated agents never receive the owner task; the worker's lease next
    // claims the unblocked task (the dependent one waits).
    const strangerNext = reviewer.ctl(['lease', 'next']);
    expect(strangerNext.ok && strangerNext.data?.status === 'none', 'a reviewer-only agent with no bound task gets status none (answered by the Hub): ' + JSON.stringify(strangerNext.reply) + strangerNext.error);
    const next = worker.ctl(['lease', 'next']);
    expect(next.ok && next.data?.status === 'granted', 'ham-ctl lease next claims the owner task: ' + JSON.stringify(next.reply) + next.error);
    const lease = next.data.lease;
    expect(lease.task_id === tid && lease.chain_id === cid && lease.placement.workdir === git.worktree && lease.placement.branch === git.sourceBranch && existsSync(git.worktree), 'lease next returns the task and creates its Workdir and branch after the claim');
    expect(next.data.authority?.kind === 'owner' && next.data.authority?.bridge_id === bridgeId, 'response marks owner authority');
    expect(fixtureGit(git.worktree, 'symbolic-ref', '--short', 'HEAD') === git.sourceBranch, 'Workdir is checked out on heimdall/<task>');
    const md = worker.readTaskMd();
    expect(md.includes(lease.lease_id) && md.includes('transparent-private-goal') && md.includes('Workdir: `' + git.worktree + '`') && md.includes('--acknowledge-requirements-revision 1'), 'TASK.md has the lease, requirements, Workdir and ACK command');
    const current = worker.ctl(['lease', 'next']);
    expect(current.ok && current.data?.status === 'current' && current.data.lease.lease_id === lease.lease_id, 'a second lease next returns the current lease');

    const early = worker.ctl(['lease', 'submit', '--summary', 'too-early']);
    expect(early.ok === false, 'submit before the ACK is refused');
    const ack = worker.ctl(['lease', 'heartbeat', '--lease', lease.lease_id, '--acknowledge-requirements-revision', '1']);
    expect(ack.ok && ack.data?.acknowledged_requirements_revision === '1', 'heartbeat ACKs the presented requirements revision: ' + JSON.stringify(ack.reply));

    writeFileSync(path.join(git.worktree, 'transparent.txt'), 'transparent work\n');
    const dirty = worker.ctl(['lease', 'submit', '--summary', 'uncommitted']);
    expect(dirty.ok === false && JSON.stringify(dirty.reply).includes('worktree_not_clean'), 'submit refuses an uncommitted Workdir');
    fixtureGit(git.worktree, 'add', '.');
    fixtureGit(git.worktree, 'commit', '-m', 'transparent work');
    const head = fixtureGit(git.worktree, 'rev-parse', 'HEAD');
    const submitted = worker.ctl(['lease', 'submit', '--summary', 'transparent-checks-pass']);
    expect(submitted.ok && submitted.data?.state === 'in_review' && submitted.data?.head === head, 'ham-ctl lease submit records the committed head: ' + JSON.stringify(submitted.reply));
    expect(submitted.data.vcs?.head === head && submitted.data.vcs?.dirty === false && submitted.data.vcs.files.some((f: any) => f.path === 'transparent.txt'), 'submit returns the vcs facet (head, dirty, files)');
    expect(worker.ctl(['lease', 'next']).data?.status === 'none', 'after submit the worker holds no lease');

    // Coordinator chain verbs; a non-coordinator is refused.
    const shown = coordinator.ctl(['task-chain', 'show', cid]);
    expect(shown.ok && shown.data?.authority?.kind === 'owner' && shown.data.tasks.some((t: any) => t.task_id === tid), 'coordinator task-chain show reads the owner chain');
    expect(coordinator.ctl(['task', 'comment', tid, '--body', 'transparent-coordinator-note']).ok, 'coordinator comments through the owner');
    expect(coordinator.ctl(['task-chain', 'summary', 'set', 'transparent-summary', '--chain', cid]).ok, 'coordinator sets the chain summary');
    const task = coordinator.ctl(['task', 'show', tid]);
    expect(task.ok && task.data?.task?.state === 'in_review' && task.data.comments.some((c: any) => c.body === 'transparent-coordinator-note'), 'task show returns state and comments');
    expect(reviewer.ctl(['task', 'comment', tid, '--body', 'not-allowed']).ok === false, 'a non-coordinator, non-holder agent is refused');
    expect(worker.ctl(['task-chain', 'summary', 'set', 'not-allowed', '--chain', cid]).ok === false, 'a worker cannot use coordinator verbs');

    // The author cannot review; the configured reviewer approves; merge runs.
    expect(worker.ctl(['review', 'post', '--task', tid, '--verdict', 'approve']).ok === false, 'the author cannot review its own work');
    const reviewed = reviewer.ctl(['review', 'post', '--task', tid, '--verdict', 'approve', '--summary', 'transparent-review']);
    expect(reviewed.ok && reviewed.data?.verdict === 'approve', 'ham-ctl review post records the independent verdict: ' + JSON.stringify(reviewed.reply));
    let state: any;
    for (const deadline = Date.now() + 15000; ; await new Promise(r => setTimeout(r, 200))) {
      state = JSON.parse((await human('runtime.read', { taskId: tid, expectedRevision: '0' })).body);
      if (state.state[0][0] === 'done') break;
      if (Date.now() > deadline) throw new Error('merge gate did not settle: ' + JSON.stringify(state));
    }
    expect(git.targetHead() === head && state.state[0][2] === head, 'bridge_owner_merge moves the target to the reviewed head');

    // H1: a deterministic worktree failure (a plain directory squatting on the
    // dependent task's worktree path) blocks the lease, waiting on human,
    // instead of leaving it held for endless lease next retries.
    const laterId = later.data.task_id;
    mkdirSync(git.repository + '/.heimdall/worktrees/' + laterId, { recursive: true });
    const squatted = worker.ctl(['lease', 'next']);
    expect(!squatted.ok && JSON.stringify(squatted.reply).includes('worktree_unavailable') && JSON.stringify(squatted.reply).includes('the lease was blocked'),
      'a squatted task worktree blocks the lease: ' + JSON.stringify(squatted.reply) + squatted.error);
    const blocked = JSON.parse((await human('runtime.read', { taskId: laterId, expectedRevision: '0' })).body);
    expect(blocked.leases.length === 0 && blocked.controls.length === 1 && blocked.controls[0][0] === 'blocked' && blocked.controls.flat().includes('human'),
      'the task is blocked waiting on human with no live lease: ' + JSON.stringify({ leases: blocked.leases, controls: blocked.controls }));
  } finally { await worker.stop(); await reviewer.stop(); await coordinator.stop(); await outsider.stop(); }
}
