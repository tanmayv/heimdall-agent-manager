#+build linux, darwin
package testkit

import "core:fmt"
import "core:sys/posix"

// owner_json: the instance.json `owner` of the current user (spec §3).
owner_json :: proc() -> string {
	return fmt.tprintf(`{{"uid":%d}}`, posix.geteuid())
}
