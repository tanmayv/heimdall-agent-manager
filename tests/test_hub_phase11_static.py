#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text()
def require(c,m):
    if not c: raise AssertionError(m)
def main():
    domain=read('src/hub/domain/content.odin')
    repo=read('src/hub/repository/iface/content_repo.odin')
    sqlite=read('src/hub/repository/sqlite/content_repo_sqlite.odin')
    service=read('src/hub/service/content/content_service.odin')
    handlers=read('src/hub/transport/http/content_handlers.odin')
    wiring=read('src/hub/app/wiring.odin')
    mig=read('src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql')
    for s in ['Memory :: struct','Chat_Conversation :: struct','Chat_Message :: struct','Artifact :: struct','Template :: struct','owner_user_id']:
        require(s in domain, f'missing domain {s}')
    for s in ['Content_Repository','content_save_memory','content_save_conversation','content_save_artifact','content_delete_artifact','content_save_template']:
        require(s in repo, f'missing repo API {s}')
    for table in ['memories','chat_conversations','chat_messages','artifacts','templates']:
        require(f'CREATE TABLE IF NOT EXISTS {table}' in mig, f'missing migration {table}')
    require('description TEXT NOT NULL DEFAULT' in mig and 'is_system INTEGER NOT NULL' in mig and 'agent_instance_id TEXT NOT NULL' in mig, 'migration missing HBR-17 fields')
    for s in ['approve_memory','reject_memory','archive_memory','artifacts_owned_json','validate_initial_message','artifact_context_owned','conversation_instance_binding_valid','project_get','taskchain_get_chain','taskchain_get_task','agent_get_instance','delete_artifact','create_template','owner_from_auth']:
        require(s in service, f'missing service behavior {s}')
    for route in ['"GET", "/api/v1/memories"','"POST", "/api/v1/chats"','"GET", "/api/v1/chats/*/messages"','"POST", "/api/v1/artifacts"','"PATCH", "/api/v1/artifacts/*"','"DELETE", "/api/v1/artifacts/*"','"GET", "/api/v1/templates"']:
        require(route in wiring, f'missing route {route}')
    require('message_body_for_response' in handlers and 'artifact_refs_have_missing' in service and 'unavailable/deleted' in service, 'deleted artifact placeholder must be conditional on missing refs')
    require('owner_user_id=?' in sqlite, 'SQLite repository must owner-filter lists/deletes')
    print('PASS: hub phase11 static')
if __name__=='__main__': main()
