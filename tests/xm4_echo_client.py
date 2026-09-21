#!/usr/bin/env python3
"""Echo client for the REQ-XM-4 proxy path end-to-end test.

Talks ONLY to the ORIGINATING bridge's local proxy endpoint. It never contacts the
hub, the target bridge, or the echo server directly — that is the point: every byte
travels

    client -> bridge A local endpoint -> hub -> bridge B -> echo server

and all the way back. If this script passes, the full chain carried the payload
intact in both directions.

Stdlib only, so it runs anywhere in the dev stack.

  usage:
    xm4_echo_client.py --endpoint 127.0.0.1:49626 --session-id sh_xxx [--rounds N]

  Point it at an existing stack by passing the originating bridge's
  --local-endpoint-port as --endpoint and any running kind=server session id that
  hosts xm4_echo_server.py as --session-id.

Exit code 0 = every round trip returned byte-identical payload.
"""
import argparse
import hashlib
import http.client
import sys


def make_payloads():
    """Payloads chosen to exercise distinct failure modes, not just connectivity."""
    return [
        ("tiny-ascii", b"hello echo"),
        ("empty-ish", b"x"),
        # Non-ASCII + control bytes: catches anyone treating the body as text or
        # round-tripping it through a JSON string without base64.
        ("utf8-and-control", "héllo — ünïcode\t\r\n\x00\x01\x02 end".encode("utf-8")),
        # All 256 byte values: catches base64/encoding damage on specific bytes.
        ("all-byte-values", bytes(range(256)) * 4),
        # Larger than one 48KB tunnel frame: forces chunking, so this is the payload
        # that actually proves ordering and reassembly rather than mere connectivity.
        ("multi-frame-200k", bytes((i * 7 + 13) % 256 for i in range(200_000))),
    ]


def round_trip(endpoint, session_id, payload, timeout):
    host, port = endpoint.split(":")
    conn = http.client.HTTPConnection(host, int(port), timeout=timeout)
    try:
        conn.request(
            "POST",
            f"/proxy/{session_id}/echo",
            body=payload,
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(payload)),
            },
        )
        resp = conn.getresponse()
        returned = resp.read()
        return resp.status, returned
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True,
                    help="originating bridge local endpoint, host:port (e.g. 127.0.0.1:49626)")
    ap.add_argument("--session-id", required=True,
                    help="kind=server session id on the TARGET bridge running xm4_echo_server.py")
    ap.add_argument("--rounds", type=int, default=1,
                    help="repeat the whole payload set this many times")
    ap.add_argument("--timeout", type=float, default=30.0)
    args = ap.parse_args()

    payloads = make_payloads()
    failures = 0
    total = 0

    print(f"[client] talking to bridge local endpoint {args.endpoint}")
    print(f"[client] target session {args.session_id}")
    print(f"[client] {len(payloads)} payloads x {args.rounds} round(s)\n")

    for r in range(1, args.rounds + 1):
        for name, payload in payloads:
            total += 1
            sent_md5 = hashlib.md5(payload).hexdigest()
            try:
                status, returned = round_trip(
                    args.endpoint, args.session_id, payload, args.timeout)
            except Exception as exc:  # noqa: BLE001 - report, don't crash the suite
                print(f"  [r{r}] {name:<18} TRANSPORT ERROR: {exc}")
                failures += 1
                continue

            got_md5 = hashlib.md5(returned).hexdigest()
            identical = (returned == payload) and status == 200

            # Show the actual bytes for small payloads so the transcript is legible;
            # for large ones the md5 + length is the evidence.
            if len(payload) <= 64:
                shown_sent = repr(payload)
                shown_got = repr(returned)
                detail = f"sent={shown_sent} got={shown_got}"
            else:
                detail = (f"sent_bytes={len(payload)} got_bytes={len(returned)} "
                          f"sent_md5={sent_md5} got_md5={got_md5}")

            verdict = "IDENTICAL" if identical else "MISMATCH"
            print(f"  [r{r}] {name:<18} HTTP {status} {verdict}")
            print(f"        {detail}")
            if not identical:
                failures += 1

    print(f"\n[client] {total - failures}/{total} round trips returned byte-identical payloads")
    if failures:
        print(f"[client] FAIL — {failures} mismatch(es)")
        return 1
    print("[client] PASS — every payload survived the full chain intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
