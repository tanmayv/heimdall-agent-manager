package engine

// Operation journal (spec §6.1): supervisor/journal/ops.jsonl, one JSON object per line,
// appended with a single write + fsync before the action it announces (terminal lines
// after). Line format (T13 fixes the byte layout the crc32 covers):
//
//   {"js":1,"seq":N,"ts":N,"op_id":"…","action":"…","actor":"…","state":"…","sub":"…"|null,
//    "from":{"version":"…","sha256":"…","tree":"…"}|null,"to":{…}|null,"force_at":N|null,
//    "probation_attempt":N,"hub":true|false,"error":"…"|null,"note":"…"|null,
//    "forced":true|false,"busy":{"pty_sessions":N,"launches":N,"helpers":N}|null,
//    "interrupted_by":"…"|null,"cancelled_by":"…"|null,"crc32":"xxxxxxxx"}
//
// crc32 = IEEE CRC-32 (8 lowercase hex) of the line's bytes before `,"crc32":"`. Members
// are always written in this order; readers ignore unknown members (a newer journal
// schema adds members, §8 "read N and N-1").

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

JOURNAL_SCHEMA :: 1
JOURNAL_DIR :: "journal"
JOURNAL_FILE :: "ops.jsonl"
JOURNAL_ROTATED :: "ops.1.jsonl"
JOURNAL_NEW :: "ops.jsonl.new"
OP_INDEX_FILE :: "op-index.json"
ROTATE_BYTES :: 1 << 20
INDEX_HORIZON_S :: 31 * 24 * 3600
ROTATE_KEEP_MIN :: 50
MAX_JOURNAL_BYTES :: 64 << 20 // refuse to read anything larger into memory (corrupt)

Ref :: struct {
	version: string,
	sha256:  string,
	tree:    string,
}

ref_empty :: proc(r: Ref) -> bool {
	return r.tree == "" && r.version == "" && r.sha256 == ""
}

// Busy: what the agent gate counted (spec §12), as reported by the runtime. `counted` =
// false is journaled as null (no count was taken, or the runtime did not answer).
Busy :: struct {
	counted:      bool,
	pty_sessions: int, // live PTY sessions (agents)
	launches:     int, // in-flight launches not yet a session
	helpers:      int, // helper processes in this instance's job / process groups
}

busy_total :: proc(b: Busy) -> int {
	return b.pty_sessions + b.launches + b.helpers
}

Line :: struct {
	js:                int,
	seq:               i64,
	ts:                i64,
	op_id:             string,
	action:            string,
	actor:             string,
	state:             string,
	sub:               string, // "" = null
	from:              Ref, // empty = null
	to:                Ref,
	force_at:          i64, // 0 = null
	probation_attempt: int,
	hub:               bool, // hub connection required in probation (§14)
	error:             string, // "" = null
	note:              string, // "" = null (pin_skipped, probation_offline, from_mismatch, …)
	// Agent gate (§12, T14).
	forced:            bool, // gate_closed after the 2 h wait ran out with agents still busy
	busy:              Busy, // count at gate_closed / waiting_for_idle
	interrupted_by:    string, // J30: op_id of the update_now that ended the wait
	cancelled_by:      string, // J35: op_id of the cancel intent
}

TERMINAL_STATES :: []string{"committed", "noop", "applied", "failed", "cancelled", "expired", "rejected", "rolled_back", "rollback_failed"}

is_terminal :: proc(state: string) -> bool {
	return slice.contains(TERMINAL_STATES, state)
}

