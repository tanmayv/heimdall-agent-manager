package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import httpc "odin_test:lib/httpc"

// Task_Brief_Wire is the Task System v2 brief object carried under `brief` on
// every task read. Only the fields ham-ctl renders are typed; the hub stores the
// brief verbatim, so unknown keys (inputs, budget, output, …) are ignored.
Task_Brief_Wire :: struct {
	goal:         string   `json:"goal"`,
	acceptance:   []string `json:"acceptance"`,
	review_roles: []string `json:"review_roles"`,
	assignee:     string   `json:"assignee"`,
}

// Task_Blocked_On_Wire mirrors the hub's blocked_on object (zero value when the
// task is not blocked; the hub sends null then).
Task_Blocked_On_Wire :: struct {
	kind:   string `json:"kind"`,
	ref:    string `json:"ref"`,
	reason: string `json:"reason"`,
	since:  string `json:"since"`,
}

// Task_Created_Data_Wire is the subset of the Task System v2 task wire that the
// `tasks create` summary reads back: `state` replaces the old `status`, and
// `brief.assignee` / `brief.review_roles` replace assignee_ref / reviewer_refs.
Task_Created_Data_Wire :: struct {
	task_id:                string               `json:"task_id"`,
	state:                  string               `json:"state"`,
	kind:                   string               `json:"kind"`,
	attempt_no:             int                  `json:"attempt_no"`,
	brief:                  Task_Brief_Wire      `json:"brief"`,
	blocked_on:             Task_Blocked_On_Wire `json:"blocked_on"`,
	requires_user_approval: bool                 `json:"requires_user_approval"`,
	depends_on:             []string             `json:"depends_on"`,
	blocked:                bool                 `json:"blocked"`,
	bridge_id:              string               `json:"bridge_id"`,
}

Ctl_Transport_Kind :: enum {
	User,
	Agent,
}

Ctl_Transport :: struct {
	kind: Ctl_Transport_Kind,
	user_base_url: string,
	user_token: string,
	agent_endpoint: string,
	agent_token: string,
	// hub: user_base_url parsed once (resolve_ctl_transport) for the User kind.
	hub: Ctl_Hub,
}

// ctl_valid_task_priority gates --priority on task CREATE in both CLI modes.
// The Hub coerces an unrecognised priority to p2, so an unvalidated flag value
// would land silently at the default; REQ-CLI-2 requires a usage error instead.
// Create-only by design: the update path's existing behaviour is unchanged.
ctl_valid_task_priority :: proc(value: string) -> bool {
	switch value {
	case "p0", "p1", "p2": return true
	}
	return false
}

// ctl_user_token_removed reports (and explains) a Hub user token (hut_): the Hub
// no longer accepts them; users authenticate with OIDC only.
ctl_user_token_removed :: proc(user_tok: string) -> bool {
	if !strings.has_prefix(user_tok, "hut_") do return false
	fmt.println(`{"ok":false,"message":"Ninjy user tokens (hut_) were removed: the Hub accepts only OIDC sign-in for users. ham-ctl user mode is not available; run ham-ctl inside an agent instance (agent mode) or use the web UI."}`)
	return true
}

resolve_ctl_transport :: proc(args: []string) -> (Ctl_Transport, bool) {
	as_override := option_value(args, "--as", "")
	hub_url := hub_user_mode_url(args)
	user_tok := hub_user_mode_token(args)
	ag_endpoint := agent_mode_endpoint(args)
	ag_tok := agent_mode_token(args)

	if ctl_user_token_removed(user_tok) do return Ctl_Transport{}, false
	if as_override == "user" {
		if hub_url == "" || user_tok == "" {
			fmt.println(`{"ok":false,"message":"--as user requires --hub-url and --user-token (or HAM_HUB_URL and HAM_USER_TOKEN)"}`)
			return Ctl_Transport{}, false
		}
		return ctl_user_transport(hub_url, user_tok), true
	}

	if as_override == "agent" {
		if ag_endpoint == "" || ag_tok == "" {
			fmt.println(`{"ok":false,"message":"--as agent requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint and --agent-token)"}`)
			return Ctl_Transport{}, false
		}
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	if hub_url != "" && user_tok != "" {
		return ctl_user_transport(hub_url, user_tok), true
	}

	if ag_endpoint != "" && ag_tok != "" {
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	return ctl_user_transport(hub_url, user_tok), true
}

ctl_user_transport :: proc(hub_url, user_tok: string) -> Ctl_Transport {
	base := strings.trim_right(hub_url, "/")
	return Ctl_Transport{kind = .User, user_base_url = base, user_token = user_tok, hub = ctl_hub_make(base, user_tok)}
}

resolve_chain_id :: proc(transport: Ctl_Transport, args: []string) -> string {
	cid := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if cid != "" do return cid
	if transport.kind == .Agent {
		res, ok := ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.context.get", "{}")
		if ok {
			chain_id := extract_json_string_unescaped(res, "chain_id", "")
			if chain_id != "" do return chain_id
		}
	}
	return ""
}

// ctl_task_chain_token_usage: `task-chain token-usage [<chain-id>]` (T10) prints
// the hub's per-agent + chain-total token usage (GET .../token-usage) as JSON.
// The chain defaults to --chain, then (agent mode) the caller's own chain.
ctl_task_chain_token_usage :: proc(transport: Ctl_Transport, tokens: []string, args: []string) {
	chain_id := pos(tokens, 0)
	if chain_id == "" do chain_id = resolve_chain_id(transport, args)
	if chain_id == "" {
		fmt.println("usage: ham-ctl task-chain token-usage <chain-id>")
		os.exit(1)
	}
	ctl_tasks_request(transport, {method = .GET, path = ctl_api("task-chains", chain_id, "token-usage")})
}

// Ctl_Directory_Body: chain directory add/update. --vcs-info holding a JSON
// object is sent as `vcs`; any other --vcs-info value is a vcs_kind (and wins
// over --vcs-kind, as the later duplicate key did).
Ctl_Directory_Body :: struct {
	path:      string     `json:"path,omitempty"`,
	bridge_id: string     `json:"bridge_id,omitempty"`,
	vcs_kind:  string     `json:"vcs_kind,omitempty"`,
	vcs:       json.Value `json:"vcs,omitempty"`,
}

// Ctl_Task_Update_Body: presence-checked flags (reviewers, approval, bridge,
// depends_on) are Maybe so an explicit empty value is still sent.
Ctl_Task_Update_Body :: struct {
    expected_requirements_revision: Maybe(int) `json:"expected_requirements_revision,omitempty"`,
    requirements_reason: string `json:"requirements_reason,omitempty"`,
    request_id: string `json:"request_id,omitempty"`,
	title:                  string          `json:"title,omitempty"`,
	description:            string          `json:"description,omitempty"`,
	priority:               string          `json:"priority,omitempty"`,
	assignee:               string          `json:"assignee,omitempty"`,
	reviewers:              Maybe([]string) `json:"reviewers,omitempty"`,
	requires_user_approval: Maybe(bool)     `json:"requires_user_approval,omitempty"`,
	bridge_id:              Maybe(string)   `json:"bridge_id,omitempty"`,
	depends_on:             Maybe([]string) `json:"depends_on,omitempty"`,
	brief:                  json.Value      `json:"brief,omitempty"`,
	replace_brief:          Maybe(bool)     `json:"replace_brief,omitempty"`,
}
