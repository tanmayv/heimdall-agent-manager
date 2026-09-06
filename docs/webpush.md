# Web Push (iOS PWA background notifications)

Heimdall delivers OS notifications to a backgrounded/closed installed PWA using
the W3C Web Push pipeline, implemented natively in the Hub (no third-party
service). When an agent sends a chat message to the user, the Hub signs a VAPID
JWT, encrypts the payload per RFC 8291 (`aes128gcm`), and POSTs it to each of
the user's browser push subscriptions. A service worker (`public/notification-sw.js`)
renders the notification.

This document covers generating the VAPID keypair and running the Hub with it.

## VAPID keypair

The Hub needs one VAPID (RFC 8292) P-256 keypair:

- **Public key** — the uncompressed P-256 point (`0x04 || X || Y`, 65 bytes),
  base64url (unpadded). Served by `GET /api/v1/push/vapid-public-key` and used by
  the browser as `applicationServerKey` when subscribing.
- **Private key** — the 32-byte scalar, base64url (unpadded). Used by the Hub to
  sign VAPID JWTs. **Secret — never commit or log it.**

### Generate with OpenSSL

```sh
# 1. Generate a P-256 private key.
openssl ecparam -genkey -name prime256v1 -noout -out vapid.pem

# 2. Private key = the 32-byte scalar, base64url (unpadded).
#    Extracted robustly from the DER via asn1parse (the l=32 OCTET STRING).
VAPID_PRIVATE=$(openssl asn1parse -in vapid.pem \
  | awk '/OCTET STRING/{print}' \
  | grep -o 'HEX DUMP\]:[0-9A-F]*' | head -1 | cut -d: -f2 \
  | xxd -r -p | base64 | tr '+/' '-_' | tr -d '=')

# 3. Public key = the 65-byte uncompressed point, base64url (unpadded).
#    It is the last 65 bytes of the DER SubjectPublicKeyInfo.
VAPID_PUBLIC=$(openssl ec -in vapid.pem -pubout -outform DER 2>/dev/null \
  | tail -c 65 | base64 | tr '+/' '-_' | tr -d '=')

printf '%s' "$VAPID_PRIVATE" > vapid_private.key   # 0600, deploy as a secret
echo "public: $VAPID_PUBLIC"
```

Sanity checks (optional): the private key must decode to **32 bytes** and the
public key to **65 bytes starting with `0x04`**.

> The private key derives exactly the public key the Hub serves — verified by the
> crypto layer (`ecdsa.public_key_set_priv`). If you regenerate one, regenerate
> both; a mismatched pair makes every push fail with a 401/403 at the push service.

## Running the Hub with VAPID

Provide the public key inline and the private key via a file (recommended for
deploys so the secret never appears in the process args or logs):

```sh
ham-hub \
  --vapid-public-key "$VAPID_PUBLIC" \
  --vapid-private-key-file /run/secrets/vapid_private.key \
  --vapid-subject "mailto:you@example.com"
```

Or entirely via environment (flags override env):

| Setting        | Flag                        | Environment                          |
|----------------|-----------------------------|--------------------------------------|
| Public key     | `--vapid-public-key`        | `HEIMDALL_VAPID_PUBLIC_KEY`          |
| Private key    | `--vapid-private-key`       | `HEIMDALL_VAPID_PRIVATE_KEY`         |
| Private (file) | `--vapid-private-key-file`  | `HEIMDALL_VAPID_PRIVATE_KEY_FILE`    |
| JWT subject    | `--vapid-subject`           | `HEIMDALL_VAPID_SUBJECT`             |

Behavior:

- When both keys are present, the Hub logs `web push enabled` at startup.
- When either is missing, it logs `web push send disabled … endpoints remain
  active`: subscription endpoints still work, but no messages are sent.
- An unreadable `--vapid-private-key-file` path logs a `WARNING` to stderr and
  disables sending (rather than failing silently).
- The private key is never logged.

## Verifying the public key is served

```sh
curl -s http://127.0.0.1:8081/api/v1/push/vapid-public-key
# {"data":{"vapid_public_key":"BJv4kvdt7wNIAXEQ...GSoWWPc"}, ...}
```

The returned value must equal `$VAPID_PUBLIC`. The browser subscribe flow
(`NotificationsPanel`) fetches this and passes it to
`pushManager.subscribe({ userVisibleOnly: true, applicationServerKey })`.

## NixOS deploy note

The keypair is generated once (as above) and the **private key** is provided to
the Hub as a deployment secret via `--vapid-private-key-file` /
`HEIMDALL_VAPID_PRIVATE_KEY_FILE`. Wiring the secret into the NixOS config is
owned by the deploy/coordinator; workers only implement the flag/env reading.
The Hub serves only `/api/v1`; the service worker + web app manifest are served
same-origin by the reverse proxy/static host in production
(`https://heimdall.mundus.in`).

## On-device iOS verification

For iOS on-device verification, see the iOS PWA background-notification checklist
(WP-TEST-CLIENT deliverable), which is the authoritative source for the
device-side steps.
