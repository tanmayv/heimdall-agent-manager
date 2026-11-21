package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import content_service "odin_test:hub/service/content"

// REQ-VOICE-5: an agent-created audio artifact stores kind audio and the media
// type as both content_type and mime; chat message rows that attach it describe
// it as {artifact_id, kind, mime} and flag ids that do not resolve.
@(test)
test_agent_audio_artifact_kind_mime_and_message_descriptors :: proc(t:^testing.T) {
	context.allocator=context.temp_allocator
	f:=wire_setup(t,"artifact-audio");defer wire_teardown(f)
	impl:sqlite.Content_Repo_SQLite;repo:=sqlite.new_content_repository(&impl,&f.conn)
	svc:=content_service.new_content_service(&repo,&f.ag_repo,&f.br_repo,nil,&f.tc_repo,&f.clock,&f.ids);f.ah.content=&svc
	_,agent_saved,_:=iface.agent_save(&f.ag_repo,domain.Agent{agent_id="agt_wire_tb2",owner_user_id=f.owner,name="Worker",slug="audio-worker"});testing.expect(t,agent_saved)
	body:=strings.clone(`{"agent_instance_id":"inst_wire_tb2","params":{"name":"vault:v2:sealed-name","kind":"audio","content_type":"audio/ogg","content_base64":"T2dnUw=="}}`,context.temp_allocator)
	response:=agent_action_artifact_create_handler(&f.ah,wire_agent_request(f,"artifact/create",body))
	if !testing.expect_value(t,response.status,201) do return
	wire:struct {data:struct {artifact_id,kind,content_type,mime:string}}
	testing.expect(t,json.unmarshal_string(response.body,&wire,.JSON,context.temp_allocator)==nil)
	testing.expect_value(t,wire.data.kind,"audio")
	testing.expect_value(t,wire.data.content_type,"audio/ogg")
	testing.expect_value(t,wire.data.mime,"audio/ogg")
	row,found,_:=iface.content_get_artifact(&repo,wire.data.artifact_id)
	testing.expect(t,found && row.kind=="audio" && row.mime=="audio/ogg" && row.content_type=="audio/ogg")

	show:=agent_action_artifact_show_handler(&f.ah,wire_agent_request(f,"artifact/show",strings.concatenate({`{"agent_instance_id":"inst_wire_tb2","params":{"artifact_id":"`,wire.data.artifact_id,`"}}`})))
	testing.expect_value(t,show.status,200)
	testing.expect(t,strings.contains(show.body,`"kind":"audio"`) && strings.contains(show.body,`"mime":"audio/ogg"`))

	msg:=domain.Chat_Message{message_id="msg_voice",owner_user_id=f.owner,direction="user_to_agent",body="listen",artifact_ids_json=strings.concatenate({`["`,wire.data.artifact_id,`","art_missing"]`})}
	b:=strings.builder_make()
	write_message_json(&b,msg,&svc)
	out:=strings.to_string(b)
	parsed:struct {body:string, artifacts:[]struct {artifact_id,kind,mime:string, available:bool}}
	if !testing.expect(t,json.unmarshal_string(out,&parsed,.JSON,context.temp_allocator)==nil,out) do return
	if !testing.expect_value(t,len(parsed.artifacts),2) do return
	testing.expect_value(t,parsed.artifacts[0].artifact_id,wire.data.artifact_id)
	testing.expect_value(t,parsed.artifacts[0].kind,"audio")
	testing.expect_value(t,parsed.artifacts[0].mime,"audio/ogg")
	testing.expect(t,parsed.artifacts[0].available)
	testing.expect_value(t,parsed.artifacts[1].artifact_id,"art_missing")
	testing.expect(t,!parsed.artifacts[1].available)
	testing.expect(t,strings.contains(parsed.body,"[artifact unavailable/deleted]"),"missing attachment keeps the unavailable marker")

	plain:=strings.builder_make()
	write_message_json(&plain,domain.Chat_Message{message_id="msg_plain",owner_user_id=f.owner,body="hi"},&svc)
	testing.expect(t,strings.contains(strings.to_string(plain),`"artifact_ids":[],"artifacts":[]`))
}