@(private)
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 || c == 0x7f {
				fmt.sbprintf(b, "\\u%04x", c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

@(private)
write_opt_string :: proc(b: ^strings.Builder, s: string) {
	if s == "" do strings.write_string(b, "null")
	else do write_json_string(b, s)
}

@(private)
write_ref :: proc(b: ^strings.Builder, r: Ref) {
	if ref_empty(r) {
		strings.write_string(b, "null")
		return
	}
	strings.write_string(b, `{"version":`)
	write_json_string(b, r.version)
	strings.write_string(b, `,"sha256":`)
	write_json_string(b, r.sha256)
	strings.write_string(b, `,"tree":`)
	write_json_string(b, r.tree)
	strings.write_byte(b, '}')
}

CRC_MARK :: `,"crc32":"`

// encode_line renders a full journal line including crc32 and the trailing LF.
encode_line :: proc(l: Line, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, `{{"js":%d,"seq":%d,"ts":%d,"op_id":`, l.js, l.seq, l.ts)
	write_json_string(&b, l.op_id)
	strings.write_string(&b, `,"action":`)
	write_json_string(&b, l.action)
	strings.write_string(&b, `,"actor":`)
	write_json_string(&b, l.actor)
	strings.write_string(&b, `,"state":`)
	write_json_string(&b, l.state)
	strings.write_string(&b, `,"sub":`)
	write_opt_string(&b, l.sub)
	strings.write_string(&b, `,"from":`)
	write_ref(&b, l.from)
	strings.write_string(&b, `,"to":`)
	write_ref(&b, l.to)
	strings.write_string(&b, `,"force_at":`)
	if l.force_at == 0 do strings.write_string(&b, "null")
	else do fmt.sbprintf(&b, "%d", l.force_at)
	fmt.sbprintf(&b, `,"probation_attempt":%d,"hub":%v,"error":`, l.probation_attempt, l.hub)
	write_opt_string(&b, l.error)
	strings.write_string(&b, `,"note":`)
	write_opt_string(&b, l.note)
	fmt.sbprintf(&b, `,"forced":%v,"busy":`, l.forced)
	if l.busy.counted {
		fmt.sbprintf(&b, `{{"pty_sessions":%d,"launches":%d,"helpers":%d}}`, l.busy.pty_sessions, l.busy.launches, l.busy.helpers)
	} else {
		strings.write_string(&b, "null")
	}
	strings.write_string(&b, `,"interrupted_by":`)
	write_opt_string(&b, l.interrupted_by)
	strings.write_string(&b, `,"cancelled_by":`)
	write_opt_string(&b, l.cancelled_by)
	prefix := strings.to_string(b)
	crc := hash.crc32(transmute([]byte)prefix)
	fmt.sbprintf(&b, `%s%08x"}}`, CRC_MARK, crc)
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

@(private)
obj_string :: proc(o: json.Object, key: string) -> (string, bool) {
	v, present := o[key]
	if !present do return "", false
	#partial switch s in v {
	case json.String:
		return string(s), true
	case json.Null:
		return "", true
	}
	return "", false
}

@(private)
obj_int :: proc(o: json.Object, key: string) -> (i64, bool) {
	v, present := o[key]
	if !present do return 0, false
	#partial switch n in v {
	case json.Integer:
		return n, true
	case json.Float:
		if n == f64(i64(n)) do return i64(n), true
	case json.Null:
		return 0, true
	}
	return 0, false
}

@(private)
obj_ref :: proc(o: json.Object, key: string, allocator := context.allocator) -> (r: Ref, ok: bool) {
	v, present := o[key]
	if !present do return r, false
	#partial switch x in v {
	case json.Null:
		return r, true
	case json.Object:
		version, ok1 := obj_string(x, "version")
		sha, ok2 := obj_string(x, "sha256")
		tree, ok3 := obj_string(x, "tree")
		if !ok1 || !ok2 || !ok3 do return r, false
		return Ref{strings.clone(version, allocator), strings.clone(sha, allocator), strings.clone(tree, allocator)}, true
	}
	return r, false
}

