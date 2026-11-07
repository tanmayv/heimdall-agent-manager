import React, {useEffect, useState} from 'react';
import {cookieJsonFetch, cookieMutation} from '../../api/cookieFetch';
import {executorParse} from '../../api/executor';
import {localLaunchRelay, openLocalLaunchReply, prepareLocalLaunchOperation, type LocalLaunchDraftRef, type LocalLaunchOperation} from '../../api/executorLocalLaunch';
import type {OwnerSession} from '../../api/ownerLocalClient';
import {ownerPayloadDigest} from '../../api/ownerLocal';
import {decryptVaultText, encryptVaultText} from '../../utils/vaultContent';
import {getKeyringSession, subscribeKeyringSession} from '../../utils/vaultKeyringSession';
import {pinsFromChain, verifyDirectory} from '../../utils/vaultDirectoryVerify';

export function pendingLaunchDraft(lastError: unknown): LocalLaunchDraftRef | null {
  try {
    const raw = typeof lastError === 'object' && lastError !== null && 'message' in lastError ? lastError.message : '';
    if (typeof raw !== 'string') return null;
    const value = JSON.parse(raw);
    if (value.code !== 'launch_authorization_required' || !/^[a-f0-9]{64}$/.test(value.draft_id) ||
        !/^[a-f0-9]{64}$/.test(value.configuration_digest) || !/^[1-9][0-9]*$/.test(value.draft_revision) ||
        typeof value.executor_bridge_id !== 'string' || !value.executor_bridge_id) return null;
    return {executorBridge:value.executor_bridge_id,draftId:value.draft_id,revision:value.draft_revision,configurationDigest:value.configuration_digest};
  } catch {return null;}
}

type DraftView = {draft_id:string;draft_revision:string;configuration:string;configuration_digest:string;state:string;launch_state:string};

// Keep the lifecycle controls reachable after readiness clears last_error.
// References and unresolved signed operations survive reload as ciphertext.
export function LocalLaunchSurface({instanceId,lastError}:{instanceId:string;lastError:unknown}) {
  const proposed = pendingLaunchDraft(lastError);
  const [draft,setDraft] = useState<LocalLaunchDraftRef|null>(proposed);
  useEffect(() => {
    let active = true;
    const session = getKeyringSession();
    if (!session) {setDraft(null);return;}
    const key = `local-launch-ref:${session.identity.userId}:${session.identity.deviceId}:${instanceId}`;
    if (proposed) {
      setDraft(proposed);
      void encryptVaultText(JSON.stringify(proposed),session.keyring).then(cipher => {
        if (active && getKeyringSession() === session) sessionStorage.setItem(key,cipher);
      });
    } else {
      const saved = sessionStorage.getItem(key);
      if (saved) void decryptVaultText(saved,session.keyring).then(raw => {
        const restored = JSON.parse(raw) as LocalLaunchDraftRef;
        if (active && getKeyringSession() === session) setDraft(restored);
      }).catch(() => {if (active) setDraft(null);});
    }
    return () => {active = false;};
  }, [instanceId,proposed?.draftId,proposed?.configurationDigest]);
  return draft ? <LocalLaunchApproval key={draft.draftId} draft={draft} instanceId={instanceId} /> : null;
}

