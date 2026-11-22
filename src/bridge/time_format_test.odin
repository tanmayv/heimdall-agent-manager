package main

import "core:testing"
import "core:mem"

@(test)
test_bridge_format_rfc3339_utc_ms :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    test_bridge_format_rfc3339_utc_ms_scenario(t)
    testing.expect_value(t, len(track.allocation_map), 0)
}

test_bridge_format_rfc3339_utc_ms_scenario :: proc(t: ^testing.T) {
    for c in ([]struct {ms: i64, expected: string}{
        {0, "1970-01-01T00:00:00Z"},
        {1_767_225_600_000, "2026-01-01T00:00:00Z"},
        {1_798_126_245_000, "2026-12-24T15:30:45Z"},
        {-1000, "1969-12-31T23:59:59Z"},
        {951_782_400_000, "2000-02-29T00:00:00Z"},
    }) {
        testing.expect_value(t, bridge_format_rfc3339_utc_ms(c.ms), c.expected)
    }
}
