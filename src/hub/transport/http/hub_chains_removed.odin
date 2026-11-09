package http

import domain "odin_test:hub/domain"

// The Hub task-chain engine (chains, tasks, leases, reviews, workflows) is
// removed: every chain is Bridge-owned. Hub-only chain/task/workflow routes,
// and agent verbs that would have fallen through to the Hub engine, answer
// one typed refusal: HTTP 410 {"code":"hub_chains_removed"}. Legacy rows stay
// in the database as read-only records for the one-shot owner import.
HUB_CHAINS_REMOVED_MESSAGE :: "Hub task chains are removed; chains are Bridge-owned. Create one on a Bridge, or import a legacy chain from Settings → Bridge."

hub_chains_removed_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Hub_Chains_Removed, HUB_CHAINS_REMOVED_MESSAGE, `{"code":"hub_chains_removed"}`)
}

hub_chains_removed_handler :: proc(ctx: rawptr, req: Request) -> Response {
	return respond_error(hub_chains_removed_error(), req.request_id)
}