// decode_line validates one line (without its LF): crc32 first, then the JSON. Strings
// are cloned into `allocator`.
decode_line :: proc(text: string, allocator := context.allocator) -> (l: Line, ok: bool) {
	// …,"crc32":"xxxxxxxx"}  = 10 + 8 + 2 bytes at the end.
	if len(text) < 22 || !strings.has_suffix(text, `"}`) do return
	mark := len(text) - 20
	if text[mark:mark + 10] != CRC_MARK do return
	hex := text[mark + 10:mark + 18]
	for c in transmute([]byte)hex {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) do return
	}
	want, parsed := strconv.parse_u64(hex, 16)
	if !parsed || u64(hash.crc32(transmute([]byte)text[:mark])) != want do return
	value, err := json.parse(transmute([]byte)text, json.Specification.JSON, true, context.temp_allocator)
	if err != nil do return
	obj, is_obj := value.(json.Object)
	if !is_obj do return
	js, has_js := obj_int(obj, "js")
	if !has_js || js < JOURNAL_SCHEMA || js > JOURNAL_SCHEMA + 1 do return
	l.js = int(js)
	has: [8]bool
	l.seq, has[0] = obj_int(obj, "seq")
	l.ts, has[1] = obj_int(obj, "ts")
	op_id, action, actor, state, sub: string
	op_id, has[2] = obj_string(obj, "op_id")
	action, has[3] = obj_string(obj, "action")
	actor, has[4] = obj_string(obj, "actor")
	state, has[5] = obj_string(obj, "state")
	sub, _ = obj_string(obj, "sub")
	attempt, _ := obj_int(obj, "probation_attempt")
	force_at, _ := obj_int(obj, "force_at")
	errs, _ := obj_string(obj, "error")
	note, _ := obj_string(obj, "note")
	from, from_ok := obj_ref(obj, "from", allocator)
	to, to_ok := obj_ref(obj, "to", allocator)
	has[6] = from_ok || !("from" in obj)
	has[7] = to_ok || !("to" in obj)
	for h in has do if !h do return
	if op_id == "" || state == "" do return
	if hv, present := obj["hub"]; present {
		if bv, is_bool := hv.(json.Boolean); is_bool do l.hub = bool(bv)
	}
	if fv, present := obj["forced"]; present {
		if bv, is_bool := fv.(json.Boolean); is_bool do l.forced = bool(bv)
	}
	if bo, is_obj2 := obj["busy"].(json.Object); is_obj2 {
		ps, ok1 := obj_int(bo, "pty_sessions")
		ln, ok2 := obj_int(bo, "launches")
		hp, ok3 := obj_int(bo, "helpers")
		if !ok1 || !ok2 || !ok3 do return
		l.busy = Busy{true, int(ps), int(ln), int(hp)}
	}
	interrupted_by, _ := obj_string(obj, "interrupted_by")
	cancelled_by, _ := obj_string(obj, "cancelled_by")
	l.interrupted_by = strings.clone(interrupted_by, allocator)
	l.cancelled_by = strings.clone(cancelled_by, allocator)
	l.op_id = strings.clone(op_id, allocator)
	l.action = strings.clone(action, allocator)
	l.actor = strings.clone(actor, allocator)
	l.state = strings.clone(state, allocator)
	l.sub = strings.clone(sub, allocator)
	l.error = strings.clone(errs, allocator)
	l.note = strings.clone(note, allocator)
	l.from = from
	l.to = to
	l.force_at = force_at
	l.probation_attempt = int(attempt)
	return l, true
}

Journal_Read_Status :: enum {
	Ok,
	Missing,
	Torn_Tail, // last line torn: valid prefix up to `valid_bytes`
	Corrupt, // an invalid line followed by more data (§16)
}

Journal_Read :: struct {
	lines:       [dynamic]Line,
	status:      Journal_Read_Status,
	valid_bytes: i64,
	total_bytes: i64,
}

