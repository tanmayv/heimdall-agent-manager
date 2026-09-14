package push

// WP-CRYPTO-1: VAPID (RFC 8292) ES256 JWT signing for the `Authorization`
// header of Web Push requests.
//
// The JWS is signed with ECDSA P-256 + SHA-256 and, per RFC 7515, the
// signature is the raw `R || S` (64 bytes) base64url-encoded — NOT the ASN.1
// DER form that `core:crypto/ecdsa` also offers.

import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// VAPID_JWT_TTL_SECONDS is the token lifetime we request. RFC 8292 caps `exp`
// at 24h from issuance; 12h leaves comfortable headroom for clock skew while
// staying well under the limit.
VAPID_JWT_TTL_SECONDS :: 12 * 60 * 60

// ES256_SIGNATURE_SIZE is the raw `R || S` signature length for P-256.
ES256_SIGNATURE_SIZE :: 64

// P256_N is the order n of the P-256 (secp256r1) base point, big-endian.
// P256_N_HALF is floor(n/2). A canonical ("low-S") ECDSA signature has
// S <= n/2. RFC 7515 accepts either S, and FCM/Mozilla do too, but Apple's
// web.push.apple.com rejects a high-S VAPID JWT as `BadJwtToken`, so we MUST
// normalize S to its low form before sending.
@(private = "file")
P256_N := [32]byte{
	0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
	0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
}
@(private = "file")
P256_N_HALF := [32]byte{
	0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
	0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42,
	0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
}

// Vapid_Claims are the RFC 8292 JWT claims. `audience` is the origin
// (`<scheme>://<host>`) of the push endpoint; `subject` is a contact URI
// (`mailto:` or `https:`).
Vapid_Claims :: struct {
	audience: string,
	subject:  string,
	// expiry is the absolute `exp` claim in unix seconds.
	expiry:   i64,
}

// vapid_claims_for builds claims for a push endpoint, setting `exp` to
// now_unix + VAPID_JWT_TTL_SECONDS. `now_unix` is the current time in unix
// seconds (supplied by the caller so this stays pure/testable).
vapid_claims_for :: proc(audience, subject: string, now_unix: i64) -> Vapid_Claims {
	return Vapid_Claims{
		audience = audience,
		subject  = subject,
		expiry   = now_unix + VAPID_JWT_TTL_SECONDS,
	}
}

// vapid_endpoint_audience derives the JWT `aud` claim — the origin
// `<scheme>://<host>` — from a push endpoint URL. It returns (audience, true)
// on success, or ("", false) if the URL is not an absolute http(s) URL.
vapid_endpoint_audience :: proc(endpoint: string, allocator := context.allocator) -> (string, bool) {
	scheme_end := strings.index(endpoint, "://")
	if scheme_end <= 0 {
		return "", false
	}
	scheme := endpoint[:scheme_end]
	if scheme != "https" && scheme != "http" {
		return "", false
	}

	rest := endpoint[scheme_end + 3:]
	// The authority ends at the first '/', '?' or '#'.
	host_end := len(rest)
	loop: for i in 0 ..< len(rest) {
		switch rest[i] {
		case '/', '?', '#':
			host_end = i
			break loop
		}
	}
	host := rest[:host_end]
	if len(host) == 0 {
		return "", false
	}

	return fmt.aprintf("%s://%s", scheme, host, allocator = allocator), true
}

