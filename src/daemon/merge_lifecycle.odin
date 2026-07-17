package main

import "core:net"
import "core:strings"
import vcs "odin_test:lib/vcs"

// Task 16 — merge lifecycle on chain completion.
// Implements docs/teams-v1/03-lifecycle.md §3.4 (non-VCS: archive team immediately)
// and §3.5 (VCS: surface Merge_Decision_Pending attention item; archive after decision).
//
// Storage is lazy: the merge-pending state lives on the existing
// `vcs_workspaces.status` column (`merge_pending`), so no new chain column/event
// is introduced. `GET /attention` derives merge_decisions from that column.

MERGE_PENDING_STATUS :: "merge_pending"

// Called from the Chain_Completed path in task_service_chain_status_command.
// Non-VCS chain → archive team now. VCS chain → mark workspace merge_pending and
// notify operator@local via the durable user fanout.
merge_lifecycle_on_chain_completed :: proc(chain_id, author: string) {
	team_id := merge_lifecycle_team_id(chain_id)
	rec, has_ws := vcs_db_workspace_for_chain(chain_id)
	if !has_ws {
		// §3.4 non-VCS: archive team immediately.
		if team_id != "" do _ = team_service_archive(team_id, "chain_completed_no_vcs")
		return
	}
	// §3.5 VCS: do NOT archive yet. Compute a merge preview so the operator sees
	// conflicts/commands up front, then surface a merge decision.
	backend := vcs.vcs_backend_for(vcs_handle_from_record(rec).kind)
	preview, _, _ := backend.merge_preview(vcs_handle_from_record(rec), rec.base_ref)
	_ = vcs_db_update_status(chain_id, MERGE_PENDING_STATUS)
	user_client_fanout_all_ws_text(merge_decision_pending_json(chain_id, rec, preview))
}

// Finalize the decision after operator action (merge succeeded, keep, or abandon).
// Archives the team; the workspace status is set by the caller (merged/archived/kept).
merge_lifecycle_finalize_decision :: proc(chain_id: string) {
	team_id := merge_lifecycle_team_id(chain_id)
	if team_id != "" do _ = team_service_archive(team_id, "merge_decision_recorded")
}

merge_lifecycle_team_id :: proc(chain_id: string) -> string {
	if chain, ok := store_get_chain(chain_id); ok {
		if tid := task_chain_effective_team_id(chain); tid != "" do return tid
	}
	if team, ok := team_db_get_team_by_chain_id(team_service_db, chain_id); ok do return team.team_id
	return ""
}

merge_decision_pending_json :: proc(chain_id: string, rec: Vcs_Workspace_Record, preview: vcs.Vcs_Merge_Preview) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"merge_decision_pending","chain_id":"`); json_write_string(&b, chain_id)
	strings.write_string(&b, `","workspace_id":"`); json_write_string(&b, rec.workspace_id)
	strings.write_string(&b, `","vcs_kind":"`); json_write_string(&b, rec.vcs_kind)
	strings.write_string(&b, `","branch_or_change":"`); json_write_string(&b, rec.branch_or_change)
	strings.write_string(&b, `","base_ref":"`); json_write_string(&b, rec.base_ref)
	strings.write_string(&b, `","preview":`); merge_preview_body_json(&b, preview)
	strings.write_string(&b, `,"recipient":"`); json_write_string(&b, HUMAN_RECIPIENT_ID); strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

merge_preview_body_json :: proc(b: ^strings.Builder, p: vcs.Vcs_Merge_Preview) {
	strings.write_string(b, `{"can_fast_forward":`); strings.write_string(b, "true" if p.can_fast_forward else "false")
	strings.write_string(b, `,"summary":"`); json_write_string(b, p.summary); strings.write_string(b, `","conflicts":[`)
	for c, i in p.conflicts { if i > 0 do strings.write_string(b, `,`); strings.write_string(b, `"`); json_write_string(b, c); strings.write_string(b, `"`) }
	strings.write_string(b, `],"commands":[`)
	for c, i in p.commands { if i > 0 do strings.write_string(b, `,`); strings.write_string(b, `"`); json_write_string(b, c); strings.write_string(b, `"`) }
	strings.write_string(b, `]}`)
}

