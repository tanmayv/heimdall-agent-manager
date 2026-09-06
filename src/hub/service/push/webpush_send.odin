package push

// WP-SEND-1: deliver an encrypted Web Push message to every subscription a user
// owns. For each subscription we RFC 8291-encrypt the payload, sign a VAPID JWT
// for the endpoint's origin, and POST the aes128gcm body via the Hub's
// http_client. Endpoints that report 404/410 Gone are pruned.
//
// send_to_user is BLOCKING; callers on the request path must run it on a
// background thread (see send_to_user_async) so it never stalls the response.

import "core:crypto/ecdsa"
import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import http_client "odin_test:lib/http_client"

// WEBPUSH_TTL_SECONDS is the `TTL` header: how long the push service should try
// to deliver if the device is offline. One day matches the design doc.
WEBPUSH_TTL_SECONDS :: 86400

// Async_Send_Job carries an owned copy of the send arguments to a background
// thread. Owned strings are freed by the worker after send_to_user returns.
@(private = "file")
Async_Send_Job :: struct {
	service:       ^Push_Service,
	owner_user_id: domain.User_ID,
	payload_json:  string,
}

// send_to_user_async runs send_to_user on a background thread so the request
// path is never blocked by network I/O to push endpoints. It clones payload_json
// (the caller keeps ownership of the original). Best-effort: delivery failures
// are swallowed. No-op when push is disabled.
send_to_user_async :: proc(service: ^Push_Service, owner_user_id: domain.User_ID, payload_json: string) {
	if !push_send_enabled(service) {
		return
	}
	job := new(Async_Send_Job)
	job.service = service
	job.owner_user_id = owner_user_id
	job.payload_json = strings.clone(payload_json)
	thread.run_with_data(rawptr(job), async_send_entry)
}

@(private = "file")
async_send_entry :: proc(data: rawptr) {
	job := (^Async_Send_Job)(data)
	if job == nil do return
	defer {
		delete(job.payload_json)
		free(job)
	}
	_ = send_to_user(job.service, job.owner_user_id, job.payload_json)
}

// send_to_user encrypts payload_json and pushes it to every subscription owned
// by owner_user_id. Returns the number of successful deliveries. Subscriptions
// whose endpoint is Gone (404/410) are pruned. When push is disabled (no VAPID
// keypair) it is a no-op returning 0.
send_to_user :: proc(service: ^Push_Service, owner_user_id: domain.User_ID, payload_json: string) -> int {
	if !push_send_enabled(service) {
		return 0
	}

	subs, err := iface.push_subscription_list_by_owner(service.subscriptions, owner_user_id)
	if err.code != .None {
		return 0
	}
	defer delete(subs)
	if len(subs) == 0 {
		return 0
	}

	// Decode the VAPID private scalar + public key once for the whole batch.
	priv_bytes, priv_ok := base64url_decode(service.vapid.private_key)
	if !priv_ok {
		return 0
	}
	defer delete(priv_bytes)
	vapid_priv: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&vapid_priv)
	if !ecdsa.private_key_set_bytes(&vapid_priv, .SECP256R1, priv_bytes) {
		return 0
	}

	now_unix := time.time_to_unix(time.now())

	sent := 0
	for sub in subs {
		if send_to_subscription(service, &vapid_priv, sub, payload_json, now_unix) {
			sent += 1
		}
	}
	return sent
}

// send_to_subscription encrypts + delivers one message. Returns true on a 2xx
// push-service response. On 404/410 it prunes the subscription by id.
@(private = "file")
send_to_subscription :: proc(
	service: ^Push_Service,
	vapid_priv: ^ecdsa.Private_Key,
	sub: domain.Push_Subscription,
	payload_json: string,
	now_unix: i64,
) -> bool {
	ua_public, ua_ok := base64url_decode(sub.p256dh)
	if !ua_ok {
		return false
	}
	defer delete(ua_public)
	auth_secret, auth_ok := base64url_decode(sub.auth)
	if !auth_ok {
		return false
	}
	defer delete(auth_secret)

	enc, enc_ok := webpush_encrypt(transmute([]byte)payload_json, ua_public, auth_secret)
	if !enc_ok {
		return false
	}
	defer delete(enc.body)

	// VAPID JWT audience is the endpoint origin.
	audience, aud_ok := vapid_endpoint_audience(sub.endpoint)
	if !aud_ok {
		return false
	}
	defer delete(audience)
	claims := vapid_claims_for(audience, service.vapid.subject, now_unix)
	jwt, jwt_ok := vapid_sign_jwt(vapid_priv, claims)
	if !jwt_ok {
		return false
	}
	defer delete(jwt)
	authorization := vapid_authorization_header(jwt, service.vapid.public_key)
	defer delete(authorization)

	base_url, path, split_ok := split_endpoint(sub.endpoint)
	if !split_ok {
		return false
	}
	defer delete(base_url)
	defer delete(path)

	headers := []http_client.Header{
		{name = "Authorization", value = authorization},
		{name = "Content-Encoding", value = "aes128gcm"},
		{name = "Content-Type", value = "application/octet-stream"},
		{name = "TTL", value = fmt.tprintf("%d", WEBPUSH_TTL_SECONDS)},
	}

	resp, ok := http_client.request_with_headers_timeout(
		"POST",
		base_url,
		path,
		string(enc.body),
		headers,
		http_client.DEFAULT_TIMEOUT_MS,
	)
	if !ok {
		return false
	}

	// Prune subscriptions the push service reports as permanently gone.
	if resp.status == 404 || resp.status == 410 {
		_, _ = iface.push_subscription_delete_by_id(service.subscriptions, sub.id)
		return false
	}
	return resp.status >= 200 && resp.status < 300
}

// split_endpoint splits a push endpoint URL into (base_url, path) for the
// http_client, e.g. "https://web.push.apple.com/abc?x=1" ->
// ("https://web.push.apple.com", "/abc?x=1"). The returned strings are owned by
// the caller.
split_endpoint :: proc(endpoint: string, allocator := context.allocator) -> (string, string, bool) {
	scheme_end := strings.index(endpoint, "://")
	if scheme_end <= 0 {
		return "", "", false
	}
	rest := endpoint[scheme_end + 3:]
	slash := strings.index_byte(rest, '/')
	if slash < 0 {
		// No path component; target root.
		return strings.clone(endpoint, allocator), strings.clone("/", allocator), true
	}
	base := endpoint[:scheme_end + 3 + slash]
	path := endpoint[scheme_end + 3 + slash:]
	return strings.clone(base, allocator), strings.clone(path, allocator), true
}
