#!/usr/bin/env python3
"""REQ-SHELL-6 static guards — the invariants a truth table cannot express.

The behavioural decisions live in tests/ui_shell_req6_predicates_test.sh, which runs the
real predicates. What is left here is structural, and each of these is a rule that a
future edit could break silently:

- AC1  a user cannot start a run from the UI by ANY path — the picker, and the
       verb menu, where restart would otherwise start one
- AC5  no poller survives in the shells UI, except the two JUSTIFIED exceptions
- §6   the push channel the UI listens on is the one the hub actually publishes
- §7   the three output states are distinguished by the hub's error CODE, not by
       string-matching a human-readable message
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SHELLS = ROOT / "src" / "ui" / "components" / "shells"
NEW_SHELL_DIALOG = SHELLS / "NewShellDialog.tsx"
SHELL_MODEL = SHELLS / "shellModel.ts"
WS_INVALIDATION = ROOT / "src" / "ui" / "api" / "wsInvalidation.ts"
COOKIE_FETCH = ROOT / "src" / "ui" / "api" / "cookieFetch.ts"
SHELLS_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "shells.ts"
PANE_SUBSCRIPTION = ROOT / "src" / "ui" / "hooks" / "useShellPaneSubscription.ts"

# The ONLY two timers allowed to remain, per the coordinator's ruling on REQ-SHELL-6 §6.
# Both are justified AT the line in their own source; see also REQ-SHELL-19.
#   useShellStream.ts          a WebSocket KEEPALIVE — sends a heartbeat on an open
#                              socket, fetches nothing, invalidates nothing.
#   useShellPaneSubscription   the LEGACY TERMINAL TRANSPORT, whose replacement is gated
#                              server-side by the streaming_terminal_pane experiment.
#                              Deleting it would leave a terminal that never paints.
JUSTIFIED_TIMER_FILES = {"useShellStream.ts"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def strip_comments(src: str) -> str:
    """Drop // and /* */ comments so a comment naming a poller is not read as one."""
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return src


def test_ac1_user_cannot_start_a_run() -> None:
    require(NEW_SHELL_DIALOG.is_file(), f"NewShellDialog.tsx must exist at {NEW_SHELL_DIALOG}")
    code = strip_comments(NEW_SHELL_DIALOG.read_text(encoding="utf-8"))

    # `run` must not be offerable — not as an option, and not as a DISABLED option
    # either: AC1 says the UI must not present it at all.
    require(not re.search(r"value:\s*'run'", code),
            "NewShellDialog must not offer kind 'run' — a user can never start a run (AC1)")
    require(not re.search(r"'agent'", code),
            "NewShellDialog must not reference the dropped 'agent' kind")

    # The two kinds a user MAY start must both still be there, so this guard fails loudly
    # if the picker is emptied rather than silently passing on an empty list.
    require(re.search(r"value:\s*'shell'", code), "NewShellDialog must offer kind 'shell'")
    require(re.search(r"value:\s*'server'", code), "NewShellDialog must offer kind 'server'")


def test_ac1_no_verb_can_restart_a_run() -> None:
    """AC1's SECOND path, found by #26: restart.

    Gating the NewShellDialog picker closes the obvious way a user starts a run and leaves
    this one open. The owner-wide /shells listing attaches no kind clause, so run rows do
    reach the list, and ShellRow renders whatever `verbsForSession` returns — restart among
    them, both live and terminal. The service-side check is no backstop either: ownership is
    all `shell_session_restart` verifies; the starter rule is consulted only in
    `shell_session_start`.

    The BEHAVIOUR is proved exhaustively over kind x state by tests/ui/shell_req6_predicates.mjs,
    which runs the real predicate. What this guard adds is different and not redundant: a regex
    cannot tell a CORRECT gate from a wrong one, but it can stop the gate being quietly DELETED
    later — which is precisely how this hole came to exist while a static AC1 test passed.
    """
    require(SHELL_MODEL.is_file(), f"shellModel.ts must exist at {SHELL_MODEL}")
    code = strip_comments(SHELL_MODEL.read_text(encoding="utf-8"))

    match = re.search(r"export function verbsForSession\b.*?\n}", code, flags=re.S)
    require(match is not None, "shellModel.ts must export verbsForSession")
    body = match.group(0)

    gate = re.search(r"const\s+(\w+)\s*=\s*session\.kind\s*!==\s*'run'", body)
    require(gate is not None,
            "verbsForSession must gate on session.kind !== 'run' — restart is a second path "
            "by which a user would start a run (AC1)")
    flag = gate.group(1)

    # Every mention of the restart verb must sit behind that flag. verbsForSession returns
    # from TWO branches (terminal and live) and a gate covering only one of them is exactly
    # the hole #26 found, so checking the flag merely EXISTS would not be enough.
    restart_lines = [line.strip() for line in body.splitlines() if "'restart'" in line]
    require(restart_lines, "verbsForSession must still offer restart to the kinds that may have it")
    for line in restart_lines:
        require(flag in line,
                f"every 'restart' in verbsForSession must be gated by `{flag}`, but this "
                f"line is not: {line}")


