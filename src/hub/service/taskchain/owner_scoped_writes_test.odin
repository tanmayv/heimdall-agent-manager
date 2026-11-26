package taskchain

// REQ-AUTHZ-1/2: chain status changes and task update/cancel/hold/release/
// recheck are owner-scoped. Any agent instance of the chain's owner may perform
// them without being a member or coordinator of the chain; an instance of a
// different owner is still refused, and the non-membership guards (draft chain,
// `complete` for completion, valid transitions, lease-holder self-edit) stay.

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import taskv2 "odin_test:hub/service/taskv2"

@(private = "file")
AZ_OWNER :: "owner_authz"
@(private = "file")
AZ_FOREIGN :: "owner_authz_other"

@(private = "file")
Az_Fx :: struct {
	conn:    sqlite.Conn,
	tc_impl: sqlite.Taskchain_Repo_SQLite,
	repo:    iface.Taskchain_Repository,
	ag_impl: sqlite.Agent_Repo_SQLite,
	agents:  iface.Agent_Repository,
	clock:   platform.Clock,
	ids:     platform.ID_Generator,
	svc:     Taskchain_Service,
	engine:  taskv2.Service,
}

@(private = "file")
az_make :: proc(fx: ^Az_Fx, t: ^testing.T, name: string) -> bool {
	ok: bool
	// Authorization does not depend on disk durability; each case owns a private DB.
	fx.conn, ok, _ = sqlite.open(":memory:")
	if !testing.expect(t, ok, "open database") do return false
	mig_ok, _ := sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, mig_ok, "migrations") do return false
	fx.repo = sqlite.new_taskchain_repository(&fx.tc_impl, &fx.conn)
	fx.agents = sqlite.new_agent_repository(&fx.ag_impl, &fx.conn)
	fx.clock = platform.real_clock()
	fx.ids = platform.real_id_generator()
	fx.svc = new_taskchain_service(&fx.repo, &fx.agents, &fx.clock, &fx.ids)
	fx.engine = taskv2.new_service(&fx.repo, &fx.agents, nil, &fx.clock, &fx.ids)
	fx.svc.engine = &fx.engine
	now := platform.clock_now(&fx.clock)
	// coord: member + coordinator; outsider: same owner, no membership in any
	// chain; foreign: an instance of another owner.
	seed := [?]struct{id, owner, chain: string}{
		{"inst_coord", AZ_OWNER, "chain_authz"},
		{"inst_outsider", AZ_OWNER, "chain_elsewhere"},
		{"inst_holder", AZ_OWNER, "chain_authz"},
		{"inst_foreign", AZ_FOREIGN, ""},
	}
	for s in seed {
		_, _, _ = iface.agent_save_instance(&fx.agents, domain.Agent_Instance{agent_instance_id = s.id, owner_user_id = domain.User_ID(s.owner), agent_id = "agt_authz", chain_id = s.chain, created_at = now, updated_at = now})
	}
	return true
}

@(private = "file")
az_free :: proc(fx: ^Az_Fx) {
	sqlite.close(&fx.conn)
}

@(private = "file")
az_chain :: proc(fx: ^Az_Fx, chain_id: string, publish := domain.Publish_State.Published) -> domain.Task_Chain {
	now := platform.clock_now(&fx.clock)
	chain, _, _ := iface.taskchain_save_chain(&fx.repo, domain.Task_Chain{
		chain_id = domain.Task_Chain_ID(chain_id), owner_user_id = AZ_OWNER, title = "authz",
		publish_state = publish, status = .Active, kind = domain.CHAIN_KIND_MIXED_WORK,
		created_at = now, updated_at = now,
	})
	_, _, _ = iface.taskchain_save_member(&fx.repo, domain.Task_Chain_Member{chain_id = chain.chain_id, owner_user_id = AZ_OWNER, agent_instance_id = "inst_coord", agent_id = "agt_authz", role = "coordinator", created_at = now})
	_, _, _ = iface.taskchain_save_member(&fx.repo, domain.Task_Chain_Member{chain_id = chain.chain_id, owner_user_id = AZ_OWNER, agent_instance_id = "inst_holder", agent_id = "agt_authz", role = "worker", created_at = now})
	return chain
}

