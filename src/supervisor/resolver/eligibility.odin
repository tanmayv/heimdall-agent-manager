package resolver

// Eligibility of a verified candidate, docs/specs/bridge-supervisor-engine.md
// §13.2 rules 1-6 (first failure wins). Rule 7 (journal schema gap) and rule 8
// (state rules §11.3) need journal and snapshot context and belong to the
// activation engine (T13), which runs them after these.

Action :: enum {
	Timer,
	Update_Now,
	Install_Version,
	Retry_Failed,
	Repair,
}

// Release_Id identifies installed bytes: version (no "v"), bundle SHA-256 and
// the trusted-comment seq of the manifest that installed it (0 = unknown, e.g.
// a tree installed before manifests carried one).
Release_Id :: struct {
	version: string,
	sha256:  string,
	seq:     i64,
}

// Offer is the candidate as stated by its verified manifest.
Offer :: struct {
	using id:         Release_Id,
	min_engine:       int,
	min_launcher_abi: int,
}

Pin :: struct {
	version: string `json:"version"`,
	sha256:  string `json:"sha256"`,
}

Verdict :: enum {
	Proceed,
	Noop,
	Failed,
}

check_eligibility :: proc(
	action: Action,
	installed: Release_Id,
	offer: Offer,
	pins: []Pin,
	engine_version: int,
	launcher_abi: int,
) -> (verdict: Verdict, code: string) {
	cmp := semver_compare_strings(offer.version, installed.version)
	same_seq := offer.seq == installed.seq || offer.seq == 0 || installed.seq == 0
	// 1. Same release already installed (repair re-installs it into a new tree).
	if cmp == 0 && offer.sha256 == installed.sha256 && same_seq && action != .Repair {
		return .Noop, "up_to_date"
	}
	// 2. Releases are immutable: the same version with other bytes or another
	//    signature is refused, whatever the action.
	if cmp == 0 && (offer.sha256 != installed.sha256 || !same_seq) {
		return .Failed, "digest_conflict"
	}
	// 3. Never a silent downgrade: only an explicit install_version goes lower.
	if cmp < 0 && action != .Install_Version {
		return .Noop, "ahead_of_channel"
	}
	// 4. A candidate that failed before stays pinned unless the user overrides.
	if action != .Retry_Failed && action != .Install_Version {
		for p in pins {
			if p.version == offer.version && p.sha256 == offer.sha256 do return .Noop, "pinned"
		}
	}
	// 5. The release must name an engine this supervisor satisfies.
	if offer.min_engine == 0 do return .Failed, "no_engine"
	if offer.min_engine > engine_version do return .Failed, "engine_too_old"
	// 6. The frozen launcher must be new enough (D8).
	if offer.min_launcher_abi > launcher_abi do return .Failed, "launcher_abi_too_old"
	return .Proceed, ""
}

// check_manifest_match is the last rule of §13.1: the verified manifest's
// version must equal the tag without "v", and its entry for this target must
// name the bundle asset found in the release.
check_manifest_match :: proc(r: Release, manifest_version, manifest_target_asset: string) -> (ok: bool, code: string) {
	if r.version == "" || manifest_version != r.version || manifest_target_asset != r.bundle.name || r.bundle.name == "" {
		return false, "manifest_mismatch"
	}
	return true, ""
}
