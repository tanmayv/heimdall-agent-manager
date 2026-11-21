#!/usr/bin/env python3
"""Large-body client for the REQ-XM-4 proxy path (REQ-VOICE-6).

Sends ONE POST of --mb megabytes through a bridge's local proxy endpoint and reports
status, byte counts, md5 and wall time. It exists because a ~60 MB upload once hung
the relay and dropped the bridge's Hub WebSocket; the small-payload echo client never
got near the sizes that exposed that.

  usage:
    xm4_large_body_client.py --endpoint 127.0.0.1:49726 --session-id sh_xxx --mb 60 \
        [--expect echo|413] [--timeout 180]

--expect echo  (default) the target echoes the body; pass when HTTP 200 and the
               returned bytes are identical.
--expect 413   the relay must refuse the body up front; pass when HTTP 413 arrives
               within --fast-seconds (default 5) - "fail fast", not after a hang.

The body is generated deterministically and streamed, so the client itself never
holds more than one copy of it. Stdlib only.
"""
import argparse
import hashlib
import http.client
import sys
import time

CHUNK = 1 << 20


def body_chunks(total):
    # Deterministic, non-repeating-per-chunk content so a reordered or dropped chunk
    # changes the md5 rather than hiding behind identical blocks.
    i = 0
    sent = 0
    while sent < total:
        n = min(CHUNK, total - sent)
        seed = (i * 2654435761) & 0xFFFFFFFF
        block = (seed.to_bytes(4, "little") * (n // 4 + 1))[:n]
        yield block
        sent += n
        i += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--session-id", required=True)
    ap.add_argument("--mb", type=float, required=True)
    ap.add_argument("--expect", choices=["echo", "413"], default="echo")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--fast-seconds", type=float, default=5.0)
    args = ap.parse_args()

    total = int(args.mb * 1024 * 1024)
    sent_md5 = hashlib.md5()
    for c in body_chunks(total):
        sent_md5.update(c)

    host, port = args.endpoint.split(":")
    conn = http.client.HTTPConnection(host, int(port), timeout=args.timeout)
    started = time.monotonic()
    status = 0
    got = hashlib.md5()
    got_len = 0
    err = ""
    try:
        conn.putrequest("POST", f"/proxy/{args.session_id}/echo")
        conn.putheader("Content-Type", "application/octet-stream")
        conn.putheader("Content-Length", str(total))
        conn.endheaders()
        try:
            for c in body_chunks(total):
                conn.send(c)
        except (BrokenPipeError, ConnectionResetError) as exc:
            # A relay that refuses early may close before the body is all sent;
            # the response it wrote first is still readable.
            err = f"send stopped early: {exc}"
        resp = conn.getresponse()
        status = resp.status
        while True:
            b = resp.read(CHUNK)
            if not b:
                break
            got.update(b)
            got_len += len(b)
    except Exception as exc:  # noqa: BLE001 - report, never crash the suite
        err = f"{type(exc).__name__}: {exc}"
    finally:
        conn.close()
    elapsed = time.monotonic() - started

    print(f"[large] mb={args.mb} bytes={total} status={status} got_bytes={got_len} "
          f"elapsed_s={elapsed:.2f} sent_md5={sent_md5.hexdigest()} got_md5={got.hexdigest()}"
          + (f" note={err!r}" if err else ""))

    if args.expect == "echo":
        ok = status == 200 and got_len == total and got.hexdigest() == sent_md5.hexdigest()
    else:
        ok = status == 413 and elapsed <= args.fast_seconds
    print("[large] PASS" if ok else "[large] FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
