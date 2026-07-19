#!/usr/bin/env python3
"""Retired pre-bridge remote-review federation E2E.

This test exercised the removed direct-daemon peer orchestration flow
(daemon-owned [[peer]] + /federation/peers/reconnect). Federation v2 moved peer
management to ham-bridge; this file now serves as an explicit retirement marker
so obsolete topology is not counted as active federation coverage.

Bridge-native transport/review plumbing coverage currently comes from:
- tests/test_bridge_federation_two_homes_e2e.py
- tests/test_bridge_federation_disconnect_recovery_e2e.py
- tests/test_federation_peer_backend_static.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in [
    "tests/test_bridge_federation_two_homes_e2e.py",
    "tests/test_bridge_federation_disconnect_recovery_e2e.py",
    "tests/test_federation_peer_backend_static.py",
]:
    if not (ROOT / rel).exists():
        raise SystemExit(f"missing bridge-era coverage: {rel}")

print("federation_phase3_remote_review_e2e: retired (direct-daemon topology removed in bridge v2)")
