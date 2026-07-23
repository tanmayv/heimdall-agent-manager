package platform

import "core:fmt"
import "core:time"

ID_Generate_Proc :: proc(ctx: rawptr, prefix: string) -> string

ID_Generator :: struct {
	ctx: rawptr,
	generate: ID_Generate_Proc,
}

generate_id :: proc(generator: ^ID_Generator, prefix: string) -> string {
	if generator == nil || generator.generate == nil do return ""
	return generator.generate(generator.ctx, prefix)
}

real_id_generator :: proc() -> ID_Generator {
	return ID_Generator{ctx = nil, generate = time_id_generate}
}

time_id_generate :: proc(ctx: rawptr, prefix: string) -> string {
	_ = ctx
	return fmt.tprintf("%s%x", prefix, time.to_unix_nanoseconds(time.now()))
}
