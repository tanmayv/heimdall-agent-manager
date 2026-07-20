from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SERVICE = (ROOT / "src/daemon/task_service.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)

require('state.status == .Approved || state.status == .Cancelled' in SERVICE, 'terminal approved/cancelled tasks must be protected')
require('terminal task status cannot be changed without force' in SERVICE, 'terminal status regression must return explicit error')
require('status_val != state.status' in SERVICE, 'same terminal status should stay idempotent')

print('task_terminal_status_static: ok')
