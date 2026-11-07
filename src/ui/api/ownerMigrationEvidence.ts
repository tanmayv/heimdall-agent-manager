import {ownerCanonical,ownerDigest,ownerDocumentValid,ownerPayloadDigest,ownerVerifySignature,OWNER_REQUEST_TTL_MS} from './ownerLocal.ts';
import type {OwnerError,OwnerVerifiedKey} from './ownerLocal.ts';
import type {OwnerDocuments as D} from './ownerSchema.ts';

export interface MigrationDirectoryPin {root:string;head:string;sequence:bigint;epoch:bigint}
const hex = (s:string) => /^[0-9a-f]{64}$/.test(s);
type Correlation = Pick<D['migration_source_inventory'],'account_id'|'chain_id'|'migration_id'|'selection_digest'|'source_generation'>;
function correlates(a:Correlation,b:Correlation):boolean {
  return (['account_id','chain_id','migration_id','selection_digest','source_generation'] as const).every(k=>a[k]===b[k]);
}

// Proof correlation only. Native completeness, physical observation, current
// directory and journal/CAS checks remain prerequisites to any transition.
export function migrationObservationAdmit(kind:'migration_executor_inventory'|'migration_executor_drain'|'migration_origin_binding',o:D[typeof kind],now:bigint):OwnerError {
  if (!ownerDocumentValid(kind,o)) return 'malformed';
  const issued=BigInt('issued_ms' in o ? o.issued_ms : o.observed_ms),expires=BigInt(o.request_expires_ms);
  return now<0n || issued>now || expires<=now || issued>=expires || expires-issued>OWNER_REQUEST_TTL_MS ? 'expired' : 'none';
}

export async function verifyMigrationExecutorInventory(o:D['migration_executor_inventory'],source:D['migration_source_inventory'],challenge:string,key:OwnerVerifiedKey):Promise<OwnerError> {
  if (!ownerDocumentValid('migration_executor_inventory',o) || !ownerDocumentValid('migration_source_inventory',source) || !hex(challenge)) return 'malformed';
  if (key.kind!=='bridge' || key.account_id!==o.account_id || key.principal_id!==o.executor_bridge_id || key.key_id!==o.key_id || !correlates(o,source)) return 'invalid_scope';
  if (o.source_inventory_digest!==await ownerDigest('migration_source_inventory',source) || o.challenge!==challenge) return 'digest_mismatch';
  if (source.admission_closed!=='1' || source.coverage_version!=='1' || o.coverage_version!=='1' || o.complete!=='1' || o.unknown_count!=='0') return 'invalid_scope';
  return await ownerVerifySignature('migration_executor_inventory',o,'signature',key) ? 'none' : 'bad_signature';
}

export async function verifyMigrationAdoption(o:D['migration_origin_binding'],selection:D['migration_selection'],source:D['migration_source_inventory'],executorSetDigest:string,mappingDigest:string,mappingCount:bigint,pin:MigrationDirectoryPin,device:OwnerVerifiedKey):Promise<OwnerError> {
  if (!ownerDocumentValid('migration_origin_binding',o) || !ownerDocumentValid('migration_selection',selection) || !ownerDocumentValid('migration_source_inventory',source) || !hex(executorSetDigest) || !hex(mappingDigest) || mappingCount<0n) return 'malformed';
  if (device.kind!=='device' || device.account_id!==o.account_id || device.principal_id!==o.principal_id || device.key_id!==o.key_id) return 'invalid_scope';
  if (!(['account_id','chain_id','migration_id','owner_bridge_id','owner_key_id'] as const).every(k=>o[k]===selection[k]) || !correlates(o,source) || o.source_revision!==source.source_revision || o.executor_count!==source.executor_count || source.admission_closed!=='1') return 'invalid_scope';
  if (o.selection_digest!==await ownerDigest('migration_selection',selection) || o.source_inventory_digest!==await ownerDigest('migration_source_inventory',source) || o.executor_inventories_digest!==executorSetDigest || o.mapping_digest!==mappingDigest || o.mapping_count!==String(mappingCount)) return 'digest_mismatch';
  if (!hex(pin.root) || !hex(pin.head) || pin.sequence<0n || pin.epoch<=0n || o.directory_root!==pin.root || o.directory_head!==pin.head || o.directory_sequence!==String(pin.sequence) || o.directory_epoch!==String(pin.epoch)) return 'invalid_scope';
  return await ownerVerifySignature('migration_origin_binding',o,'signature',device) ? 'none' : 'bad_signature';
}

