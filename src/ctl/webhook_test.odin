package main
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_ctl_webhook_verbs :: proc(t:^testing.T) {
 ctl_actions_test_tracked(t,proc(t:^testing.T) {
  for verb in ([]string{"create","update","list","show","rotate","enable","disable","delete","test"}) {
   args:[]string
   if verb=="test" do args={"--token","whsec_sample"}
   method,params,ok:=ctl_automation_call({"webhooks",verb,"wh_1"},args)
   testing.expect(t,ok,verb)
   testing.expect_value(t,method,strings.concatenate({"agent.automations.webhooks.",verb},context.temp_allocator))
   testing.expect(t,strings.contains(ctl_webhook_help(verb),"Example:"),verb)
   if verb!="create" && verb!="list" do testing.expect(t,strings.contains(params,"wh_1"))
   if verb!="create" && verb!="list" {
    _,_,valid:=ctl_webhook_call({verb},args);testing.expect(t,!valid,verb)
   }
   _,_,valid:=ctl_webhook_call({verb,"wh_1"},{"--unexpected","x"});testing.expect(t,!valid,verb)
  }
  _,params,ok:=ctl_webhook_call({"create"},{"--name","CI"})
  testing.expect(t,ok);testing.expect(t,strings.contains(params,`"name":"CI"`))
  _,_,ok=ctl_webhook_call({"test","wh_1"},nil);testing.expect(t,!ok)
  _,_,ok=ctl_webhook_call({"delete","wh_1"},{"--name","CI"});testing.expect(t,!ok)
  _,params,ok=ctl_webhook_call({"update","wh_1"},{"--dedupe-header","X-GitHub-Delivery"})
  testing.expect(t,ok);testing.expect(t,strings.contains(params,`"dedupe_header":"X-GitHub-Delivery"`))
  _,params,ok=ctl_webhook_call({"test","wh_1"},{"--token","secret","--data",`{"token":"payload-value"}`})
  testing.expect(t,ok)
  testing.expect(t,strings.contains(params,"webhook_secret"))
  testing.expect(t,!strings.contains(params,`"token"`),"sample keys remain encoded through agent auth")
  _,_,ok=ctl_webhook_call({"test","wh_1"},{"--token","secret","--data","{}","--body-file","unused"});testing.expect(t,!ok)
 })
}
@(test)
test_ctl_webhook_sample_file :: proc(t:^testing.T) {
 ctl_actions_test_tracked(t,proc(t:^testing.T) {
  path:=fmt.tprintf("%s/.cache/heimdall-tests/webhook-sample-%d.json",os.get_env_alloc("HOME",context.temp_allocator),os.get_pid())
  if !testing.expect(t,os.write_entire_file(path,string(`{"build":"passed"}`))==nil) do return
  defer os.remove(path)
  _,params,ok:=ctl_webhook_call({"test","wh_1"},{"--token","whsec_example","--body-file",path})
  testing.expect(t,ok)
  parsed,valid:=ctl_parse_json_document(params)
  testing.expect(t,valid)
  sample:=parsed.(json.Object)["body"].(string)
  decoded,good:=ctl_parse_json_document(sample)
  testing.expect(t,good)
  body:=decoded.(json.Object)
  testing.expect_value(t,body["build"].(string),"passed")
  testing.expect(t,os.write_entire_file(path,string(`[]`))==nil)
  _,_,ok=ctl_webhook_call({"test","wh_1"},{"--token","secret","--body-file",path});testing.expect(t,!ok)
  testing.expect(t,os.write_entire_file(path,string("  whsec_from_file\n"))==nil)
  _,params,ok=ctl_webhook_call({"test","wh_1"},{"--token-file",path})
  testing.expect(t,ok)
  parsed,valid=ctl_parse_json_document(params)
  testing.expect(t,valid)
  testing.expect_value(t,parsed.(json.Object)["webhook_secret"].(string),"whsec_from_file")
  _,_,ok=ctl_webhook_call({"test","wh_1"},{"--token","secret","--token-file",path});testing.expect(t,!ok)
  testing.expect(t,os.write_entire_file(path,string(" \n"))==nil)
  _,_,ok=ctl_webhook_call({"test","wh_1"},{"--token-file",path});testing.expect(t,!ok)
 })
}
