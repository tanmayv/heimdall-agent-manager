package bridge_runtime

import "base:runtime"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "odin_test:contracts"
import project "odin_test:hub/service/project"

Secure_Form_Dispatch_Result :: enum { Queued, Stale, Busy }

Secure_Form_Dispatch_Job :: struct {
	registry: ^project.Bridge_Runtime_Registry,
	connection: ^project.Bridge_Runtime_Connection,
	payload: string,
	done: proc(rawptr, Command_Write_Result),
	ctx: rawptr,
}

// Bound concurrent live deliveries across the process. There is no backlog:
// once the sole slot is occupied, callers fail admission without copying a body.
_secure_form_dispatch_slot: i32

// Match the submission parser's worst-case JSON escaping, plus frame metadata.
SECURE_FORM_DISPATCH_MAX :: 6 * (contracts.SECURE_FORM_ENVELOPE_MAX + contracts.SECURE_FORM_PROOF_MAX) + 2048

secure_form_dispatch :: proc(registry: ^project.Bridge_Runtime_Registry, bridge: string, generation: int,
	payload: string, done: proc(rawptr, Command_Write_Result), ctx: rawptr) -> Secure_Form_Dispatch_Result {
	if registry == nil || generation <= 0 do return .Stale
	if len(payload) == 0 || len(payload) > SECURE_FORM_DISPATCH_MAX do return .Busy
	connection := project.bridge_runtime_connection_acquire(registry, bridge, generation)
	if connection == nil do return .Stale
	transferred := false
	defer if !transferred do project.bridge_runtime_connection_release(registry, connection)
	if sync.atomic_load(&connection.retired) do return .Stale
	if len(payload) > contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES {
		if !sync.mutex_try_lock(&connection.chunk_sequence_mutex) do return .Busy
		sync.unlock(&connection.chunk_sequence_mutex)
	}
	if !sync.mutex_try_lock(&connection.writer_mutex) do return .Busy
	live := connection.socket != net.TCP_Socket(0) && !sync.atomic_load(&connection.retired)
	sync.unlock(&connection.writer_mutex)
	if !live do return .Stale
	if !hub_command_is_chunkable(payload, contracts.BRIDGE_WS_HUB_TO_BRIDGE_CHUNK_PAYLOAD_BYTES) do return .Busy
	if _, ok := sync.atomic_compare_exchange_strong(&_secure_form_dispatch_slot, 0, 1); !ok do return .Busy

	heap := runtime.heap_allocator()
	// The detached thread outlives the caller. HTTP handlers run on a per-request
	// arena that is unmapped once the response is written, and core:thread
	// allocates (and, with self_cleanup, later frees) its ^Thread through
	// context.allocator. Every allocation that crosses into the thread must be
	// heap-owned, so switch the allocator for the rest of this proc body.
	context.allocator = heap
	job := new(Secure_Form_Dispatch_Job, heap)
	job^ = {registry, connection, strings.clone(payload, heap), done, ctx}
	if thread.create_and_start_with_data(job, secure_form_dispatch_run, self_cleanup = true) == nil {
		delete(job.payload, heap)
		free(job, heap)
		sync.atomic_store(&_secure_form_dispatch_slot, 0)
		return .Busy
	}
	transferred = true
	return .Queued
}

secure_form_dispatch_run :: proc(raw: rawptr) {
	job := (^Secure_Form_Dispatch_Job)(raw)
	heap := runtime.heap_allocator()
	// Use the untracked writer. The command tracker is for replayable commands.
	result := write_ws_command_on_connection(job.connection, job.payload)
	delete(job.payload, heap)
	if job.done != nil do job.done(job.ctx, result)
	project.bridge_runtime_connection_release(job.registry, job.connection)
	free(job, heap)
	sync.atomic_store(&_secure_form_dispatch_slot, 0)
}
