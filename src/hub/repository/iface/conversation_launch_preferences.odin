package iface
import domain "odin_test:hub/domain"
Launch_Preferences_Get_Proc :: proc(ctx: rawptr, owner: string) -> (string, domain.Domain_Error)
Launch_Preferences_Save_Proc :: proc(ctx: rawptr, owner, payload: string) -> (bool, domain.Domain_Error)
launch_preferences_get :: proc(repo: ^User_Repository, owner: string) -> (string, domain.Domain_Error) {
 if repo == nil || repo.launch_preferences_get == nil do return "", domain.domain_error(.Internal_Error, "launch preferences are not configured")
 return repo.launch_preferences_get(repo.ctx, owner)
}
launch_preferences_save :: proc(repo: ^User_Repository, owner, payload: string) -> (bool, domain.Domain_Error) {
 if repo == nil || repo.launch_preferences_save == nil do return false, domain.domain_error(.Internal_Error, "launch preferences are not configured")
 return repo.launch_preferences_save(repo.ctx, owner, payload)
}
