package mcp

import "core:crypto"
import "core:encoding/json"
import "core:strings"
import vault "odin_test:lib/vault"

// Hosted transforms fail closed. Unlike a locked interactive UI, they never
// forward a ciphertext placeholder as though it were a successfully read result.
hosted_text :: proc(kr:^vault.Vault_Keyring,text:string)->(string,bool) {
	if kr==nil do return "",false
	if vault.is_armored(text) {
		plain,result:=vault.open(text,kr,context.temp_allocator)
		return plain,result==.Ok
	}
	if !strings.contains(text,vault.VAULT_V2_PREFIX) do return strings.clone(text,context.temp_allocator),true
	pos:=0
	b:strings.Builder
	strings.builder_init(&b,context.temp_allocator)
	completed:=false
	defer if !completed {
		partial:=strings.to_string(b)
		if partial!="" do crypto.zero_explicit(raw_data(partial),len(partial))
	}
	for pos<len(text) {
		start,end:=vault.next_token(text,pos)
		if start<0 {
			if strings.contains(text[pos:],vault.VAULT_V2_PREFIX) do return "",false
			strings.write_string(&b,text[pos:]);break
		}
		if strings.contains(text[pos:start],vault.VAULT_V2_PREFIX) do return "",false
		strings.write_string(&b,text[pos:start])
		plain,result:=vault.open(text[start:end],kr,context.temp_allocator)
		if result!=.Ok do return "",false
		strings.write_string(&b,plain)
		if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain))
		pos=end
	}
	completed=true
	return strings.to_string(b),true
}

Hosted_Record_Kind :: enum {Chain,Task,Comment}
// Return a request-owned JSON encoding. Callers must wipe it after forwarding or
// on any discarded-result path; never cache it. Input metadata is not mutated.
hosted_record_json :: proc(kr:^vault.Vault_Keyring,kind:Hosted_Record_Kind,record:json.Object)->(string,bool) {
	if kr==nil || !vault.keyring_validate(kr) do return "",false
	for key in ([]string{"owner_user_id","ownerUserId"}) {
		value,present:=record[key]
		if !present do continue
		owner,valid:=value.(json.String)
		if !valid || string(owner)!=vault.keyring_user_id(kr) do return "",false
	}
	out:=make(json.Object,context.temp_allocator)
	// Match the local four-tool POC's projection; never return full task briefs,
	// handoff/facet blobs or other nested encrypted business records by accident.
	allowed:=[]string{"chain_id","title","description","status","kind","work_revision","task_count","completed_task_count","user_validation_count","created_at","updated_at"}
	if kind==.Task do allowed=[]string{"task_id","title","description","state","kind","attempt_no","requires_user_approval","reviews","updated_at"}
	if kind==.Comment do allowed=[]string{"comment_id","body","created_at"}
	for key in allowed do if value,present:=record[key];present do out[key]=value
	opened:=make([dynamic]string,context.temp_allocator)
	defer for plain in opened do if plain!="" do crypto.zero_explicit(raw_data(plain),len(plain))
	fields:=[]string{"title","description"}
	if kind==.Comment do fields=[]string{"body"}
	for key in fields {
		value,exists:=out[key]
		if !exists || value==nil do continue
		text,is_text:=value.(json.String)
		if !is_text do return "",false
		plain,ok:=hosted_text(kr,string(text))
		if !ok do return "",false
		append(&opened,plain);out[key]=json.String(plain)
	}
	data,err:=json.marshal(out,allocator=context.temp_allocator)
	if err==nil && strings.contains(string(data),vault.VAULT_V2_PREFIX) {
		crypto.zero_explicit(raw_data(data),len(data))
		return "",false
	}
	return string(data),err==nil
}

// Creation always encrypts these fields under this request's VERIFIED current
// epoch. No global vault session and no plaintext fallback exist in the Hub.
hosted_seal_chain :: proc(kr:^vault.Vault_Keyring,title,description:string)->(sealed_title,sealed_description:string,ok:bool) {
	if kr==nil || !vault.keyring_validate(kr) do return "","",false
	t,tok:=vault.seal_string(title,kr,context.temp_allocator)
	if !tok do return "","",false
	d,dok:=vault.seal_string(description,kr,context.temp_allocator)
	if !dok do return "","",false
	return t,d,true
}
