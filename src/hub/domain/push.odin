package domain

// Push_Subscription is a browser Web Push subscription owned by a user. It
// mirrors the browser's `PushSubscription.toJSON()`: `endpoint` is the push
// service URL, `p256dh` is the client public key, and `auth` is the shared
// authentication secret (both base64url). Endpoints are unique — re-subscribing
// with the same endpoint upserts (replaces the keys) rather than duplicating.
Push_Subscription :: struct {
	id:            Push_Subscription_ID,
	owner_user_id: User_ID,
	endpoint:      string,
	p256dh:        string,
	auth:          string,
	created_at:    string,
	updated_at:    string,
}
