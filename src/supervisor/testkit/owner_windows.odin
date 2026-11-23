#+build windows
package testkit

import "core:fmt"
import lc "../../launcher/core"

// owner_json: the instance.json `owner` of the current user (spec §3).
owner_json :: proc() -> string {
	sid, ok, _ := lc.current_user_sid()
	assert(ok, "current_user_sid")
	return fmt.tprintf(`{{"sid":"%s"}}`, sid)
}
