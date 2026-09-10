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
    migrations_odin = read('src/hub/repository/sqlite/migrations.odin')
    fts_migration = read('src/hub/repository/sqlite/migrations/029_search_fts_comments.sql')
    fts_all_migration = read('src/hub/repository/sqlite/migrations/030_search_fts_all.sql')
    search_fts = read('src/hub/repository/sqlite/search_fts.odin')
    agent_actions = read('src/hub/transport/http/agent_action_handlers.odin')
    bridge_agent = read('src/bridge/agent_api.odin')
    gap = read('docs/plans/ui-backend-gap-analysis.md')

    require('Search_Repository :: struct' in iface and 'Search_Query :: struct' in iface and 'Search_Hit :: struct' in iface, 'search repository interface missing')
    require('search: Search_Repository' in read('src/hub/repository/iface/repos.odin'), 'repositories must expose search repo')
    require('new_search_repository' in sqlite and 'new_search_service' in service, 'search repo/service wiring missing')
    require('"GET", "/api/v1/search"' in wiring and 'Search_Handlers' in wiring, 'search route must be registered')

    # SEARCH-7: agent.search RPC over instance tokens (same owner scoping + hit shape as REST).
    require('agent_action_search_handler' in agent_actions, 'agent.search action handler must exist')
    require('search_service.search_resources' in agent_actions, 'agent.search must delegate to the same search service (owner from the instance auth)')
    require('respond_search' in agent_actions and 'search_groups_json' in agent_actions, 'agent.search must return the identical grouped REST hit shape')
    require('"POST", "/api/v1/agent-actions/search"' in wiring and 'agent_action_search_handler' in wiring, 'agent.search route must be registered')
    require('"agent.search"' in bridge_agent and '/api/v1/agent-actions/search' in bridge_agent, 'bridge agent-API must map agent.search to the agent-action route (wrapper surface)')
    require('parse_api_query(req.query' in handler and 'types_csv' in handler and 'respond_search' in handler, 'search handler must parse q/types and use documented envelope')

    # SEARCH-8: TYPED per-parent id filters (+ negation) + exclude. scope_ids is
    # REMOVED (not aliased) across handler/service/iface/sqlite.
    for param in ['task_ids', 'chain_ids', 'project_ids', 'conversation_ids',
                  'not_in_task_ids', 'not_in_chain_ids', 'not_in_project_ids', 'not_in_conversation_ids']:
        require(param in handler, f'handler must allowlist + read {param}')
        require(param in service, f'service Search_Input must carry {param}')
        require(param in iface, f'iface Search_Query must carry {param}')
    require('exclude' in handler and 'exclude' in service and 'exclude' in iface, 'exclude must remain across layers')
    require('scope_ids' not in handler and 'scope_ids' not in service and 'scope_ids' not in iface and 'scope_ids' not in sqlite, 'scope_ids must be fully removed (SEARCH-8)')
    require('build_typed_scope_clause' in sqlite and 'scope_ids_blob' not in sqlite, 'sqlite repo must use typed scope columns, not the old blob')
    require('normalize_search_type' in sqlite, 'sqlite repo must normalize type aliases')
    require('WHERE owner_user_id = ?' in sqlite, 'typed filters must AND onto the existing owner-scoped WHERE (isolation)')
    for col in ['scope_task_id', 'scope_chain_id', 'scope_project_id', 'scope_conversation_id']:
        require(col in sqlite, f'providers must expose the precise typed column {col}')

    # SEARCH-2 rework (c): clean NESTED hit shape. KEEP id/label/sublabel/route/score;
    # nested parent {id,type} (null when N/A) + preview + matched_field. No flat fields.
    for field in ['"id\\":', '"label\\":', '"sublabel\\":', '"score\\":', '"route\\":', '"parent\\":', '"preview\\":', '"matched_field\\":']:
        require(field in handler, f'write_search_hit_json must emit {field}')
    require('"parent_id\\":' not in handler and '"parent_type\\":' not in handler, 'clean shape uses nested parent, not flat parent_id/parent_type')
    require('"id\\":\\"' in handler and '"type\\":\\"' in handler, 'parent object must carry nested id + type')
    require('parent_id' in iface and 'matched_field' in iface, 'iface Search_Hit must carry the parent/matched_field data')
    require('derive_matched_field' in sqlite, 'sqlite repo must derive matched_field from the score tier')

    # SEARCH-2 rework (a): real merge-stage cursor pagination.
    require('decode_search_cursor' in sqlite and 'encode_search_cursor' in sqlite, 'sqlite repo must encode/decode a real page cursor')
    require('next_cursor = encode_search_cursor' in sqlite, 'next_cursor must be a real cursor, not null')

    for typ in ['conversation', 'agent', 'agent_instance', 'task-chain', 'task', 'comment', 'project', 'artifact', 'memory', 'skill']:
        require(f'"{typ}"' in sqlite, f'missing supported type {typ}')
        require(f'"{typ}"' in handler, f'missing response grouping type {typ}')

    # SEARCH-3: comments + skills providers + preview extractor.
    require('run_comment_search' in sqlite and 'SEARCH_SQL_COMMENTS' in sqlite, 'comment provider must search task_comments')
    require('JOIN tasks t ON t.task_id = c.task_id AND t.owner_user_id = c.owner_user_id' in sqlite, 'comment provider must owner-scope BOTH the comment and its task via the JOIN')
    require('run_skill_search' in sqlite and 'impl.skills' in sqlite, 'skill provider must scan injected STATIC_SKILLS')
    require('/skills/' in sqlite, 'skill hits must carry a real viewer route')
    require('search_preview' in sqlite, 'preview snippet extractor must exist')

    search_impl = service + sqlite + handler
    for marker in [
        'response_limit',
        'search_limit_from_query',
        'DEFAULT_SEARCH_LIMIT',
        'hard_scan_cap',
        'hit_less',
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

    # SEARCH-6: comment body is searched via the FTS5 index (task_comments_fts),
    # NOT an unindexed full scan. POSITIVELY require the FTS MATCH + bounded
    # snippet() + bm25() path...
    require('task_comments_fts MATCH ?' in sqlite, 'comment search must use the FTS5 MATCH path')
    require('snippet(task_comments_fts' in sqlite, 'FTS preview must use bounded snippet()')
    require('bm25(task_comments_fts)' in sqlite, 'FTS relevance must use bm25()')
    # SEARCH-10: FTS5-everywhere. POSITIVELY require the per-table FTS MATCH + bm25
    # (field-weighted) + snippet() path, the secondary/body tier, and TYPE_PRIORITY.
    require('MATCH ?' in search_fts and 'bm25(' in search_fts and 'snippet(' in search_fts, 'entity FTS providers must use MATCH + bm25 + snippet')
    require('FTS_PROVIDERS' in search_fts and 'run_fts_search' in search_fts, 'FTS provider descriptors + runner must exist')
    require('FTS_TIER_SECONDARY :: 40' in search_fts, 'the canonical secondary/body match tier (40) must be defined so body-only matches are non-zero yet below any primary-field match (>=50)')
    require('type_priority' in search_fts and 'effective_score' in search_fts, 'static TYPE_PRIORITY boost + effective_score (pure emitted score, priority folded into ordering) must exist')
    require('run_fts_search' in sqlite and 'entity_fts_ready' in sqlite, 'dispatch must use FTS for entities when available')
    # ...while STILL banning unindexed full scans of the heavy content we never search
    # (checked across BOTH the LIKE repo and the FTS provider builder).
    forbidden_scan_fields = ['chat_messages', 'content AS', 'memories.body', 'artifacts.content']
    for forbidden in forbidden_scan_fields:
        require(forbidden not in sqlite and forbidden not in search_fts, f'search must not scan full message/artifact/memory content: {forbidden}')

    # SEARCH-6 migration 029: external-content FTS vtable + sync triggers + backfill,
    # wired as a fixed-array bump + embedded const + byte-identical on-disk twin.
    # (Renumbered 028->029 when landing on main, which already had a 028 migration.)
    require('029_search_fts_comments.sql' in migrations_odin, 'migration_order must include 029')
    require('MIGRATION_029_SEARCH_FTS_COMMENTS' in migrations_odin, 'embedded 029 constant must exist')
    require('fts5_available' in migrations_odin, 'run_migrations must guard on FTS5 availability (boot-safe)')
    import re as _re
    _m = _re.search(r'MIGRATION_029_SEARCH_FTS_COMMENTS :: `(.*?)`', migrations_odin, _re.S)
    require(_m is not None and _m.group(1) == fts_migration, 'embedded MIGRATION_029 must be byte-identical to the on-disk twin')
    for frag in ['USING fts5(', "content='task_comments'", 'task_comments_ai AFTER INSERT', 'task_comments_ad AFTER DELETE', 'task_comments_au AFTER UPDATE']:
        require(frag in fts_migration, f'029 migration missing FTS fragment: {frag}')

    # SEARCH-10 migration 030: per-table external-content FTS vtables for every
    # text scope; fixed-array [29]->[30] bump; embedded via #load of the twin.
    # (Renumbered 029->030 when landing on main.)
    require('030_search_fts_all.sql' in migrations_odin, 'migration_order must include 030')
    require('migration_order :: [30]string' in migrations_odin or 'migration_order :: [31]string' in migrations_odin, 'migration_order must be the fixed array')
    require('MIGRATION_030_SEARCH_FTS_ALL' in migrations_odin and '030_search_fts_all.sql", string)' in migrations_odin, 'embedded 030 must #load the byte-identical on-disk twin')
    for vt in ['chat_conversations_fts', 'agents_fts', 'agent_instances_fts', 'task_chains_fts', 'tasks_fts', 'projects_fts', 'artifacts_fts', 'memories_fts']:
        require(f'CREATE VIRTUAL TABLE IF NOT EXISTS {vt} USING fts5(' in fts_all_migration, f'030 missing FTS vtable {vt}')
        require(f'{vt.rsplit("_fts",1)[0]}_fts_ai AFTER INSERT' in fts_all_migration or f'_fts_ai AFTER INSERT' in fts_all_migration, f'030 missing sync trigger for {vt}')

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
