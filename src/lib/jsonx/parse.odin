package jsonx

import "core:encoding/json"
import "core:mem"
import "core:strconv"

// ---------------------------------------------------------------------------
// A byte-preserving JSON reader (F1 / REQ-JSONX-2).
//
// WHY THIS EXISTS -- `core:encoding/json`'s `parse_string` cannot be used on a
// ham-ctl response, because it can abort the process:
//
//   `unquote_string` sizes its output buffer at `len(s) + 2*utf8.UTF_MAX`
//   (len+8 of slack) and its pre-scan loop bails out the moment it meets
//   invalid UTF-8, which forces the slow decode path. That path re-encodes
//   every invalid byte as U+FFFD: `utf8.decode_rune_in_string` returns
//   (RUNE_ERROR, width=1), consuming ONE input byte, while
//   `utf8.encode_rune(RUNE_ERROR)` emits THREE. The guarding
//   `assert(buf_width <= width)` is deliberately skipped for RUNE_ERROR, so
//   each invalid byte nets +2 output bytes against 8 bytes of slack: FIVE
//   invalid bytes overflow the buffer and the process dies inside core.
//
// Every ham-ctl response is parsed here, and artifact content is arbitrary
// binary, so this was reachable from any response that carried five bad bytes.
// The Odin core library is not vendored in this repo (it comes from the
// read-only nix store), so the fix has to live on our side of the boundary.
//
// WHAT WE DO INSTEAD -- core's TOKENIZER is safe on the same input: it never
// writes into a sized buffer, and invalid UTF-8 inside a string literal only
// makes it report `.Invalid_String` alongside a token whose span is still
// correct. So we keep core's tokenizer for structure and decode string
// literals ourselves with `json_unescape_string`, which is byte-preserving.
// That buys two things at once:
//
//   1. No response can panic the CLI, whatever bytes it carries.
//   2. Binary content round-trips VERBATIM instead of having each invalid byte
//      replaced by U+FFFD -- which is what lets `artifact download` write a
//      byte-complete file (REQ-JSONX-4).
//
// Structural grammar, allocation ownership (every key and string is owned by
// `allocator`, so `json.destroy_value` still frees the tree) and laxness are
// mirrored from core's `parse_value`/`parse_object_body` under
// `json.DEFAULT_SPECIFICATION`, so this is a drop-in for the `parse_string`
// calls it replaces. The one intentional divergence is `.Invalid_String`:
// core rejects the document, we accept the token and keep the bytes.

@(private = "file")
Reader :: struct {
	tok:       json.Tokenizer,
	curr:      json.Token,
	allocator: mem.Allocator,
}

// parse_body parses a JSON document into a json.Value tree without routing any
// string literal through core's `unquote_string`. The returned value is owned
// by `allocator` and must be released with `json.destroy_value`.
parse_body :: proc(body: string, allocator := context.allocator) -> (value: json.Value, ok: bool) {
	r := Reader {
		tok       = json.make_tokenizer(body, json.DEFAULT_SPECIFICATION, true),
		allocator = allocator,
	}
	if !advance(&r) do return nil, false
	return read_value(&r)
}

// advance pulls the next token, deciding which tokenizer errors are fatal.
@(private = "file")
advance :: proc(r: ^Reader) -> bool {
	tok, err := json.get_token(&r.tok)
	#partial switch err {
	case .None:
		// Good token.
	case .EOF:
		// Reported alongside the EOF token itself; not a failure on its own.
	case .Invalid_String:
		// DELIBERATE: core flags any string literal carrying invalid UTF-8
		// (or an unknown escape) as `.Invalid_String` and gives up on the
		// document. ham-ctl has to be able to read such a response anyway --
		// artifact content is arbitrary binary -- and the token's span is
		// still correct, so we take the token and let `json_unescape_string`
		// preserve the bytes.
		if tok.kind != .String do return false
	case:
		// Every other tokenizer error is structural: reject the document.
		return false
	}
	r.curr = tok
	return true
}

