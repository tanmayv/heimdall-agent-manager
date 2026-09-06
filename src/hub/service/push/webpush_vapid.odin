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