// vapid_sign_jwt builds and signs a VAPID ES256 JWT. `priv_key` must be an
// initialized P-256 ECDSA private key. The `exp` claim comes from
// claims.expiry (see vapid_claims_for). The returned compact JWS is owned by
// the caller.
vapid_sign_jwt :: proc(
	priv_key: ^ecdsa.Private_Key,
	claims: Vapid_Claims,
	allocator := context.allocator,
) -> (string, bool) {
	// Header: fixed ES256 JWT.
	header_json := `{"typ":"JWT","alg":"ES256"}`
	header_b64 := base64url_encode(transmute([]byte)header_json, allocator)
	defer delete(header_b64, allocator)

	// Claims. RFC 8292 requires `aud`, `exp`, `sub`. Build via a string builder
	// (NOT fmt.aprintf) because the literal JSON braces would be misread as format
	// verbs; aud/sub are JSON-escaped defensively.
	claims_b := strings.builder_make(allocator)
	defer strings.builder_destroy(&claims_b)
	strings.write_string(&claims_b, "{\"aud\":\"")
	contracts.write_json_string(&claims_b, claims.audience)
	strings.write_string(&claims_b, "\",\"exp\":")
	strings.write_int(&claims_b, int(claims.expiry))
	strings.write_string(&claims_b, ",\"sub\":\"")
	contracts.write_json_string(&claims_b, claims.subject)
	strings.write_string(&claims_b, "\"}")
	claims_json := strings.to_string(claims_b)
	claims_b64 := base64url_encode(transmute([]byte)claims_json, allocator)
	defer delete(claims_b64, allocator)

	// Signing input is `header.claims` (ASCII).
	signing_input := fmt.aprintf("%s.%s", header_b64, claims_b64, allocator = allocator)
	defer delete(signing_input, allocator)

	sig: [ES256_SIGNATURE_SIZE]byte
	if !ecdsa.sign_raw(priv_key, hash.Algorithm.SHA256, transmute([]byte)signing_input, sig[:]) {
		return "", false
	}
	// Apple's web.push.apple.com rejects high-S ECDSA signatures as
	// `BadJwtToken`; normalize S to its canonical low form (S <= n/2).
	es256_normalize_low_s(sig[:])
	sig_b64 := base64url_encode(sig[:], allocator)
	defer delete(sig_b64, allocator)

	return fmt.aprintf("%s.%s", signing_input, sig_b64, allocator = allocator), true
}

// vapid_authorization_header builds the full `Authorization` header value for a
// Web Push request: `vapid t=<jwt>, k=<vapid public key base64url>`.
// `public_key_b64` is the unpadded base64url of the uncompressed VAPID public
// point. The returned string is owned by the caller.
vapid_authorization_header :: proc(jwt: string, public_key_b64: string, allocator := context.allocator) -> string {
	return fmt.aprintf("vapid t=%s, k=%s", jwt, public_key_b64, allocator = allocator)
}

// es256_normalize_low_s rewrites the S half of a raw `R || S` P-256 signature to
// its canonical low form: if S > n/2 it is replaced with n - S (which is an
// equally valid signature). `sig` is the 64-byte raw signature; S is sig[32:64],
// big-endian. This is required for Apple Web Push (high-S -> `BadJwtToken`); it
// is a no-op for signatures that are already low-S.
es256_normalize_low_s :: proc(sig: []byte) {
	assert(len(sig) == ES256_SIGNATURE_SIZE)
	s := sig[32:]
	if be_greater_32(s, P256_N_HALF[:]) {
		// s = n - s (n > s always holds for a valid signature, so no borrow out).
		be_sub_32(P256_N[:], s, s)
	}
}

// be_greater_32 reports whether big-endian unsigned `a` > `b` (equal lengths).
@(private = "file")
be_greater_32 :: proc(a, b: []byte) -> bool {
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}

// be_sub_32 computes dst = minuend - subtrahend for equal-length big-endian
// unsigned integers, assuming minuend >= subtrahend. dst may alias subtrahend
// (each index is read before it is written), which es256_normalize_low_s relies
// on to compute n - S in place.
@(private = "file")
be_sub_32 :: proc(minuend, subtrahend, dst: []byte) {
	borrow := 0
	for i := len(dst) - 1; i >= 0; i -= 1 {
		d := int(minuend[i]) - int(subtrahend[i]) - borrow
		if d < 0 {
			d += 256
			borrow = 1
		} else {
			borrow = 0
		}
		dst[i] = byte(d)
	}
}
