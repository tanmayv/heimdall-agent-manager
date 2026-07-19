#!/usr/bin/env python3
"""Retired pre-bridge fresh-home federation message E2E.

This test depended on daemon-owned [[peer]] config and POST
/federation/peers/reconnect. Federation v2 moved those responsibilities to
ham-bridge. The bridge-native two-homes and disconnect/recovery suites now own
active message-delivery coverage for fresh isolated homes.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in [
    "tests/test_bridge_federation_two_homes_e2e.py",
    "tests/test_bridge_federation_disconnect_recovery_e2e.py",
]:
    if not (ROOT / rel).exists():
        raise SystemExit(f"missing superseding bridge suite: {rel}")

print("federation_fresh_home_peer_messages: retired (superseded by bridge two-home coverage)")
