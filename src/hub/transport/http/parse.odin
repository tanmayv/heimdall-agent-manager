package http

import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

Parsed_Query :: struct {
	limit:   int,
	cursor:  string,
	search:  string,
	filters: [dynamic]contracts.API_Filter,
	sort:    [dynamic]contracts.API_Sort_Field,
	expand:  [dynamic]string,
	errors:  [dynamic]string,
}

parse_api_query :: proc(query: string, allowed_filters, allowed_sort, allowed_expand: []string) -> Parsed_Query {
	parsed := Parsed_Query{
		limit = contracts.API_DEFAULT_PAGE_LIMIT,
		filters = make([dynamic]contracts.API_Filter),
		sort = make([dynamic]contracts.API_Sort_Field),
		expand = make([dynamic]string),
		errors = make([dynamic]string),
	}
	if query == "" do return parsed
	pairs := strings.split(query, "&")
	defer delete(pairs)
	for pair in pairs {
		if pair == "" do continue
		key, value := split_query_pair(pair)
		switch key {
		case "limit":
			limit, ok := strconv.parse_int(value)
			if !ok || limit <= 0 {
				append(&parsed.errors, strings.clone("limit must be a positive integer"))
			} else if limit > contracts.API_MAX_PAGE_LIMIT {
				parsed.limit = contracts.API_MAX_PAGE_LIMIT
			} else {
				parsed.limit = int(limit)
			}
		case "cursor":
			parsed.cursor = strings.clone(value)
		case "q":
			parsed.search = strings.clone(value)
		case "sort":
			parse_sort_fields(value, allowed_sort, &parsed)
		case "expand":
			parse_expand_fields(value, allowed_expand, &parsed)
		case:
			// Preserve repeated filter parameters; callers decide per-endpoint semantics.
			if key != "" {
				if string_allowed(key, allowed_filters) {
					append(&parsed.filters, contracts.API_Filter{name = strings.clone(key), value = strings.clone(value)})
				} else {
					append(&parsed.errors, strings.clone("unknown filter"))
				}
			}
		}
	}
	return parsed
}

parsed_query_free :: proc(parsed: ^Parsed_Query) {
	delete(parsed.cursor)
	delete(parsed.search)
	for f in parsed.filters {
		delete(f.name)
		delete(f.value)
	}
	delete(parsed.filters)
	for s in parsed.sort do delete(s.field)
	delete(parsed.sort)
	for e in parsed.expand do delete(e)
	delete(parsed.expand)
	for e in parsed.errors do delete(e)
	delete(parsed.errors)
}

split_query_pair :: proc(pair: string) -> (string, string) {
	eq := strings.index_byte(pair, '=')
	if eq < 0 do return query_unescape(pair), ""
	return query_unescape(pair[:eq]), query_unescape(pair[eq + 1:])
}

parse_sort_fields :: proc(value: string, allowed_sort: []string, parsed: ^Parsed_Query) {
	if value == "" do return
	parts := strings.split(value, ",")
	defer delete(parts)
	for raw in parts {
		field := strings.trim_space(raw)
		if field == "" do continue
		direction := contracts.API_Sort_Direction.Asc
		if strings.has_prefix(field, "-") {
			direction = .Desc
			field = field[1:]
		}
		if !string_allowed(field, allowed_sort) {
			append(&parsed.errors, strings.clone("sort field is not allowed"))
			continue
		}
		append(&parsed.sort, contracts.API_Sort_Field{field = strings.clone(field), direction = direction})
	}
}

parse_expand_fields :: proc(value: string, allowed_expand: []string, parsed: ^Parsed_Query) {
	if value == "" do return
	parts := strings.split(value, ",")
	defer delete(parts)
	for raw in parts {
		field := strings.trim_space(raw)
		if field == "" do continue
		if !string_allowed(field, allowed_expand) {
			append(&parsed.errors, strings.clone("expand field is not allowed"))
			continue
		}
		append(&parsed.expand, strings.clone(field))
	}
}

string_allowed :: proc(value: string, allowed: []string) -> bool {
	if len(allowed) == 0 do return false
	for candidate in allowed {
		if value == candidate do return true
	}
	return false
}

query_unescape :: proc(value: string) -> string {
	builder := strings.builder_make()
	for i := 0; i < len(value); i += 1 {
		ch := value[i]
		if ch == '+' {
			strings.write_byte(&builder, ' ')
		} else if ch == '%' && i + 2 < len(value) {
			hex := value[i + 1:i + 3]
			byte_value, ok := strconv.parse_int(hex, 16)
			if ok {
				strings.write_byte(&builder, byte(byte_value))
				i += 2
			} else {
				strings.write_byte(&builder, ch)
			}
		} else {
			strings.write_byte(&builder, ch)
		}
	}
	return strings.to_string(builder)
}
