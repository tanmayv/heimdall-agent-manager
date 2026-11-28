package contracts

import "base:runtime"
import "core:crypto"

// Releases a successful Hub exchange result. Only these fields are owned.
// Request, operation and status codes parsed directly from wire instead have
// the parser's lifetime and must not be passed here.
bot_channel_vault_result_destroy :: proc(result: ^Bot_Channel_Vault_Result) {
	if result == nil do return
	if len(result.body) != 0 do crypto.zero_explicit(raw_data(result.body), len(result.body))
	a := runtime.default_allocator()
	delete(result.body, a)
	delete(result.request_id, a)
	delete(result.scope_digest, a)
	result^ = {}
}
