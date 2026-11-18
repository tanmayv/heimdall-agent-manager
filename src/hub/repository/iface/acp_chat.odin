package iface

import domain "odin_test:hub/domain"

Content_Get_Assistant_Turn_Proc :: proc(ctx: rawptr, instance, epoch, turn: string) -> (domain.ACP_Assistant_Turn, bool, domain.Domain_Error)
Content_Save_Assistant_Turn_Proc :: proc(ctx: rawptr, turn: domain.ACP_Assistant_Turn) -> domain.Domain_Error

content_get_assistant_turn :: proc(r: ^Content_Repository, instance, epoch, turn: string) -> (domain.ACP_Assistant_Turn, bool, domain.Domain_Error) {
    if r == nil || r.get_assistant_turn == nil do return {}, false, domain.domain_error(.Internal_Error, "assistant turn repository is not configured")
    return r.get_assistant_turn(r.ctx, instance, epoch, turn)
}

content_save_assistant_turn :: proc(r: ^Content_Repository, turn: domain.ACP_Assistant_Turn) -> domain.Domain_Error {
    if r == nil || r.save_assistant_turn == nil do return domain.domain_error(.Internal_Error, "assistant turn repository is not configured")
    return r.save_assistant_turn(r.ctx, turn)
}
