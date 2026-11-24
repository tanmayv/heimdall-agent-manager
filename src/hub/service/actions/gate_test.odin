package actions

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Gate_Test_State :: struct {fail:bool, owner:string}
gate_test_rows :: proc(ctx:rawptr, owner:string) -> ([dynamic]domain.Experiment,domain.Domain_Error) {
	state:=(^Gate_Test_State)(ctx)
	state.owner=owner
	if state.fail do return nil,domain.domain_error(.Internal_Error,"read failed")
	rows:[dynamic]domain.Experiment
	if owner=="owner" {
		append(&rows,domain.Experiment{owner_user_id=strings.clone(owner),key=strings.clone("actions"),enabled=true,updated_at=strings.clone("now")})
	}
	return rows,{}
}
@(test)
test_actions_gate_fails_closed :: proc(t:^testing.T) {actions_track(t,gate_cases)}
gate_cases :: proc(t:^testing.T) {
	state:Gate_Test_State
	repo:=iface.Experiment_Repository{ctx=&state,list_by_owner=gate_test_rows}
	testing.expect(t,actions_gate_on(&repo,"owner","actions"))
	testing.expect_value(t,state.owner,"owner")
	testing.expect(t,!actions_gate_on(&repo,"owner","bots"))
	testing.expect(t,!actions_gate_on(&repo,"other","actions"))
	testing.expect(t,!actions_gate_on(&repo,"","actions"))
	state.fail=true
	testing.expect(t,!actions_gate_on(&repo,"owner","actions"))
	testing.expect(t,!actions_gate_on(nil,"owner","actions"))
}

