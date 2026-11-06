// Test fixture only: use the production assertion encoder for a disposable
// instance. This tool is never invoked by production or installed.
package main
import "core:fmt"
import "core:os"
import agent "odin_test:hub/service/agent"
import domain "odin_test:hub/domain"
main :: proc() {
    if len(os.args)!=3 do os.exit(2)
    fmt.print(agent.instance_assertion_token(domain.Agent_Instance{agent_instance_id=os.args[1],launch_epoch=os.args[2]}))
}
