package domain

// The search-type vocabulary. This lives in `domain` because BOTH the sqlite
// repository (which selects per-type queries) and the search service (which must
// reject an unknown scope before querying) legitimately need it, and the
// repository must not import the service nor the service the repository. It was
// previously defined in package sqlite, where the service could not reach it —
// which is why an invalid scope had no validation path and silently returned zero
// hits instead of an error (REQ-CLI-5). Exactly one list; do not copy it.

SEARCH_TYPE_ORDER :: [?]string{"conversation", "message", "agent", "agent_instance", "task-chain", "task", "comment", "project", "artifact", "memory", "skill"}

// normalize_search_type maps accepted `types` aliases to their canonical name.
// It is additive: every historical spelling still resolves, and new plural /
// short forms (and comment/skill for the upcoming providers) are accepted too.
//
// NOTE it returns UNRECOGNIZED input unchanged via the final `return t`. That
// fallthrough is what lets canonical names resolve without listing each one, and
// it is also exactly why a typo'd scope used to survive all the way to the query
// and match nothing. Callers validating a scope MUST check membership in
// SEARCH_TYPE_ORDER after normalizing (see search_type_is_valid) — normalization
// itself rejects nothing.
normalize_search_type :: proc(t: string) -> string {
	switch t {
	case "conversations": return "conversation"
	case "agents": return "agent"
	case "instance", "instances", "agent_instances": return "agent_instance"
	case "task_chain", "task_chains", "chain", "chains", "taskchain": return "task-chain"
	case "tasks": return "task"
	case "projects": return "project"
	case "artifacts": return "artifact"
	case "memories": return "memory"
	case "comments": return "comment"
	case "skills": return "skill"
	case "messages", "msg": return "message"
	}
	return t
}

// search_type_is_valid reports whether a single scope token names a real search
// type. Membership is checked AFTER normalizing, because normalize_search_type
// passes unknown input straight through — trusting it to reject would reproduce
// the very defect this guards against. `all` is the wildcard and is handled by
// the caller before normalization, so it is NOT valid here.
search_type_is_valid :: proc(token: string) -> bool {
	canonical := normalize_search_type(token)
	for known in SEARCH_TYPE_ORDER {
		if known == canonical do return true
	}
	return false
}

// search_type_names_csv renders the canonical vocabulary for error messages, so a
// rejection can tell the caller what IS accepted without a second hardcoded list.
search_type_names_csv :: proc(allocator := context.allocator) -> string {
	total := 0
	for name in SEARCH_TYPE_ORDER do total += len(name) + 2
	buf := make([dynamic]byte, 0, total + 5, allocator)
	for name, i in SEARCH_TYPE_ORDER {
		if i > 0 do append(&buf, ',', ' ')
		for j in 0 ..< len(name) do append(&buf, name[j])
	}
	append(&buf, ',', ' ', 'a', 'l', 'l')
	return string(buf[:])
}
