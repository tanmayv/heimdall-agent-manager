#!/usr/bin/env python3
"""Retired pre-bridge federation dedupe E2E.

This scenario depended on daemon-owned [[peer]] config plus POST
/federation/peers/reconnect. Federation v2 moved peer management to ham-bridge,
so keeping this direct-daemon topology as an active test would make green
federation runs misleading.

Relevant bridge-native coverage now lives in:
- tests/test_bridge_federation_disconnect_recovery_e2e.py (eventual delivery + D6 dedupe)
- tests/test_federation_transport_static.py
- tests/test_bridge_relink_replay_static.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in [
    "tests/test_bridge_federation_disconnect_recovery_e2e.py",
    "tests/test_federation_transport_static.py",
    "tests/test_bridge_relink_replay_static.py",
]:
    if not (ROOT / rel).exists():
        raise SystemExit(f"missing superseding coverage: {rel}")

print("federation_transport_dedupe_e2e: retired (superseded by bridge federation coverage)")
