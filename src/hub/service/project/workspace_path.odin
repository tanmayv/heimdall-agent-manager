package project

import "core:fmt"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Workspace preflight checks ownership before sending a host-local path.
validate_workspace_path :: proc(bridges: ^iface.Bridge_Repository, sink: Bridge_Command_Sink, ids: ^platform.ID_Generator, owner: domain.User_ID, bridge_id, path, vcs_kind: string) -> domain.Domain_Error {
	if bridges == nil do return domain.domain_error(.Internal_Error, "bridge store unavailable")
	bridge, found, err := iface.bridge_get_bridge(bridges, bridge_id)
	if err.code != .None do return err
	if !found || bridge.owner_user_id != owner do return domain.domain_error(.Not_Found, "bridge not found")
	if bridge.status == .Revoked || bridge.revoked_at != "" do return domain.domain_error(.Bridge_Revoked, "workspace bridge is revoked")
	if bridge.enrollment_pending_until != "" || bridge.plan_disabled_at != "" do return domain.domain_error(.Validation_Failed, "workspace bridge is not eligible")
	if bridge.status != .Online do return domain.domain_error(.Bridge_Offline, "workspace bridge is offline")
	result, received, validation_err := bridge_command_validate_project_path(sink, {
		type = "validate_project_path",
		command_id = platform.generate_id(ids, "cmd_workspace_"),
		bridge_id = bridge_id,
		path = path,
		vcs_kind = vcs_kind,
	})
	if !received {
		if validation_err.code != .None do return validation_err
		return domain.domain_error(.Bridge_Offline, "workspace validation did not receive a bridge reply")
	}
	if !result.ok {
		message := result.validation_error if result.validation_error != "" else "path validation failed"
		return domain.domain_error(.Validation_Failed, fmt.tprintf("workspace path could not be validated on the selected bridge: %s", message))
	}
	return {}
}