export default function LocalLaunchApproval({draft, instanceId}: {draft:LocalLaunchDraftRef;instanceId:string}) {
  const [view,setView] = useState<DraftView|null>(null);
  const [pending,setPending] = useState<LocalLaunchOperation|null>(null);
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState('');
  const savedKey = (s:OwnerSession) => `local-launch:${s.identity.userId}:${s.identity.deviceId}:${draft.draftId}`;
  useEffect(() => subscribeKeyringSession(() => {setView(null);setError('Vault session changed; inspect the launch again.');}), []);
  useEffect(() => {
    let active = true;
    setView(null);setPending(null);setError('');
    const session = getKeyringSession();
    if (session) {
      const saved = sessionStorage.getItem(savedKey(session));
      if (saved) void decryptVaultText(saved,session.keyring).then(raw => {
        const operation = JSON.parse(raw) as LocalLaunchOperation;
        const request = executorParse(operation.request,'local_draft');
        if (request.draft_id !== draft.draftId || request.configuration_digest !== draft.configurationDigest) throw new Error('Retained operation mismatch.');
        if (active && getKeyringSession() === session) setPending(operation);
      }).catch(() => {if (active) setError('Could not open the retained operation. Unlock the original vault session.');});
    }
    return () => {active = false;};
  }, [draft.draftId,draft.configurationDigest]);
  async function current(): Promise<OwnerSession> {
    const session = getKeyringSession();
    if (!session) throw new Error('Unlock the vault to review this launch.');
    const chain = await verifyDirectory(await cookieJsonFetch('/api/v1/vault/directory'),session.identity.userId,pinsFromChain(session.chain));
    if (getKeyringSession() !== session || chain.currentEpoch !== session.keyring.currentEpoch) throw new Error('Vault session changed.');
    return {...session,chain};
  }
  async function send(operation:LocalLaunchOperation) {
    const before = getKeyringSession(), session = await current();
    const transport = await localLaunchRelay(session,operation);
    const response = await cookieMutation('/api/v1/executor/local-launch','POST',transport.relay) as {request_id?:string;envelope?:string};
    // Verify enrollment again after delayed I/O before accepting any reply.
    const fresh = await current();
    const result = await openLocalLaunchReply(fresh,transport,response);
    if (getKeyringSession() !== before) throw new Error('Vault session changed.');
    // An authenticated refusal is also a resolved outcome. A network failure
    // leaves the encrypted operation intact for exact retry, including reload.
    sessionStorage.removeItem(savedKey(session));setPending(null);
    if (result.code !== 'ok') throw new Error(result.code);
    const observed = JSON.parse(result.body) as DraftView;
    const config = executorParse(observed.configuration,'local_configuration');
    if (observed.draft_id !== draft.draftId || observed.draft_revision !== draft.revision ||
        observed.configuration_digest !== draft.configurationDigest || config.instance_id !== instanceId ||
        config.executor_bridge_id !== draft.executorBridge || await ownerPayloadDigest(observed.configuration) !== draft.configurationDigest) throw new Error('Launch identity mismatch.');
    setView(observed);setPending(null);
  }
  async function run(method:'prepare'|'inspect'|'authorize'|'cancel'|'retry') {
    setBusy(true);setError('');
    try {
      if (method === 'retry') {
        if (!pending) return;
        await send(pending);
      } else {
        if (pending) throw new Error('Resolve the retained operation with Retry before starting another operation.');
        const operation = await prepareLocalLaunchOperation(await current(),draft,method);
        const session = await current();
        sessionStorage.setItem(savedKey(session),await encryptVaultText(JSON.stringify(operation),session.keyring));
        setPending(operation); // Retain exact signed bytes across lost replies.
        await send(operation);
      }
    } catch (e) {setError(e instanceof Error ? e.message : String(e));}
    finally {setBusy(false);}
  }
  const config = view ? executorParse(view.configuration,'local_configuration') : null;
  return <section className="mt-3 border border-subtle p-3" data-debug-id="local-launch-approval">
    <h3>{view?.state === 'authorized' ? 'Local launch controls' : 'Launch approval and controls'}</h3>
    <p>Review the execution device and resources before allowing this launch. Only the device that prepares the draft can approve or cancel it.</p>
    <p>Execution device: {draft.executorBridge}</p>
    {config && <dl>
      <dt>Provider and model</dt><dd>{config.provider} / {config.model} ({config.provider_profile})</dd>
      <dt>Purpose</dt><dd>{config.purpose}</dd>
      <dt>Protected directory</dt><dd>{config.directory_id}, revision {config.directory_revision}</dd>
      <dt>Slot and policy</dt><dd>{config.slot_id}, policy {config.policy_revision}</dd>
      <dt>Launch generation</dt><dd>{config.run_count}</dd>
      <dt>Current observation</dt><dd>{view?.state} {view?.launch_state}</dd>
    </dl>}
    <div className="flex gap-3 flex-wrap">
      <button data-debug-id="local-launch-prepare" disabled={busy || !!pending} onClick={() => void run('prepare')}>Prepare review</button>
      <button data-debug-id="local-launch-inspect" disabled={busy || !!pending} onClick={() => void run('inspect')}>Inspect current state</button>
      <button data-debug-id="local-launch-authorize" disabled={busy || !!pending || view?.state !== 'prepared'} onClick={() => void run('authorize')}>Approve exact launch</button>
      <button data-debug-id="local-launch-cancel" disabled={busy || !!pending || !view || view.state === 'cancelled'} onClick={() => void run('cancel')}>Cancel launch</button>
      <button data-debug-id="local-launch-retry" disabled={busy || !pending} onClick={() => void run('retry')}>Retry retained operation</button>
    </div>
    {error && <p role="alert">{error}</p>}
    {view?.state === 'authorized' && <p>Authorization was recorded. Inspect current state for the latest child observation.</p>}
  </section>;
}
