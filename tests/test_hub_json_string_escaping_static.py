#!/usr/bin/env python3
r"""Static regression for Hub JSON string escaping.

ANSI escape bytes from tmux output can land in chat previews and other response
strings. Raw control bytes (< 0x20) are invalid inside JSON strings, so every
Hub JSON writer must use the shared contracts writer that emits \u00XX escapes.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "src" / "contracts" / "envelope.odin"
HTTP_USERS = ROOT / "src" / "hub" / "transport" / "http" / "user_handlers.odin"
AGENT_SERVICE = ROOT / "src" / "hub" / "service" / "agent" / "agent_service.odin"
CONTENT_SERVICE = ROOT / "src" / "hub" / "service" / "content" / "content_service.odin"
EVENT_BUS = ROOT / "src" / "hub" / "service" / "events" / "event_bus.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    contracts = CONTRACTS.read_text(encoding="utf-8")
    http_users = HTTP_USERS.read_text(encoding="utf-8")
    agent_service = AGENT_SERVICE.read_text(encoding="utf-8")
    content_service = CONTENT_SERVICE.read_text(encoding="utf-8")
    event_bus = EVENT_BUS.read_text(encoding="utf-8")

    require("if ch < 0x20" in contracts, "contracts JSON writer must escape all control bytes")
    require('fmt.tprintf("\\\\u%04x", int(ch))' in contracts, "control bytes must be emitted as JSON unicode escapes")

    for name, text, marker in [
        ("http handler writer", http_users, "write_handler_json_string :: proc"),
        ("agent service writer", agent_service, "write_service_json_string :: proc"),
        ("content command writer", content_service, "content_json_write :: proc"),
        ("event bus writer", event_bus, "write_json_string :: proc"),
    ]:
        require(marker in text, f"missing {name}")
        require("contracts.write_json_string" in text, f"{name} must delegate to shared control-safe writer")

    print("PASS: Hub JSON string writers escape control bytes")


if __name__ == "__main__":
    main()
