package contracts

import "core:encoding/json"
import "core:strconv"
import jsonx "odin_test:lib/jsonx"

// Request-only validation tree. Unlike the binary-compatible response reader,
// require strict JSON grammar, full input, decoded-key uniqueness and a bounded
// depth. Every member (including "") is retained for unknown-field validation.
// Integer slots accept only canonical nonnegative decimal i64 lexemes. Every
// other valid JSON number remains a Float TYPE marker (value deliberately unused),
// so it cannot wrap/round into a protocol version or page limit. This tree is
// never reserialized or forwarded; requests retain their original wire bytes.
OWNER_JSON_MAX_DEPTH :: 32

@(private = "file")
Owner_JSON_Reader :: struct {
    raw: string,
    content_strings: bool,
    previous_end: int,
    tokenizer: json.Tokenizer,
    token: json.Token,
}

owner_request_document :: proc(raw: string) -> (json.Value, bool) {
    return owner_json_document(raw, false)
}

// Content lives inside authenticated encrypted payloads. Unlike authority
// envelopes it may contain Unicode, while retaining strict grammar,
// decoded-key uniqueness, depth and exact integer rules.
owner_content_document :: proc(raw: string) -> (json.Value, bool) {
    return owner_json_document(raw, true)
}

@(private = "file")
owner_json_document :: proc(raw: string, content_strings: bool) -> (json.Value, bool) {
    r := Owner_JSON_Reader{raw = raw, content_strings = content_strings, tokenizer = json.make_tokenizer(raw, .JSON, true)}
    if !owner_json_advance(&r) do return nil, false
    value, ok := owner_json_value(&r, 0)
    return value, ok && r.token.kind == .EOF
}

@(private = "file")
owner_json_advance :: proc(r: ^Owner_JSON_Reader) -> bool {
    token, err := json.get_token(&r.tokenizer)
    if err != .None && err != .EOF do return false
    // Core also skips BOM/VT/FF in JSON mode. Request JSON permits ONLY these
    // four ASCII whitespace bytes between tokens; inspect the original gaps.
    if token.offset < r.previous_end || token.offset > len(r.raw) do return false
    for b in r.raw[r.previous_end:token.offset] {
        if b != ' ' && b != '\t' && b != '\r' && b != '\n' do return false
    }
    r.previous_end = token.offset + len(token.text)
    r.token = token
    return true
}

@(private = "file")
owner_json_string :: proc(token: json.Token, content_strings: bool) -> (string, bool) {
    text := token.text
    if content_strings {
        if !owner_content_string_valid(text) do return "", false
        value: string
        err := json.unmarshal_string(text, &value, allocator=context.temp_allocator)
        return value, err == nil
    }
    // The core JSON tokenizer also accepts backslash-apostrophe; RFC JSON does
    // not. Check escapes independently before the safe byte-preserving decoder.
    for i := 1; i < len(text) - 1; i += 1 {
        if text[i] < 0x20 || text[i] > 0x7e do return "", false
        if text[i] != '\\' do continue
        i += 1
        if i >= len(text) - 1 do return "", false
        switch text[i] {
        case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
        case 'u':
            if i + 4 >= len(text) do return "", false
            for j in 1..=4 {
                b := text[i + j]
                if !(b >= '0' && b <= '9' || b >= 'a' && b <= 'f' || b >= 'A' && b <= 'F') do return "", false
            }
            // Owner envelopes contain ASCII identifiers/counters/ciphertext only.
            // Reject non-ASCII Unicode escapes BEFORE the legacy unescape helper,
            // which otherwise does not reject isolated surrogate halves.
            if text[i+1] != '0' || text[i+2] != '0' do return "", false
            hi, lo := text[i+3], text[i+4]
            if hi > '7' || (hi == '7' && (lo == 'f' || lo == 'F')) do return "", false
            i += 4
        case: return "", false
        }
    }
    return jsonx.json_unescape_string(text[1:len(text)-1], context.temp_allocator), true
}

