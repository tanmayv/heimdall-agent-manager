package push

// WP-CRYPTO-2: RFC 8291 "aes128gcm" Web Push payload encryption.
//
// The message body is encrypted as a single RFC 8188 record:
//
//   ecdh_secret = ECDH(as_private, ua_public)            # P-256, 32-byte X
//   IKM  = HKDF(salt=auth_secret, IKM=ecdh_secret,
//               info="WebPush: info"||0x00||ua_public||as_public, L=32)
//   PRK  = HKDF-Extract(salt, IKM)
//   CEK  = HKDF-Expand(PRK, "Content-Encoding: aes128gcm"||0x00, L=16)
//   NONCE= HKDF-Expand(PRK, "Content-Encoding: nonce"||0x00,     L=12)
//   header     = salt(16) || rs(4, big-endian) || idlen(1) || as_public(65)
//   ciphertext = AES-128-GCM(CEK, NONCE, plaintext || 0x02)     # +16B tag
//   body       = header || ciphertext
//
// See RFC 8291 Section 3.4 / Appendix A and RFC 8188 Section 2.1.

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:encoding/endian"
import "core:mem"

// WEBPUSH_AUTH_SECRET_SIZE is the length of the subscription auth secret.
WEBPUSH_AUTH_SECRET_SIZE :: 16
// WEBPUSH_SALT_SIZE is the RFC 8188 content-coding header salt length.
WEBPUSH_SALT_SIZE :: 16
// WEBPUSH_RECORD_SIZE is the "rs" we advertise. RFC 8291 sends a single
// record; 4096 comfortably exceeds our small JSON payloads plus the padding
// delimiter and the 16-byte GCM tag.
WEBPUSH_RECORD_SIZE :: 4096
// WEBPUSH_PAD_DELIMITER is the final-record padding delimiter (RFC 8188).
WEBPUSH_PAD_DELIMITER :: 0x02

@(private = "file")
CEK_INFO :: "Content-Encoding: aes128gcm\x00"
@(private = "file")
NONCE_INFO :: "Content-Encoding: nonce\x00"
@(private = "file")
KEY_INFO_PREFIX :: "WebPush: info\x00"

@(private = "file")
CEK_SIZE :: 16
@(private = "file")
NONCE_SIZE :: 12
@(private = "file")
SHA256_SIZE :: 32
// IKM length per RFC 8291 Section 3.4 (L = 32 octets).
@(private = "file")
IKM_SIZE :: 32
@(private = "file")
HEADER_SIZE :: WEBPUSH_SALT_SIZE + 4 + 1 + EC_P256_POINT_SIZE

// Webpush_Encrypted is an RFC 8291 encrypted message ready to POST. `body`
// carries the full `aes128gcm` framing (header || ciphertext) and is owned by
// the caller.
Webpush_Encrypted :: struct {
	body: []byte,
}

// webpush_encrypt encrypts plaintext for a subscription, generating a fresh
// ephemeral ECDH keypair and random salt. `ua_public` is the subscription
// `p256dh` (uncompressed P-256 point, 65 bytes); `auth_secret` is the 16-byte
// `auth` value. Returns the encrypted body and true on success.
webpush_encrypt :: proc(
	plaintext: []byte,
	ua_public: []byte,
	auth_secret: []byte,
	allocator := context.allocator,
) -> (Webpush_Encrypted, bool) {
	if !crypto.HAS_RAND_BYTES {
		return {}, false
	}

	salt: [WEBPUSH_SALT_SIZE]byte
	crypto.rand_bytes(salt[:])

	as_priv: ecdh.Private_Key
	defer ecdh.private_key_clear(&as_priv)
	if !ecdh.private_key_generate(&as_priv, .SECP256R1) {
		return {}, false
	}

	return webpush_encrypt_with(plaintext, ua_public, auth_secret, &as_priv, salt[:], allocator)
}

