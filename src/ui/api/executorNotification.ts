import { executorCanonical, executorParse, executorVerify, type ExecutorDocument } from './executor.ts';
import { ownerPayloadDigest, type OwnerVerifiedKey } from './ownerLocal.ts';

const same = (a: ExecutorDocument,b: ExecutorDocument,names: string[]) => names.every(n=>a[n]===b[n]);
const scope = ['account_id','executor_bridge_id','owner_bridge_id','chain_id','reservation_id','executor_incarnation','owner_incarnation'];
export function notificationMessageValid(message: string): boolean {
  if (!message || new TextEncoder().encode(message).length>16384) return false;
  for (const ch of message) {
    const n=ch.codePointAt(0)!;
    if ((n<0x20 && n!==0x0a && n!==0x09) || (n>=0x7f && n<=0x9f) || (n>=0xd800 && n<=0xdfff)) return false;
  }
  return true;
}
export async function executorNotificationMatches(n: ExecutorDocument,b: ExecutorDocument,message: string,key: OwnerVerifiedKey,now: number|bigint): Promise<boolean> {
  try {
    executorParse(JSON.stringify(n),'notification');
    if (!await executorVerify('notification',n,key) || !await executorVerify('bootstrap',b,key) ||
        !notificationMessageValid(message) || n.message_digest!==await ownerPayloadDigest(message)) return false;
    return same(n,b,['protocol_version',...scope,'task_id','lease_id','instance_id','launch_epoch','run_count','token_generation',
      'configuration_revision','grant_generation','prepare_digest','launch_key','hard_ms','key_id']) &&
      BigInt(now)>=BigInt(n.issued_ms) && BigInt(now)<BigInt(n.request_expires_ms) && BigInt(now)<BigInt(n.expires_ms) && BigInt(now)<BigInt(n.hard_ms);
  } catch { return false; }
}
export async function executorNotificationResultMatches(r: ExecutorDocument,n: ExecutorDocument,message: string,key: OwnerVerifiedKey,now: number|bigint): Promise<boolean> {
  try {
    executorParse(JSON.stringify(n),'notification');
    if (!await executorVerify('notification_result',r,key) || !notificationMessageValid(message) ||
        n.message_digest!==await ownerPayloadDigest(message) || !same(r,n,['protocol_version',...scope,'prepare_digest','intent_id']) ||
        r.input_digest!==await ownerPayloadDigest(executorCanonical('notification',n)) ||
        BigInt(now)<BigInt(r.issued_ms) || BigInt(now)>=BigInt(r.request_expires_ms) ||
        BigInt(r.message_bytes_written)>BigInt(new TextEncoder().encode(message).length)) return false;
    if (r.status==='unsupported_not_delivered') return r.pid==='0' && r.ticket==='' && r.input_profile==='' &&
      r.esc_written==='0' && r.message_bytes_written==='0' && r.enter_written==='0';
    if (r.status==='partial' || r.status==='delivered') {
      const id=(s: string)=>/^[\x21-\x7e]{1,256}$/.test(s);
      if (BigInt(r.pid)<=0n || !id(r.ticket) || !id(r.input_profile)) return false;
      const written=BigInt(r.message_bytes_written),size=BigInt(new TextEncoder().encode(message).length),esc=r.esc_written==='1',enter=r.enter_written==='1';
      if ((!esc && (written>0n || enter)) || (enter && written!==size)) return false;
      const complete=esc && enter && written===size;
      return r.status==='delivered' ? complete : !complete;
    }
    return r.status==='recovery_required' || r.status==='child_mismatch';
  } catch { return false; }
}
export async function executorNotificationFenceMatches(r: ExecutorDocument,q: ExecutorDocument,n: ExecutorDocument,ownerKey: OwnerVerifiedKey,executorKey: OwnerVerifiedKey,now: number|bigint): Promise<boolean> {
  try {
    if (!await executorVerify('notification_fence_request',q,executorKey) || !await executorVerify('notification_fence_reply',r,ownerKey) ||
        !await executorVerify('notification',n,ownerKey) || !same(r,q,[...scope,'request_expires_ms']) || !same(q,n,scope)) return false;
    const bound=executorParse(q.notification,'notification');
    const nd=await ownerPayloadDigest(executorCanonical('notification',n)),bd=await ownerPayloadDigest(executorCanonical('notification',bound)),qd=await ownerPayloadDigest(executorCanonical('notification_fence_request',q));
    return nd===bd && bound.signature===n.signature && q.intent_id===n.intent_id && q.action_digest===nd && r.action_digest===nd && r.request_digest===qd &&
      r.prepare_digest===n.prepare_digest && r.challenge===q.challenge && r.owner_commit_seq===n.owner_commit_seq &&
      BigInt(r.checked_ms)>=BigInt(q.issued_ms) && BigInt(now)>=BigInt(r.checked_ms) && BigInt(now)<BigInt(q.request_expires_ms) &&
      BigInt(now)<BigInt(n.request_expires_ms) && BigInt(now)<BigInt(n.expires_ms) && BigInt(now)<BigInt(n.hard_ms);
  } catch { return false; }
}
