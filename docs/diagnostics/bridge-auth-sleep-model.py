#!/usr/bin/env python3
"""Offline source-backed model; no network, credential files, clocks or services."""
from pathlib import Path
import hashlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REVISIONS = ["873aa65cb717c752b2b75db93fe29b62e3c93634",
             "ada2d4c8e76fdfaaf98f41e5f4ad96ded206cf04",
             "486f2e1dd6939e79b6f57577f457bde7d5b2ec79"]

def source(rev, path):
    return subprocess.check_output(["git", "show", f"{rev}:{path}"],
                                   cwd=ROOT, text=True)

def procedure(text, name):
    # Procedures here have unindented closing braces.
    return re.search(r"^" + re.escape(name) + r" :: proc\b.*?^}", text,
                     re.M | re.S).group(0)

flow_path = "src/bridge/enroll_device_flow.odin"
runtime_path = "src/bridge/hub_runtime_client.odin"
base_flow = source(REVISIONS[0], flow_path)
base_runtime = source(REVISIONS[0], runtime_path)
for rev in REVISIONS:
    flow = source(rev, flow_path)
    runtime = source(rev, runtime_path)
    assert flow == base_flow
    for name in ("bridge_hub_runtime_worker", "bridge_hub_reconnect_sleep",
                 "bridge_credential_reauth_drain", "bridge_hub_session_frame"):
        assert procedure(runtime, name) == procedure(base_runtime, name), name
    worker = procedure(runtime, "bridge_hub_runtime_worker")
    assert "credential := bridge_credential_snapshot()" in worker
    rejected = worker.split("if !ok {", 1)[1].split("// Nothing negotiated", 1)[0]
    assert "bridge_hub_reconnect_sleep" in rejected and "refresh" not in rejected
    expired = procedure(runtime, "bridge_hub_session_frame").split(
        'case "bridge_token_expired":', 1)[1].split("case ", 1)[0]
    assert "refresh" not in expired
    print("SOURCE_MATCH", rev, "refresh_file_sha256=" +
          hashlib.sha256(flow.encode()).hexdigest())

# Derived directly from bridge_refresh_delay_seconds (jitter byte 128).
ttl = int(re.search(r"BRIDGE_ACCESS_TOKEN_TTL_SECONDS :: (\d+)",
          source(REVISIONS[0], "src/hub/service/bridge/bridge_token_service.odin")).group(1))
base = ttl * 80 // 100
span = ttl * 5 // 100
delay = base + 128 * 2 * span // 255 - span
assert delay == 2880

# Model scheduler precondition: relative timer excludes system suspend.
# Token generation A minted at wall=awake=0; sleep at 600 for 7200 seconds.
awake_at_sleep, suspended = 600, 7200
resume_wall = awake_at_sleep + suspended
remaining = delay - awake_at_sleep
assert resume_wall > ttl + 60 and remaining == 2280
generation = "A"
for post_resume in (0, 30, 300, remaining - 1):
    assert post_resume < remaining
    assert generation == "A"  # snapshot is current; renewal has not run
    print("MODEL paused_timer", "post_resume_s=" + str(post_resume),
          "expired_generation=A", "refresh_attempts=0")
# At timer wake, a successful durable rotation changes the next snapshot.
generation = "B"
assert generation == "B"
print("MODEL paused_timer", "renewal_due_after_resume_s=" + str(remaining),
      "next_snapshot=B")
# Suspend-inclusive timer: due at resume. Thread scheduling still has two orders.
for order in ("refresh_first", "reconnect_first"):
    attempted = "B" if order == "refresh_first" else "A"
    assert attempted == ("B" if order == "refresh_first" else "A")
    print("MODEL inclusive_timer", order, "first_snapshot=" + attempted,
          "after_successful_rotation=B")
# This is a conditional model, not native suspend or end-to-end execution.
print("PASS source equivalence and 6 modeled ordering observations; native incident unproven")
