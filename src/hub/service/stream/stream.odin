package stream

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

MAX_VIEWERS_PER_STREAM :: 8

Registry :: struct {
	mu: sync.Mutex,
	routes: map[string]^Route,
	next_serial: u64,
}

Route :: struct {
	info: contracts.Stream_Registration,
	generation: int,
	serial: u64,
	viewers: int,
	partial: [dynamic]byte,
	seq: u64,
	next_piece, count: u16,
	latest: [dynamic]byte,
	latest_seq, version: u64,
	window_ms: u64,
	window_bytes, window_frames: int,
	ready: bool,
}

clone_info :: proc(info: contracts.Stream_Registration, allocator := context.allocator) -> contracts.Stream_Registration {
	return {
		strings.clone(info.stream_id, allocator), strings.clone(info.owner, allocator),
		strings.clone(info.bridge, allocator), strings.clone(info.instance, allocator),
		strings.clone(info.task, allocator),
		{strings.clone(info.source.kind, allocator), strings.clone(info.source.ref, allocator)},
		strings.clone(info.title, allocator), info.expires,
	}
}

// Callers hold the registry mutex. No caller retains a Route across unlock.
remove :: proc(reg: ^Registry, route: ^Route) {
	if route.ready do fmt.eprintln("hub stream: ended")
	r := route.info
	delete_key(&reg.routes, r.stream_id)
	fields := []string{r.stream_id, r.owner, r.bridge, r.instance, r.task,
		r.source.kind, r.source.ref, r.title}
	for s in fields do delete(s)
	delete(route.partial)
	delete(route.latest)
	free(route)
}

// Select before removing so map iteration never relies on deletion order.
prune :: proc(reg: ^Registry, now: u64, bridge := "", generation := 0, replaced := false) {
	stale: [dynamic]^Route
	defer delete(stale)
	for _, r in reg.routes {
		if now >= r.info.expires ||
		   (r.info.bridge == bridge && (r.generation != generation if replaced else r.generation == generation)) {
			append(&stale, r)
		}
	}
	for r in stale do remove(reg, r)
}

destroy :: proc(reg: ^Registry) {
	prune(reg, max(u64))
	delete(reg.routes)
	reg.routes = nil
}

register :: proc(reg: ^Registry, info: contracts.Stream_Registration, generation: int, now: u64) -> string {
	prune(reg, now, info.bridge, generation, replaced = true)
	if reg.routes[info.stream_id] != nil do return "duplicate"
	count := 0
	for _, r in reg.routes {
		if r.info.bridge == info.bridge do count += 1
	}
	if count >= contracts.STREAM_MAX_PER_BRIDGE do return "limit"
	if reg.routes == nil do reg.routes = make(map[string]^Route)
	r := new(Route)
	r.info = clone_info(info)
	r.generation = generation
	reg.next_serial += 1
	r.serial = reg.next_serial
	reg.routes[r.info.stream_id] = r
	return ""
}

lookup :: proc(reg: ^Registry, owner, id: string, now: u64) -> ^Route {
	r := reg.routes[id]
	if r == nil || r.info.owner != owner || !r.ready || now >= r.info.expires do return nil
	return r
}

// A viewer takes a snapshot only when it is ready to write again. A skipped
// version is a dropped whole frame, with no per-viewer pending frame queue.
snapshot :: proc(r: ^Route, last_version: u64) -> (frame: []byte, seq, version: u64) {
	if r.version == last_version do return nil, 0, last_version
	return slice.clone(r.latest[:]), r.latest_seq, r.version
}

accept_piece :: proc(r: ^Route, p: contracts.Stream_Piece, now: u64) {
	if !r.ready || r.viewers == 0 || now >= r.info.expires || p.mime != contracts.STREAM_MIME_JPEG do return
	if now - r.window_ms >= 1000 {
		r.window_ms = now
		r.window_bytes, r.window_frames = 0, 0
	}
	if p.piece_index == 0 {
		clear(&r.partial)
		r.seq, r.next_piece, r.count = p.frame_seq, 0, p.piece_count
	}
	if r.count == 0 || p.frame_seq != r.seq || p.piece_index != r.next_piece || p.piece_count != r.count ||
	   len(r.partial) + len(p.data) > contracts.STREAM_MAX_BYTES_PER_SECOND ||
	   r.window_bytes + len(p.data) > contracts.STREAM_MAX_BYTES_PER_SECOND {
		r.count = 0
		clear(&r.partial)
		return
	}
	r.window_bytes += len(p.data)
	append(&r.partial, ..p.data)
	r.next_piece += 1
	if r.next_piece != r.count do return
	r.count = 0
	if r.window_frames >= contracts.STREAM_MAX_FPS do return
	r.window_frames += 1
	r.partial, r.latest = r.latest, r.partial
	r.latest_seq = r.seq
	if r.version == 0 do fmt.eprintln("hub stream: first frame assembled")
	r.version += 1
}
