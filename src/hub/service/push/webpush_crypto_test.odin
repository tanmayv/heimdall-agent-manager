package push

import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:strings"
import "core:testing"

// --- WP-CRYPTO-3: base64url round-trips -------------------------------------

@(test)
base64url_encode_is_unpadded :: proc(t: ^testing.T) {
	// "foobar" -> standard base64 "Zm9vYmFy" (no padding at this length).
	got := base64url_encode(transmute([]byte)string("foobar"))
	defer delete(got)
	testing.expect_value(t, got, "Zm9vYmFy")

	// A length whose padded form ends in '=' must come back trimmed.
	got2 := base64url_encode({0xff, 0xff, 0xff, 0xfe})
	defer delete(got2)
	testing.expect_value(t, got2, "_____g")
}

@(test)
base64url_uses_url_alphabet :: proc(t: ^testing.T) {
	// 0xfb produces '+'/'/' in standard base64; base64url must use '-'/'_'.
	got := base64url_encode({0xfb, 0xff, 0xbf})
	defer delete(got)
	testing.expect_value(t, got, "-_-_")
}

@(test)
base64url_decode_round_trip :: proc(t: ^testing.T) {
	original := []byte{0x00, 0x10, 0xab, 0xcd, 0xef, 0xff, 0x7f}
	encoded := base64url_encode(original)
	defer delete(encoded)
	decoded, ok := base64url_decode(encoded)
	defer delete(decoded)
	testing.expect(t, ok)
	testing.expect(t, len(decoded) == len(original))
	for i in 0 ..< len(original) {
		testing.expect_value(t, decoded[i], original[i])
	}
}

@(test)
base64url_decode_rejects_bad_input :: proc(t: ^testing.T) {
	// '+' and '/' belong to standard base64, not base64url.
	_, ok := base64url_decode("ab+c")
	testing.expect(t, !ok)
	_, ok2 := base64url_decode("ab/c")
	testing.expect(t, !ok2)
}

// --- WP-CRYPTO-1: VAPID JWT --------------------------------------------------

@(test)
vapid_endpoint_audience_extracts_origin :: proc(t: ^testing.T) {
	aud, ok := vapid_endpoint_audience("https://web.push.apple.com/abc/def?x=1")
	defer delete(aud)
	testing.expect(t, ok)
	testing.expect_value(t, aud, "https://web.push.apple.com")

	aud2, ok2 := vapid_endpoint_audience("https://fcm.googleapis.com")
	defer delete(aud2)
	testing.expect(t, ok2)
	testing.expect_value(t, aud2, "https://fcm.googleapis.com")

	_, bad := vapid_endpoint_audience("not-a-url")
	testing.expect(t, !bad)
}

@(test)
vapid_jwt_verifies_and_has_three_segments :: proc(t: ^testing.T) {
	priv: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&priv)
	testing.expect(t, ecdsa.private_key_generate(&priv, .SECP256R1))

	pub: ecdsa.Public_Key
	ecdsa.public_key_set_priv(&pub, &priv)

	claims := Vapid_Claims {
		audience = "https://web.push.apple.com",
		subject  = "mailto:test@example.com",
		expiry   = 1_800_000_000,
	}
	jwt, ok := vapid_sign_jwt(&priv, claims)
	defer delete(jwt)
	testing.expect(t, ok)

	// Exactly two dots: header.claims.signature. Track the last dot so we can
	// split the signature from the `header.claims` signing input.
	dots := 0
	last_dot := -1
	for i in 0 ..< len(jwt) {
		if jwt[i] == '.' {
			dots += 1
			last_dot = i
		}
	}
	testing.expect_value(t, dots, 2)

	// The ES256 signature over `header.claims` must verify with the public key.
	signing_input := transmute([]byte)jwt[:last_dot]
	sig_b64 := jwt[last_dot + 1:]
	sig, sig_ok := base64url_decode(sig_b64)
	defer delete(sig)
	testing.expect(t, sig_ok)
	testing.expect(t, ecdsa.verify_raw(&pub, hash.Algorithm.SHA256, signing_input, sig))

	// The claims segment must be well-formed JSON carrying aud/exp/sub. This
	// guards against format-string mishandling of the literal JSON braces.
	first_dot := strings.index_byte(jwt, '.')
	claims_seg := jwt[first_dot + 1:last_dot]
	claims_bytes, claims_ok := base64url_decode(claims_seg)
	defer delete(claims_bytes)
	testing.expect(t, claims_ok)
	claims_str := string(claims_bytes)
	testing.expect(t, strings.has_prefix(claims_str, "{\"aud\":\"https://web.push.apple.com\""))
	testing.expect(t, strings.contains(claims_str, "\"sub\":\"mailto:test@example.com\""))
	testing.expect(t, strings.has_suffix(claims_str, "}"))
	testing.expect(t, !strings.contains(claims_str, "MISSING"))
}

