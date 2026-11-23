package fetch

// Download, verify and unpack a release for the bridge supervisor (T12).
// Implements docs/specs/bridge-supervisor-engine.md §14 steps 1-4 and 6-11
// (step 5, eligibility §13.2, belongs to the resolver/engine and is a hook in
// prepare_release), the W9 download rule and the W1-W3/W5 rules for the
// staging tree (§5), and the tree-name choice of §4.
//
// Every step fails closed: on any error nothing outside
// <data>/supervisor/downloads/<op_id>/ and <data>/releases/.staging-<op_id>/
// has been written, no pointer is touched, and the installed version keeps
// running. The caller (T13) journals the returned code as `failed <code>`.
//
// Files:
//   manifest.odin   minisign signature + release manifest (§14 steps 1-4)
//   download.odin   bounded downloads, size + SHA-256, .part rename (step 6, W9)
//   inflate.odin    streaming DEFLATE decoder with a hard output cap
//   archive.odin    safe tar.gz / zip extraction (step 7)
//   ossig*.odin     OS code-signature check, macOS quarantine (step 8)
//   tree.odin       tree.json, name choice, rename, preflight, .complete (9-11)
//   prepare.odin    the whole sequence for one operation
//
// No network I/O of its own: HTTP goes through an injected Download_Proc, so
// the engine and the failure-injection suite (T15) can drive every path.
//
// Memory: procedures take an explicit allocator for what they return and use
// context.temp_allocator for scratch and for Error.detail strings. The caller
// must free_all(context.temp_allocator) after each operation.

import "core:fmt"

// TARGET is the release-manifest target of this build (docs/release-signing.md).
// Same table as the launcher (src/launcher/core/records.odin).
TARGET :: "linux-amd64" when ODIN_OS == .Linux && ODIN_ARCH == .amd64 else
	"linux-arm64" when ODIN_OS == .Linux && ODIN_ARCH == .arm64 else
	"darwin-arm64" when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 else
	"darwin-amd64" when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 else
	"windows-amd64" when ODIN_OS == .Windows && ODIN_ARCH == .amd64 else
	"unsupported"

MANIFEST_ASSET :: "heimdall-release-manifest.json"
SIGNATURE_ASSET :: MANIFEST_ASSET + ".minisig"

// Limits (spec §19).
MAX_MANIFEST_BYTES :: 1 << 20
MAX_SIGNATURE_BYTES :: 1 << 20
MAX_UNPACKED_BYTES :: i64(512) << 20
MAX_ENTRIES :: 10_000
// Longest relative path accepted inside an archive (Windows MAX_PATH budget is
// spent by the instance root; 240 keeps <root>/releases/<tree>/<path> sane).
MAX_PATH_BYTES :: 240
MAX_PATH_DEPTH :: 32

// Code is the failure reason journaled as `failed <code>` (spec §6.2, §14).
Code :: enum {
	None,
	Key_Unpinned, // signature key id not pinned in this build (§14 step 2)
	Signature_Invalid, // minisign signature or trusted-comment signature does not verify (step 3)
	Manifest_Invalid, // not canonical, wrong shape, or disagrees with its trusted comment (step 4)
	Manifest_Mismatch, // disagrees with the GitHub release: tag, target, asset (§13.1)
	Manifest_Expired, // trusted comment `expires` passed, new candidates only (step 4)
	Manifest_Incomplete, // min_engine >= 1 without the engine fields (§13.4)
	Download_Failed, // transport error, HTTP status, or a cap exceeded while downloading
	Bundle_Mismatch, // bundle size or SHA-256 differs from the manifest (step 6)
	Archive_Unsafe, // extraction refused (step 7)
	Os_Signature_Invalid, // Authenticode / codesign check failed (step 8)
	Fs_Busy, // rename or delete still refused after the W3 retries
	Fs_Error, // any other local file-system failure
	Preflight_Failed, // --version preflight did not print the manifest version (step 10)
	Tree_Damaged, // an installed tree does not match its tree.json
}

CODE_NAMES := [Code]string {
	.None                 = "",
	.Key_Unpinned         = "key_unpinned",
	.Signature_Invalid    = "signature_invalid",
	.Manifest_Invalid     = "manifest_invalid",
	.Manifest_Mismatch    = "manifest_mismatch",
	.Manifest_Expired     = "manifest_expired",
	.Manifest_Incomplete  = "manifest_incomplete",
	.Download_Failed      = "download_failed",
	.Bundle_Mismatch      = "bundle_mismatch",
	.Archive_Unsafe       = "archive_unsafe",
	.Os_Signature_Invalid = "os_signature_invalid",
	.Fs_Busy              = "fs_busy",
	.Fs_Error             = "fs_error",
	.Preflight_Failed     = "preflight_failed",
	.Tree_Damaged         = "tree_damaged",
}

// Failure is a code plus a human-readable detail (temp-allocated). Error is
// nil on success so `or_return` works.
Failure :: struct {
	code:   Code,
	detail: string,
}
Error :: union {
	Failure,
}

code_name :: proc(c: Code) -> string {
	return CODE_NAMES[c]
}

// error_code is .None for nil.
error_code :: proc(e: Error) -> Code {
	f, is := e.(Failure)
	return f.code if is else .None
}

error_detail :: proc(e: Error) -> string {
	f, _ := e.(Failure)
	return f.detail
}

@(private)
fail :: proc(code: Code, format: string, args: ..any) -> Error {
	return Failure{code = code, detail = fmt.tprintf(format, ..args)}
}
