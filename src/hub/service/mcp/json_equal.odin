package mcp

import "core:encoding/json"

// json_values_equal compares two parsed JSON values structurally (object key
// order does not matter; 1 and 1.0 compare equal).
json_values_equal :: proc(a, b: json.Value) -> bool {
	num :: proc(v: json.Value) -> (f64, bool) {
		#partial switch n in v {
		case json.Integer: return f64(n), true
		case json.Float: return f64(n), true
		}
		return 0, false
	}
	if an, aok := num(a); aok {
		bn, bok := num(b)
		return bok && an == bn
	}
	#partial switch av in a {
	case json.Null:
		_, ok := b.(json.Null); return ok
	case json.Boolean:
		bv, ok := b.(json.Boolean); return ok && av == bv
	case json.String:
		bv, ok := b.(json.String); return ok && av == bv
	case json.Array:
		bv, ok := b.(json.Array)
		if !ok || len(av) != len(bv) do return false
		for item, i in av do if !json_values_equal(item, bv[i]) do return false
		return true
	case json.Object:
		bv, ok := b.(json.Object)
		if !ok || len(av) != len(bv) do return false
		for k, v in av {
			other, has := bv[k]
			if !has || !json_values_equal(v, other) do return false
		}
		return true
	}
	return false
}
