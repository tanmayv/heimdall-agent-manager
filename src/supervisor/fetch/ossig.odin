package fetch

// OS code-signature check of an unpacked staging tree, spec §14 step 8.
//
//   macOS:   every Mach-O file must pass `codesign --verify --strict`; when the
//            policy requires signatures it must also carry a Team ID (equal to
//            `team_id` when set, else one Team ID shared by all of them, as
//            scripts/release/verify-macos-signatures.sh checks at release).
//            After the check passes, com.apple.quarantine is removed from
//            every file (it is never removed before).
//   Windows: every .exe and .dll goes through WinVerifyTrust (no UI, no
//            network revocation fetch); when required, it must be signed and,
//            when `publisher` is set, the signer's simple display name (CN)
//            must equal it (scripts/release/verify-windows-signatures.ps1).
//   Linux:   no OS signature exists; the step is a no-op.
//
// A file without a signature passes when the policy does not require one
// ("where available"); a file whose signature is present but does not verify
// (tampered after signing, untrusted chain, ...) always fails.
//
// Default policy: required on macOS, where T8 notarizes the bare binaries;
// not required on Windows, where Authenticode is deferred (T8 user decision,
// off-by-default switch). The macOS Team ID is a build-time constant
// (-define:HEIMDALL_MACOS_TEAM_ID=...) because it lives in a CI secret
// (APPLE_TEAM_ID); the release build that ships the supervisor sets it.

HEIMDALL_MACOS_TEAM_ID :: #config(HEIMDALL_MACOS_TEAM_ID, "")
HEIMDALL_WINDOWS_PUBLISHER :: #config(HEIMDALL_WINDOWS_PUBLISHER, "")

Os_Signature_Policy :: struct {
	require:   bool,
	team_id:   string, // macOS: expected TeamIdentifier, "" = any one shared Team ID
	publisher: string, // Windows: expected signer CN, "" = any trusted signer
}

DEFAULT_OS_SIGNATURE_POLICY :: Os_Signature_Policy {
	require   = ODIN_OS == .Darwin,
	team_id   = HEIMDALL_MACOS_TEAM_ID,
	publisher = HEIMDALL_WINDOWS_PUBLISHER,
}

Signature_State :: enum {
	Not_Applicable, // not a code file on this OS
	Unsigned,
	Valid,
	Invalid,
}

// check_os_signatures runs step 8 over the extracted files of `staging`.
check_os_signatures :: proc(staging: string, files: []Extracted_File, policy: Os_Signature_Policy) -> Error {
	shared_identity := ""
	for f in files {
		path := native_join(staging, f.path)
		state, identity, detail := os_signature_state(path, f.path)
		switch state {
		case .Not_Applicable:
			continue
		case .Invalid:
			return fail(.Os_Signature_Invalid, "%s: signature does not verify (%s)", f.path, detail)
		case .Unsigned:
			if policy.require do return fail(.Os_Signature_Invalid, "%s: not signed", f.path)
		case .Valid:
			if !policy.require do continue
			want := policy.team_id when ODIN_OS == .Darwin else policy.publisher
			if identity == "" do return fail(.Os_Signature_Invalid, "%s: signature carries no identity (%s)", f.path, detail)
			if want != "" && identity != want do return fail(.Os_Signature_Invalid, "%s: signed by %q, expected %q", f.path, identity, want)
			when ODIN_OS == .Darwin {
				if shared_identity != "" && identity != shared_identity {
					return fail(.Os_Signature_Invalid, "%s: Team ID %q differs from %q", f.path, identity, shared_identity)
				}
				shared_identity = identity
			}
		}
	}
	_ = shared_identity
	return clear_quarantine(staging, files)
}