// webpush_encrypt_with is the deterministic core: it encrypts using a
// caller-supplied ephemeral (application-server) private key and salt. This is
// separated out so the RFC 8291 Appendix A vector can be reproduced exactly in
// tests; production code uses webpush_encrypt, which supplies random values.
webpush_encrypt_with :: proc(
	plaintext: []byte,
	ua_public: []byte,
	auth_secret: []byte,
	as_priv: ^ecdh.Private_Key,
	salt: []byte,
	allocator := context.allocator,
) -> (Webpush_Encrypted, bool) {
	if !p256_point_is_valid(ua_public) {
		return {}, false
	}
	if len(auth_secret) != WEBPUSH_AUTH_SECRET_SIZE || len(salt) != WEBPUSH_SALT_SIZE {
		return {}, false
	}

	// Decode the subscription public key into an ECDH public point.
	ua_pub_key: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&ua_pub_key, .SECP256R1, ua_public) {
		return {}, false
	}

	// The application-server public point (uncompressed 0x04||X||Y) is both an
	// HKDF input and the RFC 8188 header "keyid".
	as_public: [EC_P256_POINT_SIZE]byte
	as_pub_key: ecdh.Public_Key
	ecdh.public_key_set_priv(&as_pub_key, as_priv)
	ecdh.public_key_bytes(&as_pub_key, as_public[:])

	// 1. ECDH shared secret (the 32-byte X coordinate).
	ecdh_secret: [EC_P256_COORD_SIZE]byte
	defer crypto.zero_explicit(&ecdh_secret, size_of(ecdh_secret))
	if !ecdh.ecdh(as_priv, &ua_pub_key, ecdh_secret[:]) {
		return {}, false
	}

	// 2. Combine with the auth secret: IKM = HKDF(auth, ecdh_secret, key_info).
	key_info := make([]byte, len(KEY_INFO_PREFIX) + EC_P256_POINT_SIZE * 2, context.temp_allocator)
	{
		n := copy(key_info, KEY_INFO_PREFIX)
		n += copy(key_info[n:], ua_public)
		copy(key_info[n:], as_public[:])
	}
	ikm: [IKM_SIZE]byte
	defer crypto.zero_explicit(&ikm, size_of(ikm))
	hkdf.extract_and_expand(.SHA256, auth_secret, ecdh_secret[:], key_info, ikm[:])

	// 3. Derive CEK and NONCE from PRK = HKDF-Extract(salt, IKM).
	prk: [SHA256_SIZE]byte
	defer crypto.zero_explicit(&prk, size_of(prk))
	hkdf.extract(.SHA256, salt, ikm[:], prk[:])

	cek: [CEK_SIZE]byte
	nonce: [NONCE_SIZE]byte
	defer crypto.zero_explicit(&cek, size_of(cek))
	defer crypto.zero_explicit(&nonce, size_of(nonce))
	hkdf.expand(.SHA256, prk[:], transmute([]byte)string(CEK_INFO), cek[:])
	hkdf.expand(.SHA256, prk[:], transmute([]byte)string(NONCE_INFO), nonce[:])

	// 4. Encrypt plaintext || 0x02 with AES-128-GCM as a single record.
	padded := make([]byte, len(plaintext) + 1, context.temp_allocator)
	copy(padded, plaintext)
	padded[len(plaintext)] = WEBPUSH_PAD_DELIMITER

	// body = header(86) || ciphertext(len(padded)) || tag(16)
	body := make([]byte, HEADER_SIZE + len(padded) + aes.GCM_TAG_SIZE, allocator)

	// header = salt || rs(be32) || idlen(1) || as_public
	copy(body[:WEBPUSH_SALT_SIZE], salt)
	endian.unchecked_put_u32be(body[WEBPUSH_SALT_SIZE:], u32(WEBPUSH_RECORD_SIZE))
	body[WEBPUSH_SALT_SIZE + 4] = EC_P256_POINT_SIZE
	copy(body[WEBPUSH_SALT_SIZE + 5:], as_public[:])

	ciphertext := body[HEADER_SIZE:HEADER_SIZE + len(padded)]
	tag := body[HEADER_SIZE + len(padded):]

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, cek[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ciphertext, tag, nonce[:], nil, padded)

	// Scrub the transient plaintext copy.
	mem.zero_explicit(raw_data(padded), len(padded))

	return Webpush_Encrypted{body = body}, true
}
