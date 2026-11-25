package main

import "core:encoding/json"
import "core:os"
import "core:strings"

ctl_webhook_call :: proc(tokens,args:[]string)->(string,string,bool) {
 verb:=pos(tokens,0)
 if verb=="" do verb="list"
 switch verb {
 case "create","update","list","show","rotate","enable","disable","delete","test":
 case: return "","",false
 }
 params:=ctl_action_object()
 sample_given:=false
 secret_given:=false
 if verb!="create" && verb!="list" {
  id:=pos(tokens,1)
  if id=="" || strings.has_prefix(id,"--") do return "","",false
  params["id"]=json.String(id)
 }
 for i:=0;i<len(args);i+=1 {
  flag:=args[i]
  if !strings.has_prefix(flag,"--") do continue
  allowed:=flag=="--bridge-endpoint" || flag=="--agent-token" ||
   ((flag=="--name" || flag=="--dedupe-header") && (verb=="create" || verb=="update")) ||
   ((flag=="--token" || flag=="--token-file" || flag=="--body-file" || flag=="--data") && verb=="test")
  if !allowed || i+1>=len(args) || strings.has_prefix(args[i+1],"--") do return "","",false
  i+=1
  value:=args[i]
  switch flag {
  case "--dedupe-header": params["dedupe_header"]=json.String(value)
  case "--name": params["name"]=json.String(value)
  case "--token","--token-file":
   if secret_given do return "","",false
   secret_given=true
   secret:=value
   if flag=="--token-file" {
    bytes,err:=os.read_entire_file(value,context.temp_allocator)
    if err!=nil do return "","",false
    secret=strings.trim_space(string(bytes))
   }
   params["webhook_secret"]=json.String(secret)
  case "--body-file","--data":
   if sample_given do return "","",false
   sample_given=true
   data:=value
   if flag=="--body-file" {
    bytes,err:=os.read_entire_file(value,context.temp_allocator)
    if err!=nil do return "","",false
    data=string(bytes)
   }
   body:json.Value
   if json.unmarshal_string(data,&body,.JSON,context.temp_allocator)!=nil do return "","",false
   if _,ok:=body.(json.Object);!ok do return "","",false
   params["body"]=json.String(data)
  }
 }
 if verb=="test" {
  token,_:=params["webhook_secret"].(string)
  if token=="" do return "","",false
  if !sample_given do params["body"]=json.String("{}")
 }
 bytes,err:=json.marshal(params,allocator=context.temp_allocator)
 if err!=nil do return "","",false
 return strings.concatenate({"agent.automations.webhooks.",verb},context.temp_allocator),string(bytes),true
}

ctl_webhook_help :: proc(verb:string)->string {
 switch verb {
 case "create": return `ham-ctl automations webhooks create [--name <text>] [--dedupe-header <header>]
Create an enabled webhook for your owner. Returns webhook metadata and a token ONCE.
Dedupe header defaults to Idempotency-Key; accepts an RFC 7230 token of 1 to 64 characters.
Credential headers Authorization, Proxy-Authorization, Cookie, Set-Cookie and X-Api-Key are rejected.
Save the token now; list/show never reveal it. Name is at most 256 bytes.
Example: ham-ctl automations webhooks create --name 'CI build'`
 case "update": return `ham-ctl automations webhooks update <id> [--name <text>] [--dedupe-header <header>]
Update owned webhook metadata. Header names must be RFC 7230 tokens of 1 to 64 characters.
Credential headers Authorization, Proxy-Authorization, Cookie, Set-Cookie and X-Api-Key are rejected.
Example: ham-ctl automations webhooks update wh_1 --dedupe-header X-GitHub-Delivery`
 case "list": return `ham-ctl automations webhooks list
List your owner's webhook metadata; tokens and hashes are omitted.
Example: ham-ctl automations webhooks list`
 case "show": return `ham-ctl automations webhooks show <id>
Show owned webhook metadata, including enabled state and last receipt; no token.
Unknown or foreign ids return not found.
Example: ham-ctl automations webhooks show wh_1`
 case "rotate": return `ham-ctl automations webhooks rotate <id>
Invalidate the previous token immediately and return a new token ONCE. Save it now.
Example: ham-ctl automations webhooks rotate wh_1`
 case "enable","disable","delete":
  return strings.concatenate({"ham-ctl automations webhooks ",verb," <id>\n",
   ("Permanently delete the owned webhook and invalidate its token." if verb=="delete" else
    "Enable the owned webhook for incoming requests." if verb=="enable" else
    "Disable the owned webhook; ingress rejects requests until enabled."),
   "\nUnknown or foreign ids return not found.\nExample: ham-ctl automations webhooks ",verb," wh_1"},context.temp_allocator)
 case "test": return `ham-ctl automations webhooks test <id> (--token-file <path> | --token <webhook-token>) [--body-file <path> | --data <json>]
POST a sample JSON object (default {}) through webhook ingress after checking ownership.
Emits a real webhook.received event and can fire automations. Requires an enabled webhook
and its current token; normal ingress limits apply. Returns event_id and duplicate.
Prefer --token-file (whitespace trimmed) to keep the secret out of argv and transcripts.
An owned disabled webhook returns a clear conflict; enable it before testing.
The actor is your agent instance; data._test=true is added (overwriting any supplied _test).
Rules can exclude samples with {"not":{"field":"data._test","op":"eq","value":true}}.
This relay test does NOT exercise public networking, proxies or TLS.
Example: ham-ctl automations webhooks test wh_1 --token-file webhook.secret --body-file sample.json
Public network check: curl -X POST <bearer_url> -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' -d '{"hello":"world"}'
Or: curl -X POST <secret_url> -H 'Content-Type: application/json' -d '{"hello":"world"}'`
 }
 return `ham-ctl automations webhooks <create|update|list|show|rotate|enable|disable|delete|test>
Owner-scoped webhook management through the authenticated local bridge.
Use <verb> --help for flags and examples. Global transport flags:
--bridge-endpoint <path>, --agent-token <instance-token>.
Ingress: POST /api/v1/hooks/<id>, Authorization: Bearer <webhook-token>, application/json.
Tokens are returned only by create/rotate; never put tokens in event filters or prompts.
Example: ham-ctl automations webhooks list`
}
