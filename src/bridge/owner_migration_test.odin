#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

Migration_Test_Hub :: struct { state,digest:string, calls:int }

migration_test_lookup :: proc(ctx:rawptr,migration:string)->(Owner_Migration_State_Wire,bool) {
    hub:=(^Migration_Test_Hub)(ctx)
    hub.calls+=1
    if hub.state=="" do return {},false // Hub unreachable
    if hub.state=="absent" do return Owner_Migration_State_Wire{migration_id=migration,state="absent"},true
    return Owner_Migration_State_Wire{migration,"legacy_chain",hub.state,hub.digest,"bridge"},true
}
migration_test_sign :: proc(ctx:rawptr,kind:string,o:json.Object)->(string,bool) {
    canonical,ok:=contracts.owner_canonical(kind,o)
    if !ok do return "",false
    sig,signed:=vault.sign_p256((^ecdsa.Private_Key)(ctx),transmute([]byte)canonical)
    if !signed do return "",false
    return vault.hex_encode_lower(sig.sig[:],context.temp_allocator),true
}

// Cutover ordering, owner side: an imported chain admits no work until the
// Hub reports `imported` for the exact manifest, including across a restart
// between the Hub cutover and local activation.
@(test)
test_owner_migration_activation_waits_for_hub_cutover_across_restart :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    path:=fmt.tprintf("%s/.cache/heimdall-tests/owner-migration-activate-%d.sqlite",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    store:owner.Store
    if !testing.expect(t,owner.open(&store,path,"account","bridge","bridge_key")) do return
    defer {
        owner.close(&store)
        for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,suffix))
    }
    priv:ecdsa.Private_Key
    testing.expect(t,vault.p256_private_key_generate(&priv));defer ecdsa.private_key_clear(&priv)
    pub:[65]byte;ecdsa.private_key_public_bytes(&priv,pub[:])
    id,_:=vault.vault_id_from_root_sign_pub(vault.hex_encode_lower(pub[:],context.temp_allocator))
    key:[32]byte;key[0]=9
    kr,_:=vault.keyring_from_single_key("account",id,1,key[:]);defer vault.keyring_wipe(&kr)
    digest:=strings.repeat("d",64)
    // The state migration_import leaves behind: chain, task and a pending import.
    testing.expect(t,owner.exec(store.db,fmt.tprintf(`INSERT INTO task_chains VALUES('legacy_chain','device','device','Legacy','desc',1);
      INSERT INTO tasks VALUES('legacy_chain','t_ready','Ready','body',1);
      INSERT INTO chain_genesis(chain_id,creation_op,genesis_digest,genesis_json,import_manifest_hash) VALUES('legacy_chain','mig','%s','{{}}','%s');
      INSERT INTO migration_imports VALUES('mig','%s','legacy_chain','%s','device','device',1,'{{}}','{{}}','{{}}',NULL);
      UPDATE runtime_database SET commit_seq=1;`,strings.repeat("a",64),digest,digest,strings.repeat("b",64))))
    hub:=Migration_Test_Hub{state="frozen",digest=digest}
    mutex:sync.Mutex
    signer:=owner.Signer{&priv,migration_test_sign}
    testing.expect_value(t,bridge_owner_migration_reconcile_store(&store,&mutex,&hub,migration_test_lookup,1000,&kr,signer),0)
    testing.expect(t,!owner.control_ready(&store,"legacy_chain","t_ready"),"frozen at the Hub: no local admission")
    hub.state="imported";hub.digest=strings.repeat("e",64)
    testing.expect_value(t,bridge_owner_migration_reconcile_store(&store,&mutex,&hub,migration_test_lookup,1000,&kr,signer),0)
    testing.expect(t,!owner.control_ready(&store,"legacy_chain","t_ready"),"a different manifest never activates")
    hub.state=""
    testing.expect_value(t,bridge_owner_migration_reconcile_store(&store,&mutex,&hub,migration_test_lookup,1000,&kr,signer),0)
    // Restart after the Hub cutover committed but before activation.
    owner.close(&store)
    testing.expect(t,owner.open(&store,path,"account","bridge","bridge_key"))
    testing.expect(t,!owner.control_ready(&store,"legacy_chain","t_ready"),"restart keeps the quarantine")
    hub.state="imported";hub.digest=digest
    testing.expect_value(t,bridge_owner_migration_reconcile_store(&store,&mutex,&hub,migration_test_lookup,2000,&kr,signer),1)
    testing.expect(t,owner.control_ready(&store,"legacy_chain","t_ready"),"admission only after the Hub reports imported")
    rows,_:=owner.query(store.db,"SELECT count(*) FROM runtime_intents WHERE chain_id='legacy_chain' AND kind='registry'")
    testing.expect_value(t,rows[0][0],"2")
    calls:=hub.calls
    testing.expect_value(t,bridge_owner_migration_reconcile_store(&store,&mutex,&hub,migration_test_lookup,3000,&kr,signer),0)
    testing.expect_value(t,hub.calls,calls)
    // A second import whose Hub migration was aborted is abandoned: it stays
    // quarantined, is never activated and is not polled again.
    testing.expect(t,owner.exec(store.db,fmt.tprintf(`INSERT INTO task_chains VALUES('aborted_chain','device','device','Aborted','desc',1);
      INSERT INTO tasks VALUES('aborted_chain','t_aborted','Aborted','body',1);
      INSERT INTO chain_genesis(chain_id,creation_op,genesis_digest,genesis_json,import_manifest_hash) VALUES('aborted_chain','mig_aborted','%s','{{}}','%s');
      INSERT INTO migration_imports VALUES('mig_aborted','%s','aborted_chain','%s','device','device',4,'{{}}','{{}}','{{}}',NULL);`,strings.repeat("c",64),digest,digest,strings.repeat("b",64))))
    hub.state="absent"
    testing.expect_value(t,bridge_owner_migration_reconcile_store(&store,&mutex,&hub,migration_test_lookup,4000,&kr,signer),0)
    pending,_:=owner.migration_pending(&store)
    testing.expect_value(t,len(pending),0)
    testing.expect(t,!owner.control_ready(&store,"aborted_chain","t_aborted"),"an aborted import is never admitted")
    calls=hub.calls
    hub.state="imported"
    testing.expect_value(t,bridge_owner_migration_reconcile_store(&store,&mutex,&hub,migration_test_lookup,5000,&kr,signer),0)
    testing.expect_value(t,hub.calls,calls)
}
