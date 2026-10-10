package ws

import "core:os"
import "core:testing"
import "core:time"

@(test)
tls_pipe_write_obeys_total_deadline :: proc(t: ^testing.T) {
	r, w, err := os.pipe()
	testing.expect(t, err == nil)
	defer os.close(r)
	defer os.close(w)
	data := make([]byte, 1024 * 1024)
	defer delete(data)
	before := send_timeouts()
	started := time.tick_now()
	ok := send_all_file(w, data)
	elapsed := time.tick_since(started)
	testing.expect(t, !ok, "a full undrained pipe must fail")
	testing.expect(t, elapsed >= WRITE_DEADLINE && elapsed < WRITE_DEADLINE + time.Second)
	testing.expect(t, send_timeouts() > before, "TLS timeout must be observable")
}

@(test)
tls_pipe_small_write_is_exact :: proc(t: ^testing.T) {
	r, w, err := os.pipe()
	testing.expect(t, err == nil)
	defer os.close(r)
	defer os.close(w)
	payload := "payload"
	testing.expect(t, send_all_file(w, transmute([]byte)payload))
	data: [7]byte
	n, read_err := os.read(r, data[:])
	testing.expect(t, read_err == nil)
	testing.expect_value(t, n, 7)
	testing.expect_value(t, string(data[:]), "payload")
}

@(test)
chunk_reassembly_reserves_a_total_byte_budget :: proc(t: ^testing.T) {
 states := make([dynamic]Chunk_Reassembly)
 defer chunk_reassemblies_free(&states)
 first := chunk_json("a", 0, 2, 8, "YWJjZA==")
 defer delete(first)
 second := chunk_json("b", 0, 2, 8, "YWJjZA==")
 defer delete(second)
 _, _, ok := reassemble_chunk(&states, first, max_buffered_bytes = 12)
 testing.expect(t, ok)
 _, _, overflow_ok := reassemble_chunk(&states, second, max_buffered_bytes = 12)
 testing.expect(t, !overflow_ok)
 testing.expect_value(t, len(states), 1)
 testing.expect_value(t, states[0].received_bytes, 4)
}