@(private = "file")
az_task :: proc(fx: ^Az_Fx, chain_id: string, task_id: string) -> domain.Task {
	task := domain.Task{task_id = domain.Task_ID(task_id), chain_id = domain.Task_Chain_ID(chain_id), owner_user_id = AZ_OWNER,
		title = "authz task", kind = .Task, publish_state = .Published, state = .Ready,
		brief_json = `{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`}
	_, _, _ = iface.taskchain_save_task(&fx.repo, task)
	_, _, _ = iface.taskchain_append_event(&fx.repo, domain.Task_Event{task_id = task.task_id, chain_id = task.chain_id,
		owner_user_id = AZ_OWNER, kind = taskv2.EV_MIGRATED, payload_json = `{"state":"ready","published":true}`})
	return task
}

@(private = "file")
az_instance :: proc(id: string, owner := AZ_OWNER) -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = owner, agent_instance_id = id}
}

@(test)
test_authz_non_member_same_owner_changes_chain_status :: proc(t: ^testing.T) {
	fx: Az_Fx
	if !az_make(&fx, t, "status") do return
	defer az_free(&fx)
	chain := az_chain(&fx, "chain_authz")
	outsider := az_instance("inst_outsider")
	testing.expect(t, !is_instance_member_or_coordinator(&fx.svc, chain, "inst_outsider"), "fixture: outsider is not a member")

	// Cross-owner: an instance of another owner is refused and nothing changes.
	_, fok, ferr := change_chain_status(&fx.svc, az_instance("inst_foreign", AZ_FOREIGN), chain.chain_id, .Cancelled)
	testing.expectf(t, !fok && (ferr.code == .Not_Found || ferr.code == .Forbidden), "foreign instance refused: %v %s", ferr.code, ferr.message)
	// Completion still goes through `complete`.
	_, cok, cerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Completed)
	testing.expect(t, !cok && cerr.code == .Validation_Failed, "completed still requires complete")
	after, _, _ := iface.taskchain_get_chain(&fx.repo, chain.chain_id)
	testing.expect_value(t, after.status, domain.Task_Chain_Status.Active)

	// archive -> unarchive -> cancel, all by a same-owner non-member.
	archived, aok, aerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Archived)
	testing.expectf(t, aok, "non-member archives: %s", aerr.message)
	testing.expect_value(t, archived.status, domain.Task_Chain_Status.Archived)
	active, uok, uerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Active)
	testing.expectf(t, uok, "non-member unarchives: %s", uerr.message)
	testing.expect_value(t, active.status, domain.Task_Chain_Status.Active)
	cancelled, xok, xerr := change_chain_status(&fx.svc, outsider, chain.chain_id, .Cancelled)
	testing.expectf(t, xok, "non-member cancels: %s", xerr.message)
	testing.expect_value(t, cancelled.status, domain.Task_Chain_Status.Cancelled)

	// Draft chains still have no execution status, whoever asks.
	draft := az_chain(&fx, "chain_authz_draft", .Draft)
	_, dok, derr := change_chain_status(&fx.svc, outsider, draft.chain_id, .Cancelled)
	testing.expect(t, !dok && derr.code == .Conflict, "draft chain guard unchanged")
}

