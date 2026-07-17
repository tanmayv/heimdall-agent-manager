from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TRANSPORT = (ROOT / 'src/daemon/federation_transport.odin').read_text(encoding='utf-8')
TASK_HTTP = (ROOT / 'src/daemon/task_http.odin').read_text(encoding='utf-8')
TASK_REST = (ROOT / 'src/daemon/task_rest.odin').read_text(encoding='utf-8')
TASK_DB = (ROOT / 'src/daemon/task_db_service.odin').read_text(encoding='utf-8')
ROUTER = (ROOT / 'src/daemon/rest_router.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


require('Federation_Remote_Work_Record :: struct' in TASK_DB, 'remote work record struct missing')
require('CREATE TABLE IF NOT EXISTS federation_remote_work' in TASK_DB, 'remote work table missing')
require('PRIMARY KEY (origin_daemon_id, task_id, local_agent_instance_id)' in TASK_DB, 'remote work primary key must include origin_daemon_id for mesh-safe identity')
require('federation_remote_work_upsert :: proc' in TASK_DB, 'remote work upsert helper missing')
require('federation_remote_work_find_task :: proc(origin_daemon_id, task_id, local_agent_instance_id: string)' in TASK_DB, 'remote work exact task lookup must include origin_daemon_id')
require('federation_remote_work_find_chain :: proc(origin_daemon_id, chain_id, local_agent_instance_id: string)' in TASK_DB, 'remote work exact chain lookup must include origin_daemon_id')
require('federation_remote_work_resolve_task :: proc' in TASK_DB, 'remote work task resolver missing')
require('federation_remote_work_resolve_chain :: proc' in TASK_DB, 'remote work chain resolver missing')
require('federation_remote_work_list_for_agent :: proc' in TASK_DB, 'remote work per-agent list lookup missing')
require('federation_remote_work_track_notification :: proc' in TRANSPORT, 'notification-to-remote-work tracker missing')
require('FEDERATION_ENVELOPE_TASK_COMMENT' in TRANSPORT and 'FEDERATION_ENVELOPE_TASK_VOTE' in TRANSPORT and 'FEDERATION_ENVELOPE_TASK_STATUS' in TRANSPORT, 'phase3 callback kinds missing')
require('json_write_string(&b, work.origin_daemon_id)' in TRANSPORT, 'callback payloads must target the owner origin_daemon_id, not the reviewer home daemon')
require('actor_origin_daemon_id' in TRANSPORT, 'callback payloads should keep reviewer/home daemon origin separate from owner origin')
require('federation_remote_task_authorized :: proc' in TRANSPORT, 'owner-side scoped task authorization helper missing')
require('handle_get_federation_task :: proc' in TRANSPORT, 'owner-side federated task show route missing')
require('handle_get_federation_task_comments :: proc' in TRANSPORT, 'owner-side federated task comments route missing')
require('handle_get_federation_task_chain :: proc' in TRANSPORT, 'owner-side federated chain show route missing')
require('handle_get_federation_task_chain_tasks :: proc' in TRANSPORT, 'owner-side federated chain tasks route missing')
require('case FEDERATION_ENVELOPE_TASK_COMMENT:' in TRANSPORT, 'callback handler must support remote task comments')
require('case FEDERATION_ENVELOPE_TASK_VOTE:' in TRANSPORT, 'callback handler must support remote task votes')
require('case FEDERATION_ENVELOPE_TASK_STATUS:' in TRANSPORT, 'callback handler must support remote task statuses')
require('target_origin_daemon_id == "" || target_origin_daemon_id != server_daemon_id || task_id == ""' in TRANSPORT, 'callback handlers must reject missing/wrong owner origin identity')
require('write_remote_task_callback_response :: proc' in TASK_HTTP, 'task HTTP should forward remote review callbacks')
require('ambiguous remote task identity; include origin_daemon_id with task_id' in TASK_HTTP, 'task HTTP should reject ambiguous bare remote task ids')
require('ambiguous remote chain identity; include origin_daemon_id with chain_id' in TASK_HTTP, 'task HTTP should reject ambiguous bare remote chain ids')
require('federation_remote_task_next_json(author)' in TASK_HTTP, 'task next should have remote fallback')
require('federation_remote_tasks_state_json(author)' in TASK_HTTP, 'task list should have remote fallback')
require('federation_remote_task_fetch_response(remote_work)' in TASK_HTTP, 'task show should forward remote task reads')
require('federation_remote_chain_fetch_response(remote_work)' in TASK_HTTP, 'task chain show should forward remote chain reads')
require('federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author)' in TASK_HTTP, 'task HTTP should resolve remote tasks by origin-aware identity')
require('federation_remote_work_resolve_chain(chain_id, remote_origin_daemon_id, author)' in TASK_HTTP, 'task HTTP should resolve remote chains by origin-aware identity')
require('federation_remote_task_fetch_response(remote_work)' in TASK_REST, 'REST task show should forward remote task reads')
require('federation_remote_chain_tasks_fetch_response(remote_work)' in TASK_REST, 'REST chain task listing should forward remote reads')
require('federation_remote_work_resolve_task(task_id, remote_origin_daemon_id, author)' in TASK_REST, 'REST task reads should resolve remote tasks by origin-aware identity')
require('federation_remote_work_resolve_chain(chain_id, remote_origin_daemon_id, author)' in TASK_REST, 'REST chain reads should resolve remote chains by origin-aware identity')
for snippet in [
    'ctx.segments[1] == "tasks" && ctx.method == "GET"',
    'ctx.segments[1] == "task-chains" && ctx.method == "GET"',
    'handle_get_federation_task(client, ctx.segments[2], ctx)',
    'handle_get_federation_task_comments(client, ctx.segments[2], ctx)',
    'handle_get_federation_task_chain(client, ctx.segments[2], ctx)',
    'handle_get_federation_task_chain_tasks(client, ctx.segments[2], ctx)',
]:
    require(snippet in ROUTER, f'missing router support for phase3 federation path: {snippet}')

print('federation_phase3_static: ok')
