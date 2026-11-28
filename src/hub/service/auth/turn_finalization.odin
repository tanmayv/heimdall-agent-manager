package auth

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"

// This identity is deliberately not an Instance_Token Auth_Context. Only the
// bridge-authored ACP handlers (assistant segment relay, input state) may
// promote it, after checking the asserted launch epoch.
Turn_Finalization_Identity :: struct {
    instance: domain.Agent_Instance,
    asserted_epoch: string,
    stale: bool,
}

authenticate_bridge_instance_for_turn_finalization :: proc(s: ^Auth_Service,req: Auth_Request) -> (Turn_Finalization_Identity,bool,domain.Domain_Error) {
    denied := domain.domain_error(.Forbidden,"bridge instance assertion token is invalid")
    if s == nil || s.bridges == nil || s.agents == nil do return {},false,denied
    if token_in_query_or_body(req.query,req.body) do return {},false,denied
    authz := header_value(req.headers,"Authorization")
    if !strings.has_prefix(authz,"Bearer ") do return {},false,denied
    bridge, valid, _ := bridge_service.verify_bridge_token(s.bridges,strings.trim_space(authz[len("Bearer "):]))
    if !valid do return {},false,denied
    token := header_value(req.headers,"X-Heimdall-Instance-Token")
    id := agent_service.instance_id_from_assertion(token)
    body_id := extract_body_instance_id(req.body)
    if id == "" || (body_id != "" && id != body_id) do return {},false,denied
    inst, exists, _ := agent_service.get_instance(s.agents,bridge,id)
    if !exists || inst.bridge_id != bridge.bridge_id do return {},false,denied
    separator := strings.index(token,"~")
    if separator < 0 || separator == len(token)-1 do return {},false,denied
    epoch := token[separator+1:]
    asserted := inst; asserted.launch_epoch=epoch
    expected := agent_service.instance_assertion_token(asserted)
    defer delete(expected)
    if token != expected do return {},false,denied
    return {instance=inst,asserted_epoch=epoch,stale=epoch!=inst.launch_epoch},true,{}
}