@(test)
test_authz_non_member_same_owner_updates_and_cancels_task :: proc(t: ^testing.T) {
	fx: Az_Fx
	if !az_make(&fx, t, "task") do return
	defer az_free(&fx)
	chain := az_chain(&fx, "chain_authz")
	task := az_task(&fx, string(chain.chain_id), "task_authz_cancel")
	outsider := az_instance("inst_outsider")
	stranger := az_instance("inst_foreign", AZ_FOREIGN)

	// update: foreign refused, same-owner non-member accepted.
	_, fu_ok, fu_err := update_task(&fx.svc, stranger, task.task_id, Update_Task_Input{priority = .P0, has_priority = true})
	testing.expectf(t, !fu_ok && (fu_err.code == .Not_Found || fu_err.code == .Forbidden), "foreign update refused: %v", fu_err.code)
	updated, u_ok, u_err := update_task(&fx.svc, outsider, task.task_id, Update_Task_Input{priority = .P0, has_priority = true})
	testing.expectf(t, u_ok, "non-member updates task: %s", u_err.message)
	testing.expect_value(t, updated.priority, domain.Task_Priority.P0)

	// hold / release / recheck through the engine with the non-member actor.
	actor := engine_actor(outsider)
	_, h_ok, h_err := taskv2.task_hold(&fx.engine, updated, actor, "pause for re-plan")
	testing.expectf(t, h_ok, "non-member holds: %s", h_err.message)
	held, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	_, r_ok, r_err := taskv2.task_release(&fx.engine, held, actor)
	testing.expectf(t, r_ok, "non-member releases: %s", r_err.message)
	released, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	_, rc_ok, rc_err := taskv2.task_recheck(&fx.engine, released, actor)
	testing.expectf(t, rc_ok, "non-member rechecks: %s", rc_err.message)
	_, fh_ok, fh_err := taskv2.task_hold(&fx.engine, released, engine_actor(stranger), "nope")
	testing.expect(t, !fh_ok && fh_err.code == .Forbidden, "foreign instance cannot hold")

	// cancel: foreign refused (task stays), same-owner non-member cancels.
	_, fc_ok, fc_err := cancel_task(&fx.svc, stranger, task.task_id, "not yours")
	testing.expectf(t, !fc_ok && (fc_err.code == .Not_Found || fc_err.code == .Forbidden), "foreign cancel refused: %v", fc_err.code)
	still, _, _ := iface.taskchain_get_task(&fx.repo, task.task_id)
	testing.expect(t, still.state != .Cancelled, "foreign cancel changed nothing")
	cancelled, c_ok, c_err := cancel_task(&fx.svc, outsider, task.task_id, "obsolete")
	testing.expectf(t, c_ok, "non-member cancels task: %s", c_err.message)
	testing.expect_value(t, cancelled.state, domain.Task_State.Cancelled)

	// The native v2 cancel verb (POST .../cancel) authorizes the same way.
	v2 := az_task(&fx, string(chain.chain_id), "task_authz_v2_cancel")
	_, v2f_ok, v2f_err := taskv2.task_cancel(&fx.engine, v2, engine_actor(stranger), taskv2.Task_Cancel_Input{reason = "x", request_id = "req_f", expected_generation = 0})
	testing.expect(t, !v2f_ok && v2f_err.code == .Forbidden, "foreign actor refused by v2 cancel")
	res, v2_ok, v2_err := taskv2.task_cancel(&fx.engine, v2, actor, taskv2.Task_Cancel_Input{reason = "obsolete", request_id = "req_o", expected_generation = 0})
	testing.expectf(t, v2_ok, "non-member v2 cancel: %s", v2_err.message)
	testing.expect_value(t, res.task.state, domain.Task_State.Cancelled)
}

@(test)
test_authz_lease_holder_still_cannot_update_its_own_task :: proc(t: ^testing.T) {
	fx: Az_Fx
	if !az_make(&fx, t, "holder") do return
	defer az_free(&fx)
	chain := az_chain(&fx, "chain_authz")
	task := az_task(&fx, string(chain.chain_id), "task_authz_held")
	now := platform.clock_now(&fx.clock)
	_, lok, lerr := iface.taskchain_save_lease(&fx.repo, domain.Task_Lease{lease_id = "lease_authz", task_id = task.task_id, chain_id = chain.chain_id, owner_user_id = AZ_OWNER, holder_instance_id = "inst_holder", attempt_no = 1, kind = domain.LEASE_KIND_WORK, delivery = "inline", granted_at = now, confirmed_at = now})
	if !testing.expectf(t, lok, "seed lease: %s", lerr.message) do return
	_, hok, herr := update_task(&fx.svc, az_instance("inst_holder"), task.task_id, Update_Task_Input{brief_json = `{"acceptance":["weaker"]}`})
	testing.expect(t, !hok && herr.code == .Forbidden, "holder cannot rewrite the task it holds")
	_, ook, oerr := update_task(&fx.svc, az_instance("inst_outsider"), task.task_id, Update_Task_Input{brief_json = `{"acceptance":["corrected"]}`})
	testing.expectf(t, ook, "another same-owner instance may correct acceptance: %s", oerr.message)
}

@(private = "file")
az_wire_uow :: proc(fx: ^Az_Fx, repos: ^iface.Repositories, impl: ^sqlite.SQLite_Unit_Of_Work_Factory, factory: ^iface.Unit_Of_Work_Factory) {
	repos.taskchains=fx.repo
	repos.agents=fx.agents
	factory^=sqlite.new_unit_of_work_factory(impl,&fx.conn,repos)
	fx.svc.uow_factory=factory
	fx.engine.uow_factory=factory
}

