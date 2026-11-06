package http

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import vault "odin_test:lib/vault"

@(test)
owner_registry_bound_publication_survives_creator_revocation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    value,_:=json.parse_string(#load("../../../contracts/fixtures/owner-local-v1.json",string),.JSON,true,context.temp_allocator)
    fixture:=value.(json.Object)
    entries:=fixture["valid"].(json.Array)
    raw_genesis,raw_registry: string
    for entry in entries {
        e:=entry.(json.Object)
        switch contracts.owner_string(e,"kind") {
        case "genesis":raw_genesis=contracts.owner_string(e,"raw")
        case "registry":raw_registry=contracts.owner_string(e,"raw")
        }
    }
    genesis,_:=contracts.owner_parse(raw_genesis,"genesis")
    registry,_:=contracts.owner_parse(raw_registry,"registry")
    creator:=contracts.Owner_Verified_Key{"acct_1","dev_1","device_key",contracts.owner_string(fixture,"creator_public_key"),"device",true,false}
    owner:=contracts.Owner_Verified_Key{"acct_1","brg_1","bridge_key",contracts.owner_string(fixture,"bridge_public_key"),"bridge",true,false}
    testing.expect(t,owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",creator,owner,nil),"initial registration requires both signatures")
    digest,_:=contracts.owner_digest("genesis",genesis)
    row:=domain.Owner_Registry_Record{account_id="acct_1",chain_id="chain_1",owner_bridge_id="brg_1",owner_key_id="bridge_key",creator_id="dev_1",genesis_digest=digest,genesis_json=raw_genesis}
    bound:=[1]domain.Owner_Registry_Record{row}
    creator.enrolled=false;creator.revoked=true
    testing.expect(t,!owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",creator,owner,nil),"first publication after creator revocation fails closed")
    // Sign newer metadata with the fixture's synthetic scalar 2 owner key.
    scalar:[32]byte;scalar[31]=2
    private:ecdsa.Private_Key
    testing.expect(t,ecdsa.private_key_set_bytes(&private,.SECP256R1,scalar[:]))
    defer ecdsa.private_key_clear(&private)
    registry["metadata_revision"]=json.String("2")
    canonical,_:=contracts.owner_canonical("registry",registry)
    sig,signed:=vault.sign_p256(&private,transmute([]byte)canonical)
    testing.expect(t,signed)
    registry["signature"]=json.String(vault.hex_encode_lower(sig.sig[:],context.temp_allocator))
    testing.expect(t,owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",creator,owner,bound[:]),"current owner can publish newer bound metadata without creator")
    testing.expect(t,owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",{},owner,bound[:]),"creator removed entirely from trusted map")
    for field in 0..<6 {
        bad:=row
        switch field {
        case 0:bad.owner_bridge_id="other"
        case 1:bad.owner_key_id="other"
        case 2:bad.genesis_digest=strings.repeat("0",64,context.temp_allocator)
        case 3:bad.genesis_json="substitute"
        case 4:bad.account_id="other"
        case 5:bad.creator_id="other"
        }
        conflict:=[1]domain.Owner_Registry_Record{bad}
        testing.expect(t,!owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",creator,owner,conflict[:]))
    }
    revoked_owner:=owner;revoked_owner.revoked=true
    testing.expect(t,!owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",creator,revoked_owner,bound[:]))
    missing_owner:=owner;missing_owner.enrolled=false
    testing.expect(t,!owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",creator,missing_owner,bound[:]))
    registry["metadata_revision"]=json.String("3")
    testing.expect(t,!owner_publication_verified(genesis,registry,raw_genesis,"acct_1","brg_1",creator,owner,bound[:]),"owner signature still required on every update")
    // Historical binding never makes a revoked creator a command signer.
    command:json.Object
    for entry in entries {
        e:=entry.(json.Object)
        if contracts.owner_string(e,"kind")=="command" { command,_=contracts.owner_parse(contracts.owner_string(e,"raw"),"command") }
    }
    grant:=contracts.Owner_Read_Grant{"acct_1","brg_1","chain_1","dev_1","device_key","task_1","task.comment",1,1000000,true,true,false}
    testing.expect_value(t,contracts.owner_authenticate_command(command,contracts.owner_string(fixture,"payload"),creator,grant,1000),contracts.Owner_Auth_Error.Bad_Signature)
}