@(private = "file")
owner_json_value :: proc(r: ^Owner_JSON_Reader, depth: int) -> (json.Value, bool) {
    if depth > OWNER_JSON_MAX_DEPTH do return nil, false
    token := r.token
    #partial switch token.kind {
    case .String:
        s, ok := owner_json_string(token, r.content_strings)
        if !ok || !owner_json_advance(r) do return nil, false
        return json.String(s), true
    case .Integer:
        if !owner_json_advance(r) do return nil, false
        if owner_decimal_valid(token.text) {
            n, ok := strconv.parse_i64(token.text)
            if !ok do return nil, false
            return json.Integer(n), true
        }
        return json.Float(0), true // noncanonical/out-of-range INTEGER SLOT, not a converted value
    case .Float:
        if !owner_json_advance(r) do return nil, false
        return json.Float(0), true // float/exponent spelling must never become an integer slot
    case .True:
        if !owner_json_advance(r) do return nil, false
        return json.Boolean(true), true
    case .False:
        if !owner_json_advance(r) do return nil, false
        return json.Boolean(false), true
    case .Null:
        if !owner_json_advance(r) do return nil, false
        return json.Null{}, true
    case .Open_Brace:
        if !owner_json_advance(r) do return nil, false
        o := make(json.Object, context.temp_allocator)
        if r.token.kind == .Close_Brace {
            if !owner_json_advance(r) do return nil, false
            return o, true
        }
        for {
            if r.token.kind != .String do return nil, false
            key, ok := owner_json_string(r.token, r.content_strings)
            if !ok || !owner_json_advance(r) || r.token.kind != .Colon do return nil, false
            if key in o do return nil, false
            if !owner_json_advance(r) do return nil, false
            value, valid := owner_json_value(r, depth + 1)
            if !valid do return nil, false
            o[key] = value
            if r.token.kind == .Close_Brace {
                if !owner_json_advance(r) do return nil, false
                return o, true
            }
            if r.token.kind != .Comma || !owner_json_advance(r) do return nil, false
        }
    case .Open_Bracket:
        if !owner_json_advance(r) do return nil, false
        a := make(json.Array, 0, 0, context.temp_allocator)
        if r.token.kind == .Close_Bracket {
            if !owner_json_advance(r) do return nil, false
            return a, true
        }
        for {
            value, valid := owner_json_value(r, depth + 1)
            if !valid do return nil, false
            append(&a, value)
            if r.token.kind == .Close_Bracket {
                if !owner_json_advance(r) do return nil, false
                return a, true
            }
            if r.token.kind != .Comma || !owner_json_advance(r) do return nil, false
        }
    }
    return nil, false
}

owner_decimal_valid :: proc(s: string) -> bool {
    if len(s) == 0 || len(s) > 19 do return false
    if s == "0" do return true
    if s[0] < '1' || s[0] > '9' do return false
    for b in s do if b < '0' || b > '9' do return false
    return len(s) < 19 || s <= "9223372036854775807"
}

// Reject permissive tokenizer escapes and isolated UTF-16 surrogate halves
// before the content decoder can replace or normalize them.
@(private = "file")
owner_content_string_valid :: proc(text: string) -> bool {
    for i:=1; i<len(text)-1; i+=1 {
        if text[i]<0x20 do return false
        if text[i]!='\\' do continue
        i+=1
        if i>=len(text)-1 do return false
        switch text[i] {
        case '"','\\','/','b','f','n','r','t':
        case 'u':
            if i+4>=len(text)-1 do return false
            unit,ok:=strconv.parse_u64(text[i+1:i+5],16)
            if !ok do return false
            i+=4
            if unit>=0xdc00 && unit<=0xdfff do return false
            if unit>=0xd800 && unit<=0xdbff {
                if i+6>=len(text)-1 || text[i+1:i+3]!="\\u" do return false
                low,valid:=strconv.parse_u64(text[i+3:i+7],16)
                if !valid || low<0xdc00 || low>0xdfff do return false
                i+=6
            }
        case: return false
        }
    }
    return true
}
