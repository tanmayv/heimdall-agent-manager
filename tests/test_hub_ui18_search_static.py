#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text()

def require(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)

def main() -> None:
    iface = read('src/hub/repository/iface/search_repo.odin')
    sqlite = read('src/hub/repository/sqlite/search_repo_sqlite.odin')
    service = read('src/hub/service/search/search_service.odin')
    handler = read('src/hub/transport/http/search_handlers.odin')
    wiring = read('src/hub/app/wiring.odin')
    migration = read('src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql')
    gap = read('docs/plans/ui-backend-gap-analysis.md')

    require('Search_Repository :: struct' in iface and 'Search_Query :: struct' in iface and 'Search_Hit :: struct' in iface, 'search repository interface missing')
    require('search: Search_Repository' in read('src/hub/repository/iface/repos.odin'), 'repositories must expose search repo')
    require('new_search_repository' in sqlite and 'new_search_service' in service, 'search repo/service wiring missing')
    require('"GET", "/api/v1/search"' in wiring and 'Search_Handlers' in wiring, 'search route must be registered')
    require('parse_api_query(req.query' in handler and 'types_csv' in handler and 'respond_search' in handler, 'search handler must parse q/types and use documented envelope')

    for typ in ['conversation', 'agent', 'agent_instance', 'task-chain', 'task', 'project', 'artifact', 'memory']:
        require(f'"{typ}"' in sqlite, f'missing supported type {typ}')
        require(f'"{typ}"' in handler, f'missing response grouping type {typ}')

    search_impl = service + sqlite + handler
    for marker in [
        'response_limit',
        'search_limit_from_query',
        'DEFAULT_SEARCH_LIMIT',
        'hard_scan_cap',
        'sort_hits_by_score_desc',
        'MAX_SEARCH_LIMIT :: 50',
        'MAX_SEARCH_SCAN_CAP :: 200',
        'q == ""',
        'prefix > word-boundary',
        'ORDER BY score DESC, updated_at DESC, id ASC LIMIT ?',
        'lower(name) LIKE lower(?) || \'%\'',
        'lower(title) LIKE lower(?) || \'%\'',
        'lower(?)',
    ]:
        require(marker in search_impl, f'missing bounded/ranking marker {marker}')

    forbidden_scan_fields = ['chat_messages', 'body AS', 'content AS', 'memories.body', 'artifacts.content']
    for forbidden in forbidden_scan_fields:
        require(forbidden not in sqlite, f'search must not scan full message/body/artifact content: {forbidden}')

    for idx in [
        'idx_search_agents_owner_lower_name',
        'idx_search_agent_instances_owner_lower_agent',
        'idx_search_chat_conversations_owner_lower_title',
        'idx_search_task_chains_owner_lower_title',
        'idx_search_tasks_owner_lower_title',
        'idx_search_projects_owner_lower_name',
        'idx_search_artifacts_owner_lower_name',
        'idx_search_memories_owner_lower_title',
    ]:
        require(idx in migration, f'missing search index {idx}')

    require('task-19f8ed3ac87' in gap and 'sub-100ms p95 server time' in gap, 'UI-18 gap context must mention search follow-up requirements')
    print('PASS: hub UI-18 search static')

if __name__ == '__main__':
    main()