@(private = "file")
read_value :: proc(r: ^Reader) -> (value: json.Value, ok: bool) {
	tok := r.curr
	#partial switch tok.kind {
	case .Null:
		if !advance(r) do return nil, false
		return json.Null{}, true
	case .False:
		if !advance(r) do return nil, false
		return json.Boolean(false), true
	case .True:
		if !advance(r) do return nil, false
		return json.Boolean(true), true
	case .Integer:
		if !advance(r) do return nil, false
		i, _ := strconv.parse_i64(tok.text)
		return json.Integer(i), true
	case .Float:
		if !advance(r) do return nil, false
		f, _ := strconv.parse_f64(tok.text)
		return json.Float(f), true
	case .Infinity:
		if !advance(r) do return nil, false
		bits: u64 = len(tok.text) > 0 && tok.text[0] == '-' ? 0xfff0000000000000 : 0x7ff0000000000000
		return json.Float(transmute(f64)bits), true
	case .NaN:
		if !advance(r) do return nil, false
		bits: u64 = len(tok.text) > 0 && tok.text[0] == '-' ? 0xfff7ffffffffffff : 0x7ff7ffffffffffff
		return json.Float(transmute(f64)bits), true
	case .String:
		if !advance(r) do return nil, false
		return json.String(decode_string_token(tok.text, r.allocator)), true
	case .Open_Brace:
		return read_object(r)
	case .Open_Bracket:
		return read_array(r)
	}
	return nil, false
}

// decode_string_token turns a string TOKEN (quotes included, exactly as the
// tokenizer spans it) into owned bytes. Unlike core's `unquote_string` this
// cannot over-run its output, because `json_unescape_string` appends to a
// growable builder and copies every byte it does not recognise as an escape
// through unchanged.
@(private = "file")
decode_string_token :: proc(text: string, allocator: mem.Allocator) -> string {
	// `len(text) <= 2` is `""` or a degenerate span; core returns "" for both.
	if len(text) <= 2 do return ""
	return json_unescape_string(text[1:len(text) - 1], allocator)
}

@(private = "file")
read_object :: proc(r: ^Reader) -> (value: json.Value, ok: bool) {
	if !advance(r) do return nil, false // consume '{'

	obj := make(json.Object, allocator = r.allocator)
	defer if !ok {
		for key, elem in obj {
			delete(key, r.allocator)
			json.destroy_value(elem, r.allocator)
		}
		delete(obj)
	}

	for r.curr.kind != .Close_Brace {
		// Core relies on the key parse failing at end-of-input to leave this
		// loop. We check explicitly: an infinite loop on a truncated response
		// would just be a different way to hang the CLI.
		if r.curr.kind == .EOF do return nil, false

		key, key_ok := read_object_key(r)
		if !key_ok do return nil, false
		if r.curr.kind != .Colon {
			delete(key, r.allocator)
			return nil, false
		}
		if !advance(r) {
			delete(key, r.allocator)
			return nil, false
		}

		elem, elem_ok := read_value(r)
		if !elem_ok {
			delete(key, r.allocator)
			return nil, false
		}
		if key in obj {
			// Mirrors core's `.Duplicate_Object_Key`: the whole document is
			// rejected rather than one of the two values silently winning.
			delete(key, r.allocator)
			json.destroy_value(elem, r.allocator)
			return nil, false
		}
		if key == "" {
			// Core drops empty-keyed members. It also leaks them; we do not.
			delete(key, r.allocator)
			json.destroy_value(elem, r.allocator)
		} else {
			obj[key] = elem
		}

		// JSON5 commas are optional and a trailing one is allowed, so a
		// missing comma is not an error here -- exactly as in core.
		if r.curr.kind == .Comma {
			if !advance(r) do return nil, false
		}
	}

	if !advance(r) do return nil, false // consume '}'
	return obj, true
}

@(private = "file")
read_object_key :: proc(r: ^Reader) -> (key: string, ok: bool) {
	tok := r.curr
	#partial switch tok.kind {
	case .Ident:
		// JSON5 permits an unquoted identifier as a key.
		if !advance(r) do return "", false
		return clone_bytes(tok.text, r.allocator), true
	case .String:
		if !advance(r) do return "", false
		return decode_string_token(tok.text, r.allocator), true
	}
	return "", false
}

@(private = "file")
read_array :: proc(r: ^Reader) -> (value: json.Value, ok: bool) {
	if !advance(r) do return nil, false // consume '['

	arr := make(json.Array, 0, 0, r.allocator)
	defer if !ok {
		for elem in arr {
			json.destroy_value(elem, r.allocator)
		}
		delete(arr)
	}

	for r.curr.kind != .Close_Bracket {
		if r.curr.kind == .EOF do return nil, false

		elem, elem_ok := read_value(r)
		if !elem_ok do return nil, false
		append(&arr, elem)

		if r.curr.kind == .Comma {
			if !advance(r) do return nil, false
		}
	}

	if !advance(r) do return nil, false // consume ']'
	return arr, true
}

// clone_bytes copies s onto allocator so the tree owns it and
// `json.destroy_value` can free it, with no interpretation of the bytes.
@(private = "file")
clone_bytes :: proc(s: string, allocator: mem.Allocator) -> string {
	if len(s) == 0 do return ""
	b, err := mem.alloc_bytes(len(s), 1, allocator)
	if err != nil do return ""
	copy(b, s)
	return string(b)
}
