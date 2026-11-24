package actions
import "core:testing"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_automation_actor_and_owner_limit :: proc(t:^testing.T) {actions_track(t,automation_actor_case)}
automation_actor_case :: proc(t:^testing.T) {service_case(t,automation_actor_scenario)}
automation_actor_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
 s.max_per_owner=1
 testing.expect_value(t,trigger_types(s).limits.max_automations_per_owner,1)
 v,e:=create(s,"owner",test_input(),"inst_creator")
 defer action_view_destroy(&v)
 if !testing.expect_value(t,e.code,domain.Error_Code.None) do return
 testing.expect_value(t,v.action.created_by,"inst_creator")
 testing.expect_value(t,v.action.updated_by,"inst_creator")
 updated,ue:=update(s,"owner",string(v.action.id),{enabled=false},"inst_editor")
 defer action_view_destroy(&updated)
 testing.expect_value(t,ue.code,domain.Error_Code.None)
 testing.expect_value(t,updated.action.created_by,"inst_creator")
 testing.expect_value(t,updated.action.updated_by,"inst_editor")
 denied,de:=create(s,"owner",test_input(),"inst_creator")
 defer action_view_destroy(&denied)
 testing.expect_value(t,de.code,domain.Error_Code.Conflict)
 other_view,fe:=update(s,"other",string(v.action.id),{enabled=true},"inst_other")
 defer action_view_destroy(&other_view)
 testing.expect_value(t,fe.code,domain.Error_Code.Not_Found)
 testing.expect_value(t,delete_action(s,"other",string(v.action.id)).code,domain.Error_Code.Not_Found)
 testing.expect_value(t,delete_action(s,"owner",string(v.action.id)).code,domain.Error_Code.None)
 again,ae:=create(s,"owner",test_input(),"inst_creator")
 defer action_view_destroy(&again)
 testing.expect_value(t,ae.code,domain.Error_Code.None)
}
