package bots

import "core:fmt"

// A2a replaces this stub with section 4.3 delivery cancellation and instance stop.
bots_on_experiment_disabled :: proc(s: ^Bots_Service, owner_user_id: string) {
	fmt.eprintf("bots: experiment disabled owner=%s\n", owner_user_id)
}
