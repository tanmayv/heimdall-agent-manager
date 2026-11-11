package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "core:encoding/json"
import vault "odin_test:lib/vault"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

// Owner-Bridge consent (option b): with no operator mapping, this executor
// installs its first policy and a per-chain scratch directory with its own
// key, and returns the selectors it chose.
@(test)
test_executor_auto_issuance_resolves_without_operator_mapping :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    st:=p1c_test_setup(t);defer p1c_test_teardown(st)
    sync.mutex_lock(&keystore_test_mutex);defer sync.mutex_unlock(&keystore_test_mutex)
    id,_:=keystore_test_bridge_ids()
    prior_id:=keystore_test_set_daemon_id(id);defer {bridge_cfg().daemon_id=prior_id}
    keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()
    unseal_nonce_cache_clear(&g_unseal_nonce_cache);bridge_unseal_init()
    if !testing.expect(t,test_provision_identity(id)) do return
    defer {keystore_lock_and_purge(id);_=keystore_delete_identity_key(id);bridge_unseal_forget_identity()}
    kr:=test_keyring_from_hex(TEST_VAULT_KEY_HEX);defer vault.keyring_wipe(&kr)
    now:=time.to_unix_nanoseconds(time.now())/1000000
    payload:=test_create_unseal_v2_payload(id,&kr,now,"issuance_auto_pair")
    unsealed,_:=bridge_unseal_decrypt_and_verify(payload,id,now)
    if !testing.expect(t,unsealed) do return
    public:=bridge_identity_public_key_hex(id);key_id,_:=vault.device_id_from_sign_pub(public,context.temp_allocator)
    self:=contracts.Owner_Verified_Key{TEST_VAULT_USER_ID,id,key_id,public,"bridge",true,false}
    if !testing.expect(t,bridge_executor_open(TEST_VAULT_USER_ID,key_id)) do return
    executor_root,_:=bridge_executor_root(TEST_VAULT_USER_ID)
    defer {executor.close(&bridge_executor_store);_=os.remove_all(executor_root)}
    // As in production (file root $HOME): the executor's private root is
    // inside the Bridge's file root.
    prior_root:=bridge_fs_root;root:=bridge_fs_canonicalize_existing(executor_root);defer delete(root)
    bridge_fs_root=root;defer {bridge_fs_root=prior_root}
    s:=&bridge_executor_store
    auto:=contracts.EXECUTOR_AUTO_SELECTOR
    requested:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","seed",auto,auto,"1",auto})
    consent:=make(json.Object);consent["chain_id"]=json.String("chain_auto")
    resources:=bridge_executor_resolve_auto_issuance(s,consent,requested,self)
    if !testing.expect(t,resources.resolved,"resolved with no operator policy or directory") do return
    chosen,chosen_ok:=contracts.executor_parse(resources.selection,"issuance_selection")
    if !testing.expect(t,chosen_ok) do return
    get:=contracts.owner_string
    testing.expect(t,get(chosen,"provider")=="claude" && get(chosen,"model")=="seed" && get(chosen,"provider_profile")=="claude")
    testing.expect_value(t,get(chosen,"policy_revision"),"1")
    testing.expect_value(t,get(chosen,"slot_id"),"auto_claude")
    testing.expect(t,strings.has_prefix(get(chosen,"directory_id"),"scratch_"))
    testing.expect(t,strings.has_prefix(resources.directory_path,fmt.tprintf("%s/scratch/",executor_root)),"scratch lives in the executor's private root")
    testing.expect(t,os.is_dir(resources.directory_path))
    testing.expect_value(t,resources.selection_digest,contracts.owner_payload_digest(requested))
    // Idempotent per chain: same directory, no new mapping or policy revision.
    again:=bridge_executor_resolve_auto_issuance(s,consent,requested,self)
    testing.expect(t,again.resolved && again.directory_path==resources.directory_path && again.selection==resources.selection)
    revision,_:=executor.directory_latest_revision(s,get(chosen,"directory_id"))
    testing.expect_value(t,revision,i64(1))
    // Another chain gets its own scratch directory.
    other:=make(json.Object);other["chain_id"]=json.String("chain_other")
    separate:=bridge_executor_resolve_auto_issuance(s,other,requested,self)
    testing.expect(t,separate.resolved && separate.directory_path!=resources.directory_path)
    // task_18e70e69aca835a7: a model this Bridge never observed (its claude
    // reports aliases only) but the account catalog lists as active is placed;
    // an inactive or unknown one is still refused.
    bridge_provider_catalog_default_hook=[]Bridge_Catalog_Provider{{provider="claude",state="active",models=[]Bridge_Catalog_Model{{model_id="claude-sonnet-5-5",state="active"},{model_id="claude-old",state="retired"}}}}
    defer bridge_provider_catalog_default_hook=nil
    catalog_only:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","claude-sonnet-5-5",auto,auto,"1",auto})
    placed:=bridge_executor_resolve_auto_issuance(s,consent,catalog_only,self)
    testing.expect(t,placed.resolved,"an active catalog model the Bridge has not observed is placed")
    for bad in ([2]string{"claude-old","claude-nope"}) {
        refused:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude",bad,auto,auto,"1",auto})
        testing.expectf(t,!bridge_executor_resolve_auto_issuance(s,consent,refused,self).resolved,"%s is refused",bad)
    }
    // Git tickets (user 15:30Z): the Hub's hint names this Bridge's checkout
    // of the chain's project, so the work runs there.
    checkout:=fmt.tprintf("%s/checkout",root)
    if !testing.expect(t,os.make_directory(checkout)==nil) do return
    hinted:=bridge_executor_resolve_auto_issuance(s,consent,requested,self,checkout)
    if !testing.expect(t,hinted.resolved,"a valid project hint resolves") do return
    testing.expect_value(t,hinted.directory_path,checkout)
    hinted_selection,_:=contracts.executor_parse(hinted.selection,"issuance_selection")
    testing.expect(t,strings.has_prefix(get(hinted_selection,"directory_id"),"project_"),"the checkout is mapped as a project directory")
    hinted_mapping,hinted_mapped:=executor.directory_mapping(s,get(hinted_selection,"directory_id"))
    testing.expect(t,hinted_mapped && hinted_mapping.path==checkout,"self-mapped with the executor's own key")
    // A missing, outside-root or non-directory hint falls back to the
    // chain's scratch directory: never a refusal.
    for bad in ([3]string{fmt.tprintf("%s/missing",root),"/",fmt.tprintf("%s/runtime.sqlite",executor_root)}) {
        fallback:=bridge_executor_resolve_auto_issuance(s,consent,requested,self,bad)
        testing.expectf(t,fallback.resolved && fallback.directory_path==resources.directory_path,"hint %s falls back to scratch",bad)
    }
    // Refusals: an explicit selection, an unknown model, another key.
    explicit:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","seed","claude","dir","1","slot1"})
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,explicit,self).resolved,"explicit selections use the operator resolver")
    unknown:=executor.encode(struct{provider,model,provider_profile,directory_id,policy_revision,slot_id:string}{"claude","not-in-catalog",auto,auto,"1",auto})
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,unknown,self).resolved,"an unknown model is refused")
    stranger:=self;stranger.key_id="other_key"
    testing.expect(t,!bridge_executor_resolve_auto_issuance(s,consent,requested,stranger).resolved,"only this executor's own key provisions")
}
