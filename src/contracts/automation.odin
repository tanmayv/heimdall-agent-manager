package contracts
import "core:encoding/json"

// agent.automations.{create,list,show,update,delete,runs,trigger-types} uses
// this params object. input reuses the actions service's Action_Input JSON.
// filter-test instead uses Action_Filter_Test_Request. Owner and actor are
// deliberately absent: the hub derives them from instance authentication.
Automation_Parameters :: struct {
 id: string,
 input: json.Value,
 limit: Maybe(int),
 before, before_id: string,
}
