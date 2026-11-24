package service

// Network plumbing shared with the binary's transport (src/supervisor/net.odin, which
// owns libcurl so this package stays testable without it).

import "core:sync"

TEST_BUILD :: #config(HEIMDALL_SUPERVISOR_TEST, false)

// Set (atomically) on a service stop: the transport aborts a transfer in flight (§7.5).
g_net_cancel: bool

net_cancel :: proc() {
	sync.atomic_store(&g_net_cancel, true)
}