// read_journal_file parses a journal file. A torn tail (the last line invalid or missing
// its LF) is reported with the size of the valid prefix; an invalid line followed by
// more lines is Corrupt.
read_journal_file :: proc(path: string, allocator := context.allocator) -> (r: Journal_Read) {
	r.lines = make([dynamic]Line, allocator)
	if !os.exists(path) {
		r.status = .Missing
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) > MAX_JOURNAL_BYTES {
		r.status = .Corrupt
		return
	}
	r.total_bytes = i64(len(data))
	text := string(data)
	pos := 0
	for pos < len(text) {
		nl := strings.index_byte(text[pos:], '\n')
		if nl < 0 {
			r.status = .Torn_Tail
			r.valid_bytes = i64(pos)
			return
		}
		line_text := text[pos:pos + nl]
		l, ok := decode_line(line_text, allocator)
		if !ok {
			rest := strings.trim_space(text[pos + nl + 1:])
			r.status = .Torn_Tail if len(rest) == 0 else .Corrupt
			r.valid_bytes = i64(pos)
			return
		}
		append(&r.lines, l)
		pos += nl + 1
	}
	r.valid_bytes = i64(pos)
	r.status = .Ok
	return
}

// Op view: the last line of every op, in journal order.
Op_View :: struct {
	first: Line,
	last:  Line,
	lines: int,
}

// active_op: the most recent op whose last line is not terminal (spec §6.1).
active_op :: proc(lines: []Line) -> (op: Op_View, ok: bool) {
	best_seq: i64 = -1
	for i := len(lines) - 1; i >= 0; i -= 1 {
		id := lines[i].op_id
		// Is this the last line of its op?
		later := false
		for j := i + 1; j < len(lines); j += 1 {
			if lines[j].op_id == id {
				later = true
				break
			}
		}
		if later do continue
		if is_terminal(lines[i].state) do continue
		if lines[i].seq > best_seq {
			best_seq = lines[i].seq
			op.last = lines[i]
			ok = true
		}
	}
	if !ok do return
	for l in lines {
		if l.op_id == op.last.op_id {
			if op.lines == 0 do op.first = l
			op.lines += 1
		}
	}
	return
}

// op_lines returns every line of one op.
op_lines :: proc(lines: []Line, op_id: string, allocator := context.temp_allocator) -> []Line {
	out := make([dynamic]Line, allocator)
	for l in lines do if l.op_id == op_id do append(&out, l)
	return out[:]
}

// ---- op index (dedupe authority, §6.1) ----

Index_Entry :: struct {
	state: string,
	at:    i64,
}

encode_op_index :: proc(idx: map[string]Index_Entry, allocator := context.temp_allocator) -> string {
	keys := make([dynamic]string, context.temp_allocator)
	for k in idx do append(&keys, k)
	slice.sort(keys[:])
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"schema":1,"ops":{`)
	for k, i in keys {
		if i > 0 do strings.write_byte(&b, ',')
		write_json_string(&b, k)
		strings.write_string(&b, `:{"state":`)
		write_json_string(&b, idx[k].state)
		fmt.sbprintf(&b, `,"at":%d}}`, idx[k].at)
	}
	strings.write_string(&b, "}}\n")
	return strings.to_string(b)
}

read_op_index :: proc(path: string, allocator := context.allocator) -> (idx: map[string]Index_Entry, ok: bool) {
	idx = make(map[string]Index_Entry, allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return idx, false
	value, perr := json.parse(data, json.Specification.JSON, true, context.temp_allocator)
	if perr != nil do return idx, false
	obj, is_obj := value.(json.Object)
	if !is_obj do return idx, false
	ops, has_ops := obj["ops"].(json.Object)
	if !has_ops do return idx, false
	for k, v in ops {
		e, is_e := v.(json.Object)
		if !is_e do continue
		state, _ := obj_string(e, "state")
		at, _ := obj_int(e, "at")
		idx[strings.clone(k, allocator)] = Index_Entry{strings.clone(state, allocator), at}
	}
	return idx, true
}
