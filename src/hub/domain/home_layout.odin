package domain

import "core:encoding/json"

// Mirrors src/ui/components/home/homeLayout.ts. Results use the request arena.
HOME_LAYOUT_MAX_BYTES :: 32 * 1024
HOME_LAYOUT_MAX_OPTIONS_BYTES :: 8 * 1024
HOME_LAYOUT_MAX_VERSION :: 9_007_199_254_740_991 // JavaScript Number.MAX_SAFE_INTEGER
HOME_LAYOUT_WIDGET_IDS :: [4]string{"activity", "chains", "uptime", "fleet"}
HOME_LAYOUT_WIDGET_WIDTHS :: [4]int{2, 1, 1, 2}

Home_Widget_Layout :: struct {
	id: string,
	width: int,
	hidden: bool,
	options: json.Object `json:"options,omitempty"`,
}

Home_Layout :: struct {
	version: i64,
	widgets: []Home_Widget_Layout,
}

// The repository revision is authoritative; payload_json holds the canonical wire shape.
Home_Layout_Record :: struct {
	revision: i64,
	payload_json: string,
}

home_layout_default :: proc() -> Home_Layout {
	widths := HOME_LAYOUT_WIDGET_WIDTHS
	widgets := make([]Home_Widget_Layout, len(HOME_LAYOUT_WIDGET_IDS), context.temp_allocator)
	for id, i in HOME_LAYOUT_WIDGET_IDS do widgets[i] = {id = id, width = widths[i]}
	return {widgets = widgets}
}

home_layout_integer :: proc(value: json.Value) -> (i64, bool) {
	#partial switch n in value {
	case json.Integer:
		if n >= 0 && n <= HOME_LAYOUT_MAX_VERSION do return i64(n), true
	case json.Float:
		if n >= 0 && n <= HOME_LAYOUT_MAX_VERSION && n == f64(i64(n)) do return i64(n), true
	}
	return 0, false
}

@(private = "file")
home_layout_options_depth_ok :: proc(value: json.Value, depth: int) -> bool {
	if depth > 16 do return false
	#partial switch v in value {
	case json.Object:
		for _, child in v do if !home_layout_options_depth_ok(child, depth + 1) do return false
	case json.Array:
		for child in v do if !home_layout_options_depth_ok(child, depth + 1) do return false
	}
	return true
}

// Strict writes reject malformed fields. Reads normalize retired/missing widgets and
// legacy width/visibility/options exactly as the browser normalizer does, without writing.
home_layout_parse :: proc(payload: string, strict: bool) -> (Home_Layout, Domain_Error) {
	ids := HOME_LAYOUT_WIDGET_IDS
	widths := HOME_LAYOUT_WIDGET_WIDTHS
	invalid := domain_error(.Validation_Failed, "invalid Home layout")
	if len(payload) > HOME_LAYOUT_MAX_BYTES do return {}, domain_error(.Validation_Failed, "Home layout exceeds 32 KiB")
	value, parse_err := json.parse_string(payload, .JSON, allocator = context.temp_allocator)
	root, object_ok := value.(json.Object)
	if parse_err != nil || !object_ok do return {}, invalid
	if strict {
		for key in root do if key != "version" && key != "widgets" do return {}, invalid
	}
	version, version_ok := home_layout_integer(root["version"])
	items, array_ok := root["widgets"].(json.Array)
	if !version_ok || !array_ok || len(items) > 64 do return {}, invalid
	widgets := make([dynamic]Home_Widget_Layout, 0, 4, context.temp_allocator)
	seen: [4]bool
	for raw in items {
		item, item_ok := raw.(json.Object)
		if !item_ok {
			if strict do return {}, invalid
			continue
		}
		id, id_ok := item["id"].(string)
		index := -1
		for known, i in HOME_LAYOUT_WIDGET_IDS do if id_ok && id == known do index = i
		if index < 0 {
			if strict do return {}, invalid
			continue
		}
		if seen[index] {
			if strict do return {}, invalid
			continue
		}
		seen[index] = true
		if strict {
			for key in item do if key != "id" && key != "width" && key != "hidden" && key != "options" do return {}, invalid
		}
		width, width_ok := home_layout_integer(item["width"])
		hidden, hidden_ok := item["hidden"].(bool)
		if strict && (!width_ok || (width != 1 && width != 2) || !hidden_ok) do return {}, invalid
		widget := Home_Widget_Layout{id = ids[index], width = widths[index], hidden = hidden_ok && hidden}
		if width_ok && (width == 1 || width == 2) do widget.width = int(width)
		if options_value, present := item["options"]; present {
			options, options_ok := options_value.(json.Object)
			if !options_ok {
				if strict do return {}, invalid
			} else {
				encoded, err := json.marshal(options, allocator = context.temp_allocator)
				if err != nil || len(encoded) > HOME_LAYOUT_MAX_OPTIONS_BYTES || !home_layout_options_depth_ok(options, 0) do return {}, invalid
				if order, has_order := options["mobile_order"]; has_order {
					if _, order_ok := home_layout_integer(order); !order_ok {
						if strict do return {}, invalid
						delete_key(&options, "mobile_order")
					}
				}
				widget.options = options
			}
		}
		append(&widgets, widget)
	}
	for id, i in HOME_LAYOUT_WIDGET_IDS {
		if !seen[i] do append(&widgets, Home_Widget_Layout{id = id, width = widths[i]})
	}
	return {version = version, widgets = widgets[:]}, {}
}
