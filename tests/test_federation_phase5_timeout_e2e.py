#!/usr/bin/env python3
"""Retired pre-bridge federation timeout E2E.

The original timeout path exercised POST /federation/peers/reconnect against a
hanging daemon peer. Federation v2 moved that control plane to ham-bridge, so
this direct-daemon timeout scenario is no longer an active federation behavior.

Current bridge-era delivery/retry coverage:
- tests/test_bridge_federation_disconnect_recovery_e2e.py
- tests/test_federation_delivery_outbox_backoff_static.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in [
    "tests/test_bridge_federation_disconnect_recovery_e2e.py",
    "tests/test_federation_delivery_outbox_backoff_static.py",
]:
    if not (ROOT / rel).exists():
        raise SystemExit(f"missing bridge-era coverage: {rel}")

print("federation_phase5_timeout_e2e: retired (bridge-native timeout replacement pending)")