@(test)
vapid_claims_for_sets_expiry :: proc(t: ^testing.T) {
	claims := vapid_claims_for("https://web.push.apple.com", "mailto:test@example.com", 1_000_000)
	testing.expect_value(t, claims.audience, "https://web.push.apple.com")
	testing.expect_value(t, claims.subject, "mailto:test@example.com")
	testing.expect_value(t, claims.expiry, i64(1_000_000 + VAPID_JWT_TTL_SECONDS))
}

@(test)
vapid_authorization_header_shape :: proc(t: ^testing.T) {
	got := vapid_authorization_header("JWT.TOKEN.SIG", "PUBKEY")
	defer delete(got)
	testing.expect_value(t, got, "vapid t=JWT.TOKEN.SIG, k=PUBKEY")
}

// --- WP-CRYPTO-2: RFC 8291 Appendix A vector --------------------------------

// The canonical intermediate/output values from RFC 8291 Appendix A. Encrypting
// the sample plaintext with the sample application-server key + salt MUST
// reproduce the exact body shown in Section 5. This is the correctness gate.
@(test)
webpush_encrypt_matches_rfc8291_appendix_a :: proc(t: ^testing.T) {
	as_private_b64 := "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
	ua_public_b64 := "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
	auth_b64 := "BTBZMqHH6r4Tts7J_aSIgg"
	salt_b64 := "DGv6ra1nlYgDCS1FRnbzlw"
	plaintext := "When I grow up, I want to be a watermelon"
	// header || ciphertext from Section 5 (whitespace removed).
	expected_body_b64 := "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

	as_private, ok1 := base64url_decode(as_private_b64)
	defer delete(as_private)
	testing.expect(t, ok1)
	ua_public, ok2 := base64url_decode(ua_public_b64)
	defer delete(ua_public)
	testing.expect(t, ok2)
	auth_secret, ok3 := base64url_decode(auth_b64)
	defer delete(auth_secret)
	testing.expect(t, ok3)
	salt, ok4 := base64url_decode(salt_b64)
	defer delete(salt)
	testing.expect(t, ok4)

	as_priv: ecdh.Private_Key
	defer ecdh.private_key_clear(&as_priv)
	testing.expect(t, ecdh.private_key_set_bytes(&as_priv, .SECP256R1, as_private))

	enc, ok := webpush_encrypt_with(transmute([]byte)plaintext, ua_public, auth_secret, &as_priv, salt)
	defer delete(enc.body)
	testing.expect(t, ok)

	got_b64 := base64url_encode(enc.body)
	defer delete(got_b64)
	testing.expect_value(t, got_b64, expected_body_b64)
}

@(test)
webpush_encrypt_rejects_bad_inputs :: proc(t: ^testing.T) {
	as_priv: ecdh.Private_Key
	defer ecdh.private_key_clear(&as_priv)
	testing.expect(t, ecdh.private_key_generate(&as_priv, .SECP256R1))
	salt: [WEBPUSH_SALT_SIZE]byte
	auth: [WEBPUSH_AUTH_SECRET_SIZE]byte

	// Malformed subscription key (not a 65-byte uncompressed point).
	_, bad_point := webpush_encrypt_with({1, 2, 3}, {0x04, 0x00}, auth[:], &as_priv, salt[:])
	testing.expect(t, !bad_point)

	// Wrong auth-secret length.
	good_point: [EC_P256_POINT_SIZE]byte
	good_point[0] = EC_UNCOMPRESSED_PREFIX
	_, bad_auth := webpush_encrypt_with({1}, good_point[:], {1, 2, 3}, &as_priv, salt[:])
	testing.expect(t, !bad_auth)
}
