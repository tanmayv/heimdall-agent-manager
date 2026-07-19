#!/usr/bin/env python3
"""Retired pre-bridge remote-proxy identity E2E.

The original test assumed daemon-managed peer links and direct reconnect RPCs.
Federation v2 moved peer management to ham-bridge, so this file is retained as a
retirement marker rather than an active direct-daemon topology test.

Bridge-era identity/bind coverage now lives in:
- tests/test_bridge_federation_two_homes_e2e.py
- tests/test_federation_peer_backend_static.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in [
    "tests/test_bridge_federation_two_homes_e2e.py",
    "tests/test_federation_peer_backend_static.py",
]:
    if not (ROOT / rel).exists():
        raise SystemExit(f"missing bridge-era coverage: {rel}")

print("remote_proxy_identity_e2e: retired (superseded by bridge-era proxy coverage)")
