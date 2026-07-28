#!/usr/bin/env python3
"""Static checks for HBR-11 Agent + AgentBridgeSupport API."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")

def test_agent_model_service_routes() -> None:
    domain = read(ROOT / "src/hub/domain/agent.odin")
    service = read(ROOT / "src/hub/service/agent/agent_service.odin")
    wiring = read(ROOT / "src/hub/app/wiring.odin")
    sql = read(ROOT / "src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql")
    for snippet in ["Agent :: struct", "Agent_Bridge_Support", "owner_user_id", "default_provider", "default_tier", "state"]:
        require(snippet in domain, f"domain missing {snippet}")
    for snippet in ["require_enabled_support", "resolve_provider_tier", "bridge_supports_provider_tier", "json_value_at", "json_tiers_array_contains", "replace_supports", "request > support override", "agent.default_provider", "default_tier_from_bridge"]:
        require(snippet in service, f"service missing HBR-11 marker {snippet}")
    for route in [
        '"GET", "/api/v1/agents"', '"POST", "/api/v1/agents"', '"PATCH", "/api/v1/agents/*"',
        '"POST", "/api/v1/agents/*/archive"', '"GET", "/api/v1/agents/*/bridge-support"',
        '"PUT", "/api/v1/agents/*/bridge-support"', '"PATCH", "/api/v1/agents/*/bridge-support/*"',
        '"DELETE", "/api/v1/agents/*/bridge-support/*"',
    ]:
        require(route in wiring, f"missing route {route}")
    for snippet in ["UNIQUE(owner_user_id, slug)", "agent_bridge_support", "provider TEXT", "tier TEXT", "max_instances"]:
        require(snippet in sql, f"migration missing {snippet}")

if __name__ == "__main__":
    test_agent_model_service_routes()
    print("PASS: hub phase6 static")
