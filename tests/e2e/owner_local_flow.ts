// Runs only against the disposable enrollment harness's Hub and real Bridge.
import { prepareOwnerOperation, sendOwnerOperation, openOwnerReply, ownerRelayFile, ownerId } from '../../src/ui/api/ownerLocalClient.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';

export async function ownerLocalFlow({ hub, approver, bridgeId, http, expect, stopOwner, restartOwner, inspectHub, otherAccount, cli }: any) {
  const session = { identity: approver.identity, chain: await approver.chain(), keyring: await importKeyring(Uint8Array.from(approver.keyringBytes), approver.userId) };
  const chainId = ownerId('chain_'), taskId = ownerId('task_');
  const send = async (body: unknown) => {
    const r = await http(hub, 'POST', '/api/v1/owner-local/relay', { body });
    if (r.status !== 200) throw new Error(r.raw);
    return r.data;
  };
  const invoke = (op: any) => sendOwnerOperation(session, op, send);
  const make = (method: any, input: any) => prepareOwnerOperation(session, bridgeId, method, { chainId, ...input });
  const create = await make('chain.create', { expectedRevision: '0', title: 'owner-private-chain', description: 'owner-private-description' });
  expect(JSON.parse((await invoke(create)).body).revision === '1', 'real Hub relay commits owner-local genesis');
  const task = await make('task.create', { taskId, expectedRevision: '1', title: 'owner-private-task', body: 'owner-private-task-body' });
  await invoke(task);
  expect((await invoke(task)).replay, 'task retry returns historical receipt');
  const comment = await make('task.comment', { taskId, expectedRevision: '1', body: 'owner-private-comment' });
  await invoke(comment);
  expect((await invoke(comment)).replay, 'comment retry returns historical receipt');
  const read = () => make('task.read', { taskId, expectedRevision: '0' });
  const detail = JSON.parse((await invoke(await read())).body);
  expect(detail.body === 'owner-private-task-body' && detail.items.length === 1 && detail.items[0].body === 'owner-private-comment', 'owner detail and exactly one comment read through real relay');
  const rows = await http(hub, 'GET', '/api/v1/owner-local/chains');
  expect(rows.status === 200 && rows.data.length === 2 && rows.data.every((r: any) => r.online), 'Hub exposes protected chain/task listing only');
  await inspectHub(chainId);
  const bad = { ...task, command: task.command.replace(/"signature":"[0-9a-f]"/, '"signature":"0"') };
  // Same valid schema, changed signed payload: never a mutation.
  const command = JSON.parse(task.command); command.signature = '0'.repeat(128); bad.command = JSON.stringify(command);
  let denied = false; try { await invoke(bad); } catch { denied = true; }
  expect(denied, 'forged device signature denied');
  const other = await createDeviceIdentity(memoryDeviceStore(), approver.userId);
  const forged = { ...session, identity: other };
  denied = false;
  try { await prepareOwnerOperation(forged, bridgeId, 'task.read', { chainId, taskId, expectedRevision: '0' }); } catch { denied = true; }
  expect(denied, 'unenrolled device cannot prepare commands');
  const otherHub = await otherAccount();
  const hidden = await http(otherHub, 'GET', '/api/v1/owner-local/chains');
  expect(hidden.status === 200 && hidden.data.length === 0, 'another account cannot discover metadata');
  const wrongAccount = await http(otherHub, 'POST', '/api/v1/owner-local/relay', { body: await ownerRelayFile(session, await read()) });
  expect(wrongAccount.status !== 200, 'another account cannot relay to this owner');
  await stopOwner();
  const offlineRows = await http(hub, 'GET', '/api/v1/owner-local/chains');
  expect(offlineRows.data.length === 2 && offlineRows.data.every((r: any) => !r.online), 'offline owner retains metadata-only listing');
  const offline = await send(await ownerRelayFile(session, await read()));
  expect(offline.code === 'owner_unavailable' && !offline.envelope, 'offline details explicitly unavailable');
  await restartOwner();
  const persisted = JSON.parse((await invoke(await read())).body);
  expect(persisted.body === detail.body && persisted.items.length === 1, 'isolated owner process restart preserves SQLite task and comment');
  expect((await invoke(comment)).replay, 'pre-restart comment replay does not append a duplicate');
  const cliOp = await read();
  const relay = await ownerRelayFile(session, cliOp);
  const cliResult = await openOwnerReply(session, cliOp, await cli(relay));
  expect(JSON.parse(cliResult.body).items.length === 1, 'real CLI signed file traverses real local Bridge and Hub relay');

  const cliChain = ownerId('chain_'), cliTask = ownerId('task_');
  const throughCli = async (method: any, input: any) => {
    const operation = await prepareOwnerOperation(session, bridgeId, method, { chainId: cliChain, ...input });
    return openOwnerReply(session, operation, await cli(await ownerRelayFile(session, operation)));
  };
  await throughCli('chain.create', { expectedRevision: '0', title: 'CLI chain', description: 'CLI description' });
  await throughCli('task.create', { taskId: cliTask, expectedRevision: '1', title: 'CLI task', body: 'CLI body' });
  await throughCli('task.comment', { taskId: cliTask, expectedRevision: '1', body: 'CLI comment' });
  const cliDetail = JSON.parse((await throughCli('task.read', { taskId: cliTask, expectedRevision: '0' })).body);
  expect(cliDetail.body === 'CLI body' && cliDetail.items.length === 1 && cliDetail.items[0].body === 'CLI comment', 'CLI chain create -> task create -> comment -> detail read all commit through real relay');
  const unsigned = { ...relay, envelope: 'not-ciphertext' };
  let rejected = false; try { const reply = await cli(unsigned); rejected = reply?.code !== 'ok'; } catch { rejected = true; }
  expect(rejected, 'CLI rejects unsigned/invalid request file');
  return { chainId, taskId };
}
