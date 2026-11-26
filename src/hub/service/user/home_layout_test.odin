package user

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Home_Layout_Probe :: struct { reads, writes: int }
home_layout_probe_read :: proc(ctx: rawptr, owner: domain.User_ID) -> (domain.Home_Layout_Record, bool, domain.Domain_Error) {
	probe := (^Home_Layout_Probe)(ctx)
	probe.reads += 1
	return {}, false, {}
}
home_layout_probe_write :: proc(ctx: rawptr, owner: domain.User_ID, expected: i64, payload: string) -> (bool, domain.Domain_Error) {
	probe := (^Home_Layout_Probe)(ctx)
	probe.writes += 1
	return true, {}
}

@(test)
test_home_layout_service_fences_before_storage :: proc(t: ^testing.T) {
	probe: Home_Layout_Probe
	repo := iface.User_Repository{ctx = &probe, home_layout_get = home_layout_probe_read, home_layout_cas = home_layout_probe_write}
	service := new_user_service_basic(&repo, nil, nil)
	for kind in ([]contracts.Auth_Kind{.None, .Bridge_Token, .Enrollment_Token, .Instance_Token}) {
		auth := contracts.Auth_Context{kind = kind, user_id = "owner"}
		_, err := get_home_layout(&service, auth, "owner")
		testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
		_, err = put_home_layout(&service, auth, "owner", 0, `{"version":0,"widgets":[]}`)
		testing.expect_value(t, err.code, domain.Error_Code.Forbidden)
	}
	auth := contracts.Auth_Context{kind = .Session, user_id = "owner"}
	_, err := get_home_layout(&service, auth, "")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	_, err = put_home_layout(&service, auth, "", 0, `{"version":0,"widgets":[]}`)
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	_, err = get_home_layout(&service, auth, "other")
	testing.expect_value(t, err.code, domain.Error_Code.Account_Mismatch)
	_, err = put_home_layout(&service, auth, "other", 0, `{"version":0,"widgets":[]}`)
	testing.expect_value(t, err.code, domain.Error_Code.Account_Mismatch)
	testing.expect_value(t, probe.reads, 0)
	testing.expect_value(t, probe.writes, 0)
	layout: domain.Home_Layout
	layout, err = get_home_layout(&service, auth, "owner")
	testing.expect(t, err.code == .None && layout.version == 0 && len(layout.widgets) == 4)
	testing.expect_value(t, probe.reads, 1)
	testing.expect_value(t, probe.writes, 0)
	_, err = put_home_layout(&service, auth, "owner", 1, `{"version":0,"widgets":[]}`)
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	_, err = put_home_layout(&service, auth, "owner", domain.HOME_LAYOUT_MAX_VERSION, `{"version":0,"widgets":[]}`)
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	_, err = put_home_layout(&service, auth, "owner", -1, `{"version":0,"widgets":[]}`)
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, probe.writes, 0)
}
