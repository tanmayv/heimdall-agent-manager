package main

import "core:fmt"
import "core:strings"

safe_path_part :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

extract_json_string :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := strings.index_byte(body[start:], '"')
	if end < 0 do return fallback
	return body[start:start + end]
}

extract_json_string_unescaped :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := start
	escaped := false
	for end < len(body) {
		ch := body[end]
		if escaped {
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			return json_unescape_string(body[start:end])
		}
		end += 1
	}
	return fallback
}

// json_unescape_string decodes a JSON string body (the text BETWEEN the quotes)
// back to its original bytes.
//
// The \uXXXX case is what makes binary artifacts survive. The Hub escaper
// (contracts.write_json_string) walks BYTES, not runes: it emits \" \\ \n \r \t
// and \u00xx for every byte < 0x20, and passes every byte >= 0x20 — including
// 0x80..0xFF — through verbatim. So a PNG reaches us intact except that each
// control byte arrived as a six-character escape. Without a \u case here the old
// default branch wrote the 'u' and left "001a" as literal text, turning every
// such byte into five junk bytes: 0x1A came out as "u001a" and the file was
// unopenable. Decoding restores a byte-identical file.
//
// \uXXXX is decoded with JSON semantics (codepoint -> UTF-8, surrogate pairs
// joined), which for the 0x00..0x7F the Hub actually emits is exactly one byte —
// so binary round-trips and ordinary JSON text is still read correctly.
json_unescape_string :: proc(value: string) -> string {
	b := strings.builder_make()
	i := 0
	for i < len(value) {
		ch := value[i]
		if ch == '\\' && i + 1 < len(value) {
			next := value[i + 1]
			switch next {
			case 'n': strings.write_byte(&b, '\n')
			case 'r': strings.write_byte(&b, '\r')
			case 't': strings.write_byte(&b, '\t')
			case 'b': strings.write_byte(&b, '\b')
			case 'f': strings.write_byte(&b, '\f')
			case '/': strings.write_byte(&b, '/')
			case '"': strings.write_byte(&b, '"')
			case '\\': strings.write_byte(&b, '\\')
			case 'u':
				if cp, width, ok := json_unescape_codepoint(value, i); ok {
					if cp < 0x80 {
						// One byte in, one byte out: this is the branch binary
						// content takes (the Hub only ever escapes bytes < 0x20).
						strings.write_byte(&b, u8(cp))
					} else {
						strings.write_rune(&b, rune(cp))
					}
					i += width
					continue
				}
				// Malformed escape: keep the source text rather than inventing bytes.
				strings.write_byte(&b, next)
			case: strings.write_byte(&b, next)
			}
			i += 2
			continue
		}
		strings.write_byte(&b, ch)
		i += 1
	}
	return strings.to_string(b)
}

// json_unescape_codepoint reads the \uXXXX escape starting at `start` (which must
// point at the backslash) and returns the codepoint plus how many source bytes it
// consumed — 12 when a high surrogate is followed by its low surrogate, else 6.
// Returns ok=false if the escape is truncated or not four hex digits.
json_unescape_codepoint :: proc(value: string, start: int) -> (cp: int, width: int, ok: bool) {
	first, first_ok := json_hex4(value, start + 2)
	if !first_ok do return 0, 0, false
	if first >= 0xD800 && first <= 0xDBFF {
		// High surrogate: only a following low surrogate forms a real codepoint.
		if start + 12 <= len(value) && value[start + 6] == '\\' && value[start + 7] == 'u' {
			if low, low_ok := json_hex4(value, start + 8); low_ok && low >= 0xDC00 && low <= 0xDFFF {
				return 0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00), 12, true
			}
		}
		return 0, 0, false
	}
	if first >= 0xDC00 && first <= 0xDFFF do return 0, 0, false
	return first, 6, true
}

json_hex4 :: proc(value: string, at: int) -> (int, bool) {
	if at + 4 > len(value) do return 0, false
	out := 0
	for i in at..<at + 4 {
		digit: int
		switch ch := value[i]; ch {
		case '0'..='9': digit = int(ch - '0')
		case 'a'..='f': digit = int(ch - 'a') + 10
		case 'A'..='F': digit = int(ch - 'A') + 10
		case: return 0, false
		}
		out = out * 16 + digit
	}
	return out, true
}

json_kv :: proc(key, value: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `"`)
	json_write_string(&b, key)
	strings.write_string(&b, `":"`)
	json_write_string(&b, value)
	strings.write_string(&b, `"`)
	return strings.to_string(b)
}

json_kv_raw :: proc(key, value_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `"`)
	json_write_string(&b, key)
	strings.write_string(&b, `":`)
	strings.write_string(&b, value_json)
	return strings.to_string(b)
}

// json_object wraps pre-serialized kv fields into a JSON object using string
// concatenation. (fmt.tprintf mishandles '{'/'}' + '%s' when field values
// contain commas, so avoid it here.)
json_object :: proc(fields: ..string) -> string {
	return strings.concatenate({"{", strings.join(fields, ","), "}"})
}

json_object_from_slice :: proc(fields: []string) -> string {
	return strings.concatenate({"{", strings.join(fields, ","), "}"})
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 32 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", u32(ch)))
			} else {
				strings.write_rune(builder, ch)
			}
		}
	}
}
