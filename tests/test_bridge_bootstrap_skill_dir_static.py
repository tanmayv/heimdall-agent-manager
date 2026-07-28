#!/usr/bin/env python3
"""Static regression for Bridge skill bootstrap materialization."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROVIDER_STORE = ROOT / "src" / "bridge" / "provider_store.odin"
BOOTSTRAP = ROOT / "src" / "bridge" / "bootstrap_service.odin"
AGENT_SERVICE = ROOT / "src" / "hub" / "service" / "agent" / "agent_service.odin"
TASKCHAIN_OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"
DOMAIN_CONTENT = ROOT / "src" / "hub" / "domain" / "content.odin"
CONTENT_REPO = ROOT / "src" / "hub" / "repository" / "sqlite" / "content_repo_sqlite.odin"
CONTENT_SERVICE = ROOT / "src" / "hub" / "service" / "content" / "content_service.odin"
CONTENT_HANDLERS = ROOT / "src" / "hub" / "transport" / "http" / "content_handlers.odin"
MIGRATIONS = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations.odin"
MEMORY_CATALOG = ROOT / "src" / "ui" / "api" / "memoryCatalog.ts"


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def main() -> None:
    provider_store = PROVIDER_STORE.read_text(encoding="utf-8")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    agent_service = AGENT_SERVICE.read_text(encoding="utf-8")
    overview = TASKCHAIN_OVERVIEW.read_text(encoding="utf-8")
    domain_content = DOMAIN_CONTENT.read_text(encoding="utf-8")
    content_repo = CONTENT_REPO.read_text(encoding="utf-8")
    content_service = CONTENT_SERVICE.read_text(encoding="utf-8")
    content_handlers = CONTENT_HANDLERS.read_text(encoding="utf-8")
    migrations = MIGRATIONS.read_text(encoding="utf-8")
    memory_catalog = MEMORY_CATALOG.read_text(encoding="utf-8")

    for marker in [
        "skill_dir = bridge_provider_skill_dir_from_config(cmd)",
        "if strings.to_lower(key) == \"skills\"",
        "bridge_provider_default_skill_dir",
        'return ".pi/skills"',
        'return ".agents/skills"',
        'return "skills"',
    ]:
        require(marker in provider_store, f"provider profile must derive/fallback skill dir: {marker}")

    for marker in [
        "bridge_bootstrap_write_skills",
        "bridge_provider_json_extract_array(body, \"skills\")",
        "bridge_provider_json_top_level_objects(skills_array)",
        "if skill_dir == \"\" do skill_dir = bridge_provider_default_skill_dir(provider)",
        "bridge_bootstrap_write_skill_file(run_dir, path, content)",
        "bridge_bootstrap_write_skill_file(run_dir, skill_path, skill_content)",
    ]:
        require(marker in bootstrap, f"Bridge bootstrap must materialize all skill files: {marker}")

    for marker in [
        "write_bootstrap_skill_fields",
        "\\\"skills\\\":[",
        "m.type != .Skill",
        "bootstrap_memory_applies(m, service, owner, inst)",
        "domain.memory_type_string(m.type)",
        "string(m.project_id) != \"\" && m.project_id != inst.project_id",
        "agent.template_id != m.template_id",
        "m.bridge_id != inst.bridge_id",
        "Heimdall CLI communication basics",
        "./.heimdall/bin/ham-ctl",
    ]:
        require(marker in agent_service, f"hub bootstrap should emit scoped matching skills: {marker}")

    for marker in [
        "Memory_Type :: enum",
        "Fact,",
        "Habit,",
        "Episode,",
        "Expertise,",
        "Skill,",
    ]:
        require(marker in domain_content, f"memory kind should be enum without template kind: {marker}")
    require("Template," not in domain_content, "template must not be a memory kind")
    require("template_id: string" in domain_content and "bridge_id: string" in domain_content, "template/bridge must be optional memory scopes")

    for marker in [
        "project_id, template_id, bridge_id, type",
        "domain.memory_type_string(m.type)",
        "domain.memory_type_from_string(column_text",
    ]:
        require(marker in content_repo, f"content repository must persist scoped enum memory: {marker}")

    for marker in [
        "bridge_id,title",
        "bridge_owned",
        "domain.memory_type_from_string(json_string(body,\"type\"))",
        "target_bridge_id",
        "target_template_id",
    ]:
        require(marker in content_service + content_handlers, f"memory API must accept optional scopes: {marker}")

    require("upgrade_memory_target_scope_schema" in migrations and "bridge_id" in migrations, "migration upgrade must add optional memory scopes")
    require("targetBridgeId" in memory_catalog and "targetTemplateId" in memory_catalog, "UI memory catalog must normalize/filter bridge/template scopes")

    agents_md = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    require('data-debug-id={`taskchain-task-description-${taskId}`}' in overview, "chat task chain task rows must show task descriptions")
    require('taskchain-task-description-${taskId}' in agents_md, "task description debug id must be documented")
    require('whitespace-pre-wrap' in overview, "task descriptions should preserve line breaks")

    print("PASS: bridge bootstrap skills static")


if __name__ == "__main__":
    main()
