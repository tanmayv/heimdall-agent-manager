import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {executorChannelAad,sealExecutorChannel,openExecutorChannel,openSignedExecutorChannel} from '../src/ui/api/executorChannel.ts';
import {type ExecutorDocument} from '../src/ui/api/executor.ts';
import {type OwnerVerifiedKey} from '../src/ui/api/ownerLocal.ts';
import {type VaultKeyring} from '../src/ui/utils/vaultKeyring.ts';
const vector = JSON.parse(readFileSync(new URL('../src/contracts/fixtures/executor-channel-v1.json',import.meta.url),'utf8')) as {
  scope:ExecutorDocument;reply_scope:ExecutorDocument;request:string;reply:string;aad:string;token:string;reply_token:string;old_token:string;content_token:string;
  vault_id:string;epoch:number;epoch_key_hex:string;old_epoch_key_hex:string;nonce_hex:string;owner_key:OwnerVerifiedKey;executor_key:OwnerVerifiedKey;
};
const bytes = (hex:string) => Uint8Array.from(Buffer.from(hex,'hex'));
async function keyring():Promise<VaultKeyring> {
  const current = await crypto.subtle.importKey('raw',bytes(vector.epoch_key_hex),{name:'AES-GCM'},false,['encrypt','decrypt']);
  const old = await crypto.subtle.importKey('raw',bytes(vector.old_epoch_key_hex),{name:'AES-GCM'},false,['encrypt','decrypt']);
  return {userId:'account',vaultId:vector.vault_id,currentEpoch:vector.epoch,keys:new Map([[1,old],[2,current]])};
}
test('executor channel shares exact AAD/ciphertext and verifies both signed directions',async()=>{
  const kr=await keyring();
  assert.equal(new TextDecoder().decode(executorChannelAad(vector.scope,kr.vaultId,kr.currentEpoch)),vector.aad);
  assert.equal(await sealExecutorChannel(vector.request,kr,vector.scope,1200n,bytes(vector.nonce_hex)),vector.token);
  assert.equal(await openSignedExecutorChannel(vector.token,kr,vector.scope,vector.owner_key,1200n),vector.request);
  assert.equal(await openSignedExecutorChannel(vector.reply_token,kr,vector.reply_scope,vector.executor_key,1200n),vector.reply);
  assert.equal(await openSignedExecutorChannel(vector.reply_token,kr,vector.reply_scope,vector.owner_key,1200n),null);
  const a=await sealExecutorChannel(vector.request,kr,vector.scope,1200n),b=await sealExecutorChannel(vector.request,kr,vector.scope,1200n);
  assert.notEqual(a,b);
  assert.equal(await openSignedExecutorChannel(a,kr,vector.scope,vector.owner_key,1200n),vector.request);
});
test('executor channel rejects every routing-field substitution, expired scope and retained old epoch',async()=>{
  const kr=await keyring();
  for(const [name,value] of Object.entries({protocol_version:'2',account_id:'other',owner_bridge_id:'other',executor_bridge_id:'other',chain_id:'other',reservation_id:'other',request_id:'other',method:'action',direction:'response',
    input_digest:'e'.repeat(64),fence_digest:'f'.repeat(64),owner_incarnation:'2',executor_incarnation:'2',issued_ms:'1100',request_expires_ms:'2500'})) {
    assert.equal(await openExecutorChannel(vector.token,kr,{...vector.scope,[name]:value},1200n),null,name);
  }
  for(const now of [999n,2000n,10000n]) assert.equal(await openExecutorChannel(vector.token,kr,vector.scope,now),null);
  assert.ok(kr.keys.has(1));
  assert.equal(await openExecutorChannel(vector.old_token,kr,vector.scope,1200n),null);
  assert.equal(await openExecutorChannel(vector.content_token,kr,vector.scope,1200n),null);
  assert.equal(await openExecutorChannel(vector.token,{...kr,vaultId:'0202030405060708'},vector.scope,1200n),null);
  await assert.rejects(sealExecutorChannel('x'.repeat(32769),kr,vector.scope,1200n));
});
test('shared account key cannot replace sender signature or exact original request correlation',async()=>{
  const kr=await keyring();
  const request={...JSON.parse(vector.request),signature:'0'.repeat(128)};
  const forged=await sealExecutorChannel(JSON.stringify(request),kr,vector.scope,1200n);
  assert.equal(await openExecutorChannel(forged,kr,vector.scope,1200n),JSON.stringify(request));
  assert.equal(await openSignedExecutorChannel(forged,kr,vector.scope,vector.owner_key,1200n),null);
  assert.equal(await openSignedExecutorChannel(vector.token,kr,vector.scope,{...vector.owner_key,revoked:true},1200n),null);
  for(const field of ['input_digest','fence_digest']) {
    const scope={...vector.scope,[field]:'e'.repeat(64)};
    const rebound=await sealExecutorChannel(vector.request,kr,scope,1200n);
    assert.equal(await openSignedExecutorChannel(rebound,kr,scope,vector.owner_key,1200n),null);
  }
  const enrollment={...vector.scope,method:'enrollment',reservation_id:''};
  const pending=await sealExecutorChannel(vector.request,kr,enrollment,1200n);
  assert.equal(await openSignedExecutorChannel(pending,kr,enrollment,vector.owner_key,1200n),null);
});
