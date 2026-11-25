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

// agent.automations.webhooks.<verb>. No caller-selected owner or URL.
// test posts body through the same authenticated ingress as external callers.
Webhook_Parameters :: struct {
 id: string,
 name: Maybe(string),
 dedupe_header: Maybe(string),
 webhook_secret: string,
 // Encoded JSON avoids interpreting payload keys as agent auth fields.
 body: string,
}
