#!/usr/bin/env python3
"""Retired pre-bridge federation artifact/attention replay E2E.

This scenario was built on daemon-owned peer links plus reconnect RPCs. In
federation v2, peer orchestration lives in ham-bridge, so the old direct-daemon
flow is intentionally retired to keep federation results aligned with the active
architecture.

Related bridge-era coverage is now split across:
- tests/test_bridge_federation_disconnect_recovery_e2e.py
- tests/test_bridge_artifact_fetch_large_e2e.py
- tests/test_federation_transport_static.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in [
    "tests/test_bridge_federation_disconnect_recovery_e2e.py",
    "tests/test_bridge_artifact_fetch_large_e2e.py",
    "tests/test_federation_transport_static.py",
]:
    if not (ROOT / rel).exists():
        raise SystemExit(f"missing related bridge-era coverage: {rel}")

print("federation_phase45_artifact_attention_replay_e2e: retired (direct-daemon topology removed in bridge v2)")
