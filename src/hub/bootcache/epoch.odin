// Package bootcache holds the process-wide "content epoch" used to invalidate the
// bootstrap manifest cache without a per-call-site "remember to bump" write path.
//
// The epoch is a monotonically increasing counter bumped at the SQLite write
// choke points that can affect a rendered bootstrap manifest (memories, agents,
// projects). The bootstrap-manifest cache stores the epoch it was rendered under;
// a conditional manifest GET can therefore short-circuit to a 304 whenever the
// cached epoch still matches the current epoch (no re-render, no memories scan),
// and is forced to re-render (and recompute bootstrap_version) after any write.
//
// It intentionally lives in its own leaf package so both the repository/sqlite
// layer (which bumps it) and the agent service (which reads it) can depend on it
// without creating an import cycle.
package bootcache

import "base:intrinsics"

@(private)
global_content_epoch: u64

// bump_content_epoch increments the process-wide content epoch. Call this from
// any write that can change a rendered bootstrap manifest (memory/agent/project
// mutations). Cheap, lock-free, and safe to over-bump: a spurious bump only costs
// one extra manifest re-render, never a stale doc.
bump_content_epoch :: proc() {
	intrinsics.atomic_add(&global_content_epoch, 1)
}

// content_epoch returns the current content epoch. The manifest cache compares
// this against the epoch it last rendered under to decide HIT (equal) vs
// re-render (changed).
content_epoch :: proc() -> u64 {
	return intrinsics.atomic_load(&global_content_epoch)
}