// GET /attention — aggregated operator view. Merge decisions are derived from
// workspaces sitting in `merge_pending`. Blocked federation review gates are
// surfaced here too so operators can unblock unreachable remote reviewers using
// the existing participant/reviewer mutation flow.
handle_attention :: proc(client: net.TCP_Socket, request: string) {
	if !workspace_query_auth(client, request_target_of(request)) do return
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"approvals":[],"blocked":[`)
	blocked_first := true
	for item in attention_federation_peer_blocks_json_items() {
		if !blocked_first do strings.write_string(&b, `,`)
		blocked_first = false
		strings.write_string(&b, item)
		delete(item)
	}
	strings.write_string(&b, `],"merge_decisions":[`)
	first := true
	rows := vcs_db_merge_pending_workspaces()
	for rec in rows {
		if !first do strings.write_string(&b, `,`)
		first = false
		merge_decision_item_json(&b, rec)
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

merge_decision_item_json :: proc(b: ^strings.Builder, rec: Vcs_Workspace_Record) {
	backend := vcs.vcs_backend_for(vcs_handle_from_record(rec).kind)
	preview, _, _ := backend.merge_preview(vcs_handle_from_record(rec), rec.base_ref)
	strings.write_string(b, `{"chain_id":"`); json_write_string(b, rec.chain_id)
	strings.write_string(b, `","workspace_id":"`); json_write_string(b, rec.workspace_id)
	strings.write_string(b, `","project_id":"`); json_write_string(b, rec.project_id)
	strings.write_string(b, `","vcs_kind":"`); json_write_string(b, rec.vcs_kind)
	strings.write_string(b, `","branch_or_change":"`); json_write_string(b, rec.branch_or_change)
	strings.write_string(b, `","base_ref":"`); json_write_string(b, rec.base_ref)
	strings.write_string(b, `","path":"`); json_write_string(b, rec.path)
	strings.write_string(b, `","preview":`); merge_preview_body_json(b, preview)
	strings.write_string(b, `}`)
}

attention_federation_peer_blocks_json_items :: proc() -> []string {
	items := make([dynamic]string)
	tasks := store_all_tasks()
	defer delete(tasks)
	for state in tasks {
		if state.status != .Review_Ready do continue
		participants := store_participants_of(state.task_id)
		for participant in participants {
			if participant.role != "lgtm_required" do continue
			if store_reviewer_has_approved_vote(state.task_id, participant.agent_instance_id) do continue
			if idx := agent_record_index_by_instance(participant.agent_instance_id); idx >= 0 && agent_record_is_remote_proxy(agent_instance_records[idx]) {
				peer_id, _, ok := agent_remote_proxy_lookup(participant.agent_instance_id)
				if !ok || peer_id == "" do continue
				peer_rec, found := peer_link_find(peer_id)
				if !found || peer_rec.status != PEER_STATUS_UNREACHABLE do continue
				chain_title := ""
				if chain, chain_found := store_get_chain(state.chain_id); chain_found do chain_title = chain.title
				item := strings.builder_make()
				strings.write_string(&item, `{"kind":"federation_peer_block","task_id":"`); json_write_string(&item, state.task_id)
				strings.write_string(&item, `","chain_id":"`); json_write_string(&item, state.chain_id)
				strings.write_string(&item, `","task_title":"`); json_write_string(&item, state.title)
				strings.write_string(&item, `","chain_title":"`); json_write_string(&item, chain_title)
				strings.write_string(&item, `","peer_id":"`); json_write_string(&item, peer_rec.peer_id)
				strings.write_string(&item, `","peer_daemon_id":"`); json_write_string(&item, peer_rec.daemon_id)
				strings.write_string(&item, `","peer_status":"`); json_write_string(&item, peer_rec.status)
				strings.write_string(&item, `","proxy_agent_instance_id":"`); json_write_string(&item, participant.agent_instance_id)
				strings.write_string(&item, `","reviewer_role":"`); json_write_string(&item, participant.role)
				strings.write_string(&item, `"}`)
				append(&items, strings.to_string(item))
			}
		}
		delete(participants)
	}
	return items[:]
}

request_target_of :: proc(request: string) -> string {
	_, target := http_method_target(request)
	return target
}