export async function verifyMigrationExecutorDrain(o:D['migration_executor_drain'],inventory:D['migration_executor_inventory'],binding:D['migration_origin_binding'],barrierDigest:string,challenge:string,key:OwnerVerifiedKey):Promise<OwnerError> {
  if (!ownerDocumentValid('migration_executor_drain',o) || !ownerDocumentValid('migration_executor_inventory',inventory) || !ownerDocumentValid('migration_origin_binding',binding) || !hex(barrierDigest) || !hex(challenge)) return 'malformed';
  if (key.kind!=='bridge' || key.account_id!==o.account_id || key.principal_id!==o.executor_bridge_id || key.key_id!==o.key_id || !correlates(o,inventory) || !correlates(o,binding)) return 'invalid_scope';
  if (!(['executor_bridge_id','key_id','executor_incarnation'] as const).every(k=>o[k]===inventory[k]) || BigInt(o.journal_sequence)<BigInt(inventory.journal_sequence) || o.complete!=='1') return 'invalid_scope';
  if (!(['unresolved_count','admitted_handler_count','live_child_count','merge_count','queued_action_count'] as const).every(k=>o[k]==='0')) return 'invalid_scope';
  if (o.inventory_digest!==await ownerDigest('migration_executor_inventory',inventory) || o.binding_digest!==await ownerDigest('migration_origin_binding',binding) || o.barrier_receipt_digest!==barrierDigest || o.challenge!==challenge || o.mapping_digest!==binding.mapping_digest || o.source_inventory_digest!==binding.source_inventory_digest) return 'digest_mismatch';
  return await ownerVerifySignature('migration_executor_drain',o,'signature',key) ? 'none' : 'bad_signature';
}

export async function migrationMappingMatches(effect:D['migration_effect'],mapping:D['migration_mapping']):Promise<boolean> {
  if (!ownerDocumentValid('migration_effect',effect) || !ownerDocumentValid('migration_mapping',mapping)) return false;
  if (mapping.effect_digest!==await ownerDigest('migration_effect',effect) || !(['executor_bridge_id','effect_id','command_id','entry_index','kind','parent_digest','entry_digest','task_id','instance_id','lease_id'] as const).every(k=>mapping[k]===effect[k])) return false;
  if (mapping.target_kind==='never_admitted') return (['native_admission_digest','launch_key','launch_epoch','token_generation','configuration_digest','directory_id','directory_key','workdir_hash','repository_hash','branch'] as const).every(k=>mapping[k]==='') && mapping.run_count==='0' && mapping.directory_revision==='0';
  if (!hex(mapping.native_admission_digest) || !hex(mapping.workdir_hash)) return false;
  if (mapping.target_kind==='merge') return effect.kind==='merge' && mapping.task_id!=='' && hex(mapping.repository_hash) && mapping.branch!=='' && mapping.launch_key==='' && mapping.run_count==='0';
  return effect.kind!=='merge' && mapping.instance_id!=='' && mapping.launch_epoch!=='' && mapping.directory_id!=='' && mapping.run_count!=='0' && mapping.directory_revision!=='0' && (['launch_key','token_generation','configuration_digest','directory_key'] as const).every(k=>hex(mapping[k]));
}

export async function migrationSetDigest<K extends 'migration_effect'|'migration_mapping'|'migration_inventory_reference'>(kind:K,rows:D[K][]):Promise<string> {
  if (rows.length>100000) throw new Error('Migration set exceeds capacity');
  const fields=kind==='migration_effect' ? ['effect_id','entry_index'] : kind==='migration_mapping' ? ['executor_bridge_id','effect_id','entry_index'] : ['executor_bridge_id'];
  let previous='',bytes=`heimdall-migration-set/${kind}/v1\n${rows.length}:`;
  for (const [index,row] of rows.entries()) {
    if (!ownerDocumentValid(kind,row)) throw new Error('Malformed migration set row');
    const record=row as unknown as Record<string,string>;
    const identity=fields.map(k=>`${record[k].length}:${record[k]},`).join('');
    if (index>0 && previous>=identity) throw new Error('Unsorted or duplicate migration identity');
    previous=identity;
    const canonical=ownerCanonical(kind,row);
    bytes+=`${canonical.length}:${canonical},`;
  }
  return ownerPayloadDigest(bytes);
}
