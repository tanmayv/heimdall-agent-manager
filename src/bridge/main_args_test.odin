package main

import "core:testing"

// Regression (HF1): `ham-bridge update --version vX` printed the binary's version
// and exited, so manual updates and the auto-update worker never ran.
@(test)
bridge_global_version_yields_to_subcommands :: proc(t: ^testing.T) {
	testing.expect(t, bridge_wants_global_version({"ham-bridge", "--version"}))
	testing.expect(t, bridge_wants_global_version({"ham-bridge", "--config", "c.toml", "--version"}))
	testing.expect(t, !bridge_wants_global_version({"ham-bridge"}))
	testing.expect(t, !bridge_wants_global_version({"ham-bridge", "update", "--version", "v0.5.60"}))
	testing.expect(t, !bridge_wants_global_version({"ham-bridge", "update", "--version", "v1", "--service", "s", "--auto-worker"}))
	testing.expect(t, !bridge_wants_global_version({"ham-bridge", "status", "--json"}))
}
