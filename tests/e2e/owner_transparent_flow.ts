// R4a: ordinary ham-ctl verbs on an owner chain, against the disposable
// enrollment harness's real Hub, Bridge, CLI and synthetic PTY children.
// Run with HEIMDALL_E2E_OWNER_LOCAL=1 HEIMDALL_E2E_OWNER_LEASE=1
// HEIMDALL_E2E_OWNER_LIFECYCLE=1 HEIMDALL_E2E_OWNER_TRANSPARENT_ONLY=1.
// The agents never see lease JSON, capabilities or owner documents.
import { prepareOwnerOperation, sendOwnerOperation, ownerId } from '../../src/ui/api/ownerLocalClient.ts';
import { existsSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

export async function ownerTransparentFlow({ session, bridgeId, hub, http, expect, launchChild, prepareGit }: any) {
  const send = async (body: unknown) => {
    const r = await http(hub, 'POST', '/api/v1/owner-local/relay', { body });
    if (r.status !== 200) throw new Error(r.raw);
    return r.data;
  };
  const cid = ownerId('chain_'), tid = ownerId('task_');
  const git = prepareGit(tid, false, true);
  expect(!existsSync(git.worktree), 'no task worktree exists before configuration');
  const worker = await launchChild(git.repository), reviewer = await launchChild(), coordinator = await launchChild();
  const human = async (method: string, input: any) => sendOwnerOperation(session, await prepareOwnerOperation(session, bridgeId, method, { chainId: cid, taskId: tid, ...input }), send);
  const chainRevision = async () => JSON.parse((await human('chain.read', { taskId: '', expectedRevision: '0' })).body).revision;
  const fixtureGit = (cwd: string, ...args: string[]) => {
    const r = spawnSync('git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', '-C', cwd, ...args], { encoding: 'utf8', timeout: 15000 });
    if (r.ok === false) throw new Error('fixture git ' + args.join(' ') + ': ' + r.stderr);
    return r.stdout.trim();
  };
  try {
    await human('chain.create', { taskId: '', expectedRevision: '0', title: 'transparent-private-chain', description: 'transparent-private-description' });
    await human('task.create', { expectedRevision: '1', title: 'transparent-private-task', body: 'transparent-private-body' });
    await human('fleet.edit', { expectedRevision: '1', instanceId: worker.instanceId, configurationRevision: '1' });
    const config = { configuration_revision: '1', author_agent_id: worker.agentId, reviewer_agent_id: reviewer.agentId, reviewer_instance_id: reviewer.instanceId, directory_id: ownerId('dir_'), merge_policy: 'git', repository: git.repository, worktree: git.worktree, source_branch: git.sourceBranch, target_branch: git.targetBranch, base_head: git.baseHead };
    await human('lifecycle.configure', { expectedRevision: '2', lifecycleConfig: config });
    expect(existsSync(git.worktree), 'signed configuration creates repo/.heimdall/worktrees/<task> for the author repository');
    await human('requirements.edit', { expectedRevision: '3', requirementsRevision: '1', body: JSON.stringify({ goal: 'transparent-private-goal', acceptance: ['transparent-private-acceptance'] }) });
    await human('chain.member.set', { taskId: '', expectedRevision: await chainRevision(), instanceId: coordinator.instanceId, agentId: coordinator.agentId, memberRole: 'coordinator' });

    // Hub: the native owner chain names its authority instead of a 404.
    const detail = await http(hub, 'GET', '/api/v1/task-chains/' + cid);
    const detailError = JSON.parse(detail.raw).error;
    expect(detail.status === 409 && detailError?.code === 'owner_authority' && detailError?.details?.bridge_id === bridgeId, 'Hub answers typed owner_authority naming the owner Bridge');

    // Unrelated agents get nothing; the worker's lease next claims.
    const strangerNext = reviewer.ctl(['lease', 'next']);
    expect(strangerNext.ok && strangerNext.data?.status === 'none', 'an agent with no bound task gets status none');
    const next = worker.ctl(['lease', 'next']);
    expect(next.ok && next.data?.status === 'granted', 'ham-ctl lease next claims the owner task: ' + JSON.stringify(next.reply) + next.error);
    const lease = next.data.lease;
    expect(lease.task_id === tid && lease.chain_id === cid && lease.placement.workdir === git.worktree && lease.placement.branch === git.sourceBranch, 'lease next returns the task, Workdir and branch');
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
      state = JSON.parse((await human('runtime.read', { expectedRevision: '0' })).body);
      if (state.state[0][0] === 'done') break;
      if (Date.now() > deadline) throw new Error('merge gate did not settle: ' + JSON.stringify(state));
    }
    expect(git.targetHead() === head && state.state[0][2] === head, 'bridge_owner_merge moves the target to the reviewed head');
  } finally { await worker.stop(); await reviewer.stop(); await coordinator.stop(); }
}
