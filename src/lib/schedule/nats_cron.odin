package schedule

import "core:strconv"
import "core:strings"

// The caller owns out in allocator. Intermediate parsed fields use context.allocator.
nats_cron :: proc(expr: string, allocator := context.allocator) -> (out: string, ok: bool) {
	parts := strings.fields(expr)
	defer delete(parts)
	if len(parts) != 5 do return "", false
	sets: [5][60]bool
	mins := [5]int{0, 0, 1, 1, 0}
	maxs := [5]int{59, 23, 31, 12, 7}
	for field, i in parts {
		bits := sets[i][:]
		if !parse_cron_field(field, mins[i], maxs[i], &bits) do return "", false
	}
	sets[4][0] = sets[4][0] || sets[4][7]
	maxs[4] = 6
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, "0")
	for field, i in parts {
		strings.write_byte(&builder, ' ')
		if field == "*" {
			strings.write_byte(&builder, '*')
			continue
		}
		first := true
		for v in mins[i]..=maxs[i] {
			if !sets[i][v] do continue
			if !first do strings.write_byte(&builder, ',')
			first = false
			buf: [20]u8
			strings.write_string(&builder, strconv.write_int(buf[:], i64(v), 10))
		}
	}
	return strings.to_string(builder), true
}