@(test)
test_cross_chain_publication_metadata_fleet_and_advertisement :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	fx: Az_Fx
	if !az_make(&fx,t,"orchestration") do return
	defer az_free(&fx)
	repos:iface.Repositories
	impl:sqlite.SQLite_Unit_Of_Work_Factory
	factory:iface.Unit_Of_Work_Factory
	az_wire_uow(&fx,&repos,&impl,&factory)
	outsider:=az_instance("inst_outsider")
	chain:=az_chain(&fx,"chain_authz",.Draft)
	task:=az_task(&fx,string(chain.chain_id),"draft_task")
	task.publish_state=.Draft
	task.brief_json=`{"goal":"g","acceptance":["a"]}`
	_,_,_=iface.taskchain_save_task(&fx.repo,task)

	// Valid same-owner outsiders reach validation; rejected publication is atomic.
	_,published,perr:=publish_chain(&fx.svc,outsider,chain.chain_id)
	testing.expect(t,!published && perr.code==.Validation_Failed,"missing assignee still blocks chain publish")
	stored,_,_:=iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	unchanged,_,_:=iface.taskchain_get_task(&fx.repo,task.task_id)
	testing.expect(t,stored.publish_state==.Draft && unchanged.publish_state==.Draft,"failed publish leaves chain and task drafts")
	task.brief_json=`{"goal":"g","acceptance":["a"],"assignee":"agt_w"}`
	_,_,_=iface.taskchain_save_task(&fx.repo,task)
	published_chain: domain.Task_Chain
	published_chain,published,perr=publish_chain(&fx.svc,outsider,chain.chain_id)
	testing.expect(t,published,perr.message)
	testing.expect_value(t,published_chain.publish_state,domain.Publish_State.Published)
	cascaded,_,_:=iface.taskchain_get_task(&fx.repo,task.task_id)
	testing.expect_value(t,cascaded.publish_state,domain.Publish_State.Published)
	_,again,aerr:=publish_chain(&fx.svc,outsider,chain.chain_id)
	testing.expect(t,!again && aerr.code==.Conflict,"published-chain guard unchanged")

	draft:=az_task(&fx,string(chain.chain_id),"individual_draft")
	draft.publish_state=.Draft
	_,_,_=iface.taskchain_save_task(&fx.repo,draft)
	actions,acterr:=task_control_actions(&fx.svc,outsider,draft)
	advertised:=false
	for action in actions do if action=="publish" do advertised=true
	testing.expect(t,acterr.code==.None && advertised,"outsider is advertised the executable publish control")
	_,individual,ierr:=publish_task(&fx.svc,outsider,draft.task_id)
	testing.expect(t,individual,ierr.message)

	renamed,rok,rerr:=set_own_chain_title(&fx.svc,outsider,string(chain.chain_id),"Renamed across chains")
	testing.expect(t,rok && renamed.title=="Renamed across chains" && renamed.title_source=="agent",rerr.message)
	described,dok,derr:=set_own_chain_description(&fx.svc,outsider,string(chain.chain_id),"New description")
	testing.expect(t,dok && described.description=="New description",derr.message)
	_,coordinated,coerr:=update_chain(&fx.svc,outsider,chain.chain_id,Update_Chain_Input{has_coordinator=true,coordinator_agent_instance_id="inst_holder",title="must not persist"})
	testing.expect(t,!coordinated && coerr.code==.Forbidden,"metadata access cannot change coordinator")
	persisted,_,_:=iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	testing.expect_value(t,persisted.title,"Renamed across chains")
	testing.expect(t,!is_chain_coordinator(&fx.svc,persisted,"inst_outsider"),"outsider remains noncoordinator")

	dir,added,direrr:=add_chain_directory(&fx.svc,outsider,Add_Directory_Input{chain_id=chain.chain_id,path="/isolated/repo"})
	if testing.expect(t,added,direrr.message) {
		moved,mok,merr:=update_chain_directory(&fx.svc,outsider,Update_Directory_Input{chain_id=chain.chain_id,directory_id=dir.directory_id,path="/isolated/renamed",has_path=true})
		testing.expect(t,mok && moved.path=="/isolated/renamed",merr.message)
		removed,remerr:=remove_chain_directory(&fx.svc,outsider,chain.chain_id,dir.directory_id)
		testing.expect(t,removed,remerr.message)
	}

	_,_,_=iface.agent_save(&fx.agents,domain.Agent{agent_id="agt_authz",owner_user_id=AZ_OWNER,name="Worker",slug="authz"})
	_,_,_=iface.agent_save(&fx.agents,domain.Agent{agent_id="agt_foreign",owner_user_id=AZ_FOREIGN,name="Foreign",slug="foreign"})
	for id in ([]string{"agt_foreign","agt_unknown"}) {
		_,referr:=upsert_fleet(&fx.svc,outsider,Upsert_Fleet_Input{chain_id=chain.chain_id,agent_id=id,capacity=1})
		testing.expect(t,referr.code==.Not_Found,"same-owner actor cannot reference a foreign or unknown fleet agent")
	}
	row,ferr:=upsert_fleet(&fx.svc,outsider,Upsert_Fleet_Input{chain_id=chain.chain_id,agent_id="agt_authz",capacity=1})
	testing.expect(t,ferr.code==.None,ferr.message)
	_,badcap:=upsert_fleet(&fx.svc,outsider,Upsert_Fleet_Input{chain_id=chain.chain_id,agent_id="agt_authz",capacity=0})
	testing.expect(t,badcap.code==.Validation_Failed,"fleet capacity still validated")
	_,badrole:=set_fleet_pause(&fx.svc,outsider,Fleet_Pause_Input{chain_id=chain.chain_id,agent_id=row.agent_id,roles=[]string{"nonexistent"},paused=true})
	testing.expect(t,badrole.code==.Validation_Failed,"per-role pause refused")
	paused,pauseerr:=set_fleet_pause(&fx.svc,outsider,Fleet_Pause_Input{chain_id=chain.chain_id,agent_id=row.agent_id,paused=true})
	testing.expect(t,pauseerr.code==.None && paused.paused,"outsider pauses fleet")
	resumed,reserr:=set_fleet_pause(&fx.svc,outsider,Fleet_Pause_Input{chain_id=chain.chain_id,agent_id=row.agent_id,paused=false})
	testing.expect(t,reserr.code==.None && !resumed.paused,"outsider resumes fleet")
	deleted,delerr:=delete_fleet(&fx.svc,outsider,chain.chain_id,row.agent_id)
	testing.expect(t,deleted,delerr.message)
}

