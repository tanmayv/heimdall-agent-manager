#!/usr/bin/env python3
"""Retired pre-bridge federation identity-collision E2E.

The original scenario assumed daemon-managed peer links plus explicit reconnect
RPCs. Federation v2 moved peer management to ham-bridge; this sentinel keeps
that obsolete topology out of active federation results until a bridge-native
identity-collision replacement is introduced.

Related surviving bridge-era coverage:
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

print("federation_phase3_identity_collision_e2e: retired (bridge-native replacement pending)")
