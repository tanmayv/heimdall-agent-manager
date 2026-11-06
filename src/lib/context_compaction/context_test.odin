package context_compaction

import "core:strings"
import "core:testing"

@(test)
project_counts_embedded_lines_bytes_and_duplicate_lessons :: proc(t:^testing.T) {
    items:=make([dynamic]string,context.temp_allocator)
    huge:=strings.repeat("界\n",20000,context.temp_allocator)
    for _ in 0..<100 do append(&items,huge)
    for i in 0..<100 do append(&items,strings.repeat("x",i+1000,context.temp_allocator))
    body:=project("header","full original retrieval footer",items[:])
    testing.expect(t,len(body)<=MAX_BYTES)
    lines:=strings.split_lines(body,context.temp_allocator)
    testing.expect(t,len(lines)<=MAX_LINES)
    testing.expect(t,strings.has_suffix(body,"full original retrieval footer"))
    for entry in lines do testing.expect(t,len(entry)<=MAX_LINE_BYTES)
    testing.expect(t,strings.count(body,"界")>0 && strings.count(body,"界")<170,"duplicate giant lessons consume one preview line")
    cipher:=strings.concatenate({"[task#1] vault:v2:",strings.repeat("A",30000,context.temp_allocator)},context.temp_allocator)
    preview:=line(cipher)
    testing.expect(t,!strings.contains(preview,"vault:v2:") && strings.contains(preview,"fetch original"),"never manufacture an invalid truncated cipher")
}