@(test)
test_cross_chain_invalid_actors_leave_metadata_publication_and_fleet_unchanged :: proc(t: ^testing.T) {
	context.allocator=context.temp_allocator
	fx: Az_Fx
	if !az_make(&fx,t,"denials") do return
	defer az_free(&fx)
	chain:=az_chain(&fx,"chain_authz",.Draft)
	task:=az_task(&fx,string(chain.chain_id),"draft_denied")
	task.publish_state=.Draft
	_,_,_=iface.taskchain_save_task(&fx.repo,task)
	chain,_,_=iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	for auth in ([]contracts.Auth_Context{
		az_instance("inst_foreign",AZ_FOREIGN),az_instance("missing"),az_instance(""),
		az_instance("inst_foreign"),{kind=.None,user_id=AZ_OWNER},
		{kind=.Bridge_Token,user_id=AZ_OWNER},
	}) {
		_,changed,err:=update_chain(&fx.svc,auth,chain.chain_id,Update_Chain_Input{title="forged"})
		testing.expect(t,!changed && err.code!=.None,"invalid metadata actor denied")
		_,published,perr:=publish_chain(&fx.svc,auth,chain.chain_id)
		testing.expect(t,!published && perr.code!=.None,"invalid chain publisher denied")
		_,tpublished,terr:=publish_task(&fx.svc,auth,task.task_id)
		testing.expect(t,!tpublished && terr.code!=.None,"invalid task publisher denied")
		_,ferr:=upsert_fleet(&fx.svc,auth,Upsert_Fleet_Input{chain_id=chain.chain_id,agent_id="agt_authz",capacity=1})
		testing.expect(t,ferr.code!=.None,"invalid fleet actor denied")
		_,added,derr:=add_chain_directory(&fx.svc,auth,Add_Directory_Input{chain_id=chain.chain_id,path="/forged"})
		testing.expect(t,!added && derr.code!=.None,"invalid directory actor denied")
		_,completed,cerr:=complete_chain(&fx.svc,auth,chain.chain_id,chain.work_revision,"forged")
		testing.expect(t,!completed && cerr.code!=.None,"invalid completion actor denied")
	}
	persisted,_,_:=iface.taskchain_get_chain(&fx.repo,chain.chain_id)
	draft,_,_:=iface.taskchain_get_task(&fx.repo,task.task_id)
	fleets,_:=iface.taskchain_list_fleets_by_chain(&fx.repo,chain.chain_id,chain.owner_user_id)
	dirs,_:=iface.taskchain_list_directories_by_chain(&fx.repo,chain.chain_id,chain.owner_user_id)
	testing.expect(t,persisted.title==chain.title && persisted.publish_state==.Draft && persisted.work_revision==chain.work_revision,"denials preserve chain")
	testing.expect(t,draft.publish_state==.Draft && len(fleets)==0 && len(dirs)==0,"denials preserve draft and referenced resources")
}
