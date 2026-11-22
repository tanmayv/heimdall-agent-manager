package placement

import "base:runtime"
Selector :: struct {
	name: string,
	ctx:  rawptr,
	pick: proc(ctx: rawptr, ordered: []Candidate, req: Requirements) -> (index: int, ok: bool),
}
pick_first :: proc(ctx: rawptr, ordered: []Candidate, req: Requirements) -> (int, bool) {return 0, len(ordered) > 0}
FIRST_SATISFIABLE :: Selector {
	name = "first",
	pick = pick_first,
}
// Startup only. Names and callback contexts must outlive the service.
selector_register :: proc(s: ^Service, sel: Selector) {
	if s.selectors.allocator.procedure == nil do s.selectors = make([dynamic]Selector, runtime.heap_allocator())
	for &existing in s.selectors do if existing.name == sel.name {existing = sel; return}
	append(&s.selectors, sel)
}
selector_find :: proc(s: ^Service, name: string) -> (Selector, bool) {
	for sel in s.selectors do if sel.name == name do return sel, true
	if name == "first" do return FIRST_SATISFIABLE, true
	return {}, false
}
select :: proc(
	s: ^Service,
	req: Requirements,
	rules: []Rule,
	selector: string = "first",
	allocator := context.temp_allocator,
) -> (
	c: Candidate,
	ok: bool,
	reason: string,
) {
	sel, found := selector_find(s, selector)
	if !found do return {}, false, "unknown_selector"
	all := candidates(s, req, context.allocator)
	defer candidates_destroy(all, context.allocator)
	ordered := match(rules, all, context.allocator)
	defer delete(ordered)
	if len(ordered) == 0 do return {}, false, "no_candidate"
	if req.prefer_bridge != "" {
		for c in ordered do if c.bridge_id == req.prefer_bridge do return candidate_clone(c, allocator), true, ""
	}
	index, selected := sel.pick(sel.ctx, ordered, req)
	if !selected || index < 0 || index >= len(ordered) do return {}, false, "no_candidate"
	return candidate_clone(ordered[index], allocator), true, ""
}