def test_ac5_no_pollers_in_shells_ui() -> None:
    offenders = []
    for path in sorted(SHELLS.glob("*.ts*")) + [PANE_SUBSCRIPTION]:
        code = strip_comments(path.read_text(encoding="utf-8"))
        hits = []
        if "pollingInterval" in code:
            hits.append("pollingInterval")
        if re.search(r"\bsetInterval\s*\(", code):
            hits.append("setInterval")
        if not hits:
            continue
        # The pane subscription is allowed its one documented timer.
        if path == PANE_SUBSCRIPTION and hits == ["setInterval"]:
            continue
        if path.name in JUSTIFIED_TIMER_FILES and hits == ["setInterval"]:
            continue
        offenders.append(f"{path.name}: {', '.join(hits)}")

    require(not offenders,
            "REQ-SHELL-6 AC5: no poller may remain in the shells UI. Unjustified: "
            + "; ".join(offenders))

    # A pollingInterval is NEVER justified here — both survivors are setInterval.
    for path in sorted(SHELLS.glob("*.ts*")) + [PANE_SUBSCRIPTION]:
        code = strip_comments(path.read_text(encoding="utf-8"))
        require("pollingInterval" not in code,
                f"{path.name} must not use pollingInterval — the shells UI is push-driven (AC5)")


def test_section6_ui_listens_for_the_events_the_hub_sends() -> None:
    require(WS_INVALIDATION.is_file(), f"wsInvalidation.ts must exist at {WS_INVALIDATION}")
    code = WS_INVALIDATION.read_text(encoding="utf-8")

    # The hub publishes these two and nothing else for shell sessions:
    #   shell_session_exited                      (shell_session_service.odin:1342)
    #   resource_changed / "shell_session"        (shell_session_inventory.odin:427)
    # Before REQ-SHELL-6 the UI handled neither, and listened for a `shell_status` type
    # that no user-bus producer emits — so with the pollers gone nothing would repaint.
    require("'shell_session_exited'" in code,
            "wsInvalidation must handle 'shell_session_exited' — it is what the hub emits on exit")
    require("case 'shell_session':" in code,
            "wsInvalidation must handle resource_changed for resource 'shell_session' "
            "(the convergence adopt/correct path)")
    require("invalidateShellSession" in code,
            "wsInvalidation must route shell events through invalidateShellSession")

    # All three consumer tags must be invalidated, or one surface silently goes stale
    # with no poller left to cover it.
    helper = code[code.index("function invalidateShellSession"):]
    helper = helper[: helper.index("\n}\n") + 3]
    for tag in ("'ShellSessions'", "'ShellSession'", "'LIST'"):
        require(tag in helper, f"invalidateShellSession must invalidate {tag}")


def test_section7_output_states_keyed_on_error_code() -> None:
    fetch_code = COOKIE_FETCH.read_text(encoding="utf-8")
    # The code must survive the fetch boundary; without it the three states collapse.
    require("class ApiError" in fetch_code, "cookieFetch must define ApiError")
    require(re.search(r"readonly code\?:\s*string", fetch_code),
            "ApiError must carry the hub's machine-readable error code")
    require(re.search(r"readonly status\?:\s*number", fetch_code),
            "ApiError must carry the HTTP status")

    endpoint_code = SHELLS_ENDPOINT.read_text(encoding="utf-8")
    require("ShellLogUnavailableReason" in endpoint_code,
            "shells.ts must type the log-unavailability reasons")
    for code_name in ("'bridge_offline'", "'gone'"):
        require(code_name in endpoint_code,
                f"shells.ts must map the hub error code {code_name} to a reason")
    # 409/410 are the statuses the hub answers with; accepting them as a fallback keeps
    # the mapping working if a code is ever absent from the body.
    require("409" in endpoint_code and "410" in endpoint_code,
            "shells.ts must accept 409/410 as the status fallback for the two reasons")


def main() -> None:
    test_ac1_user_cannot_start_a_run()
    test_ac1_no_verb_can_restart_a_run()
    test_ac5_no_pollers_in_shells_ui()
    test_section6_ui_listens_for_the_events_the_hub_sends()
    test_section7_output_states_keyed_on_error_code()
    print("PASS: test_ui_shell_req6_static")


if __name__ == "__main__":
    main()
