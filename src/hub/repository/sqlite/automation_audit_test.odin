package sqlite
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_automation_audit_upgrade_preserves_existing_rows :: proc(t:^testing.T) {
 db,opened,_:=open(":memory:")
 if !testing.expect(t,opened) do return
 defer close(&db)
 before,_:=run_migrations(&db,stop_before="actions_010_agent_automation_audit.sql")
 if !testing.expect(t,before) do return
 testing.expect(t,exec(&db,`INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,target_instance_id,created_at,updated_at) VALUES('act_existing','owner','keep','instance','inst_target','2026-11-01T00:00:00Z','2026-11-01T00:00:00Z');`))
 upgraded,e:=run_migrations(&db)
 if !testing.expect(t,upgraded && e.code==.None) do return
 impl:Action_Repo_SQLite
 repo:=new_action_repository(&impl,&db)
 v,found,err:=repo.get(repo.ctx,"act_existing")
 defer domain.action_destroy(&v)
 if !testing.expect(t,found && err.code==.None) do return
 testing.expect_value(t,v.prompt_text,"keep")
 testing.expect_value(t,v.created_by,"")
 testing.expect_value(t,v.updated_by,"")
 // A second migration pass must not reset content or re-add audit columns.
 again,ae:=run_migrations(&db)
 testing.expect(t,again && ae.code==.None)
}
