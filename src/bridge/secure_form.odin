package main

import "base:runtime"
import "core:mem/virtual"

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/json"
import "core:sync"
import "core:fmt"
import "core:os"
import "core:thread"
import ws "odin_test:lib/ws"
import jsonx "odin_test:lib/jsonx"
import "core:strings"
import "core:sys/posix"
import "core:time"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"
import "odin_test:contracts"

@(private)
SECURE_FORM_REGISTER_FRAME :: "secure_form_register"
@(private)
SECURE_FORM_REGISTER_ACK_FRAME :: "secure_form_register_ack"
@(private)
SECURE_FORM_ANSWER_FRAME :: "secure_form_answer"
@(private)
SECURE_FORM_DECLINE_FRAME :: "secure_form_decline"
@(private)
SECURE_FORM_CANCEL_FRAME :: "secure_form_cancel"
@(private)
SECURE_FORM_ACK_FRAME :: "secure_form_ack"

@(private)
SECURE_FORM_REGISTER_TIMEOUT_MS :: 10_000

// State only, with no secret data. The caller serializes all operations under
// the waiter lock and couples transitions with ownership of key and envelope.
@(private)
Secure_Form_Waiter_State :: struct {
	binding: contracts.Secure_Form_Retry_Binding,
	generation: string,
	registered, consumed, retained: bool,
	register_started, form_deadline, receipt: u64,
	attempt: contracts.Secure_Form_Attempt,
}

@(private)
secure_form_waiter_check_pending :: proc(s: ^Secure_Form_Waiter_State, now: u64) -> bool {
	if s.consumed || s.attempt.terminal do return false
	if now < s.register_started || (!s.registered && now - s.register_started >= SECURE_FORM_REGISTER_TIMEOUT_MS) {
		s.attempt = {1, true, .Not_Delivered}
		return false
	}
	if now >= s.form_deadline {
		s.attempt = {1, true, .Response_Expired}
		return false
	}
	return true
}

@(private)
secure_form_waiter_register_ack :: proc(s: ^Secure_Form_Waiter_State, ack: contracts.Secure_Form_Ack, now: u64) -> bool {
	if ack.request_id != s.binding.request_id || ack.generation != s.generation do return false
	if !secure_form_waiter_check_pending(s, now) || s.registered do return false
	if ack.state == "pending" && ack.code == nil {
		s.registered = true
		return true
	}
	if code, ok := ack.code.?; ack.state == "final" && ok && code == .Unauthorized {
		s.attempt = {1, true, .Unauthorized}
		return true
	}
	return false
}

// Call only after authenticating the envelope and allocating protected storage.
// Receipt is captured at the transport boundary, rather than at this decision.
@(private)
secure_form_waiter_consume :: proc(s: ^Secure_Form_Waiter_State, receipt, now: u64) -> bool {
	if !secure_form_waiter_check_pending(s, now) || !s.registered do return false
	if receipt < s.register_started || now < receipt || now - receipt >= contracts.SECURE_FORM_RETENTION_MS do return false
	s.consumed, s.retained = true, true
	s.receipt = receipt
	s.attempt = {1, false, .Unknown}
	return true
}

@(private)
secure_form_waiter_end_pending :: proc(s: ^Secure_Form_Waiter_State, now: u64, code: contracts.Secure_Form_Exit) -> bool {
	if code != .Cancelled && code != .Declined do return false
	if !secure_form_waiter_check_pending(s, now) do return false
	s.attempt = {1, true, code}
	return true
}

@(private)
secure_form_waiter_retry :: proc(s: ^Secure_Form_Waiter_State, caller: contracts.Secure_Form_Retry_Binding, now, after: u64) -> contracts.Secure_Form_Retry_Decision {
	if s.binding != caller || !s.consumed do return {.Reject, 0, .Unauthorized}
	decision := contracts.secure_form_retry(s.binding, caller, s.receipt, now, after, s.retained, s.attempt)
	if decision.action == .Start {
		s.attempt = {decision.attempt, false, .Unknown}
	}
	return decision
}

// Parse the outer envelope without reserializing its payload. The contract
// parser must see the original bytes, including duplicate or malformed keys.
@(private)
secure_form_frame_payload :: proc(raw, action: string, limit: int) -> (string, bool) {
	if len(raw) > limit do return "", false
	t := json.make_tokenizer(raw, .JSON, true)
	first, err := json.get_token(&t)
	if err != nil || first.kind != .Open_Brace do return "", false
	seen_type, seen_version := false, false
	payload := ""
	for i in 0..<3 {
		key, key_err := json.get_token(&t)
		colon, colon_err := json.get_token(&t)
		value, value_err := json.get_token(&t)
		if key_err != nil || key.kind != .String || colon_err != nil || colon.kind != .Colon || value_err != nil do return "", false
		switch key.text {
		case `"type"`:
			if seen_type || value.kind != .String || value.text[1:len(value.text)-1] != action do return "", false
			seen_type = true
		case `"protocol_version"`:
			if seen_version || value.kind != .Integer || value.text != "1" do return "", false
			seen_version = true
		case `"payload"`:
			if payload != "" || value.kind != .Open_Brace do return "", false
			start := int(uintptr(raw_data(value.text)) - uintptr(raw_data(raw)))
			depth := 1
			for depth > 0 {
				token, token_err := json.get_token(&t)
				if token_err != nil do return "", false
				#partial switch token.kind {
				case .Open_Brace, .Open_Bracket: depth += 1
				case .Close_Brace, .Close_Bracket: depth -= 1
				}
				if depth > 8 do return "", false
				if depth == 0 {
					if token.kind != .Close_Brace do return "", false
					end := int(uintptr(raw_data(token.text)) - uintptr(raw_data(raw))) + len(token.text)
					payload = raw[start:end]
				}
			}
		case:
			return "", false
		}
		separator, separator_err := json.get_token(&t)
		expected := i == 2 ? json.Token_Kind.Close_Brace : json.Token_Kind.Comma
		if separator_err != nil || separator.kind != expected do return "", false
	}
	_, eof := json.get_token(&t)
	return payload, eof == .EOF && seen_type && seen_version && payload != ""
}

@(private)
secure_form_waiter_register_frame :: proc(s: ^Secure_Form_Waiter_State, raw: string, now: u64) -> bool {
	payload, ok := secure_form_frame_payload(raw, SECURE_FORM_REGISTER_ACK_FRAME, 1152)
	if !ok do return false
	ack, parsed := contracts.secure_form_parse_ack(payload)
	return parsed && secure_form_waiter_register_ack(s, ack, now)
}

// The caller holds the waiter lock while resolving the race. Invalid and
// stale frames cannot mutate the waiter or elicit an ACK for a different one.
@(private)
secure_form_waiter_decline_frame :: proc(s: ^Secure_Form_Waiter_State, raw: string, now: u64) -> (contracts.Secure_Form_Ack, bool) {
	payload, ok := secure_form_frame_payload(raw, SECURE_FORM_DECLINE_FRAME, 1152)
	if !ok do return {}, false
	ref, parsed := contracts.secure_form_parse_reference(payload)
	if !parsed || ref.request_id != s.binding.request_id || ref.generation != s.generation do return {}, false
	if !s.registered do return {}, false
	ack := contracts.Secure_Form_Ack{1, ref.request_id, ref.generation, "accepted", nil}
	if s.consumed do return ack, true
	_ = secure_form_waiter_end_pending(s, now, .Declined)
	if !s.attempt.terminal do return {}, false
	ack.state, ack.code = "final", s.attempt.code
	return ack, true
}

// Per-vault in-memory rollback fence. Callers serialize the check and update
// so two concurrently verified proof chains cannot both advance from one pin.
@(private)
Secure_Form_Directory_Key :: struct {
	owner, vault_id: string,
}

@(private)
Secure_Form_Directory_Checkpoint :: struct {
	sequence: i64,
	head: [32]byte,
}

@(private)
secure_form_directory_mutex: sync.Mutex
@(private)
secure_form_directory_checkpoints: map[Secure_Form_Directory_Key]Secure_Form_Directory_Checkpoint

@(private)
secure_form_directory_advance :: proc(prior: Secure_Form_Directory_Checkpoint, dir: ^vault.Verified_Directory) -> (Secure_Form_Directory_Checkpoint, bool) {
	next := Secure_Form_Directory_Checkpoint{sequence = dir.version}
	if dir.version < 1 || i64(len(dir.log_hashes)) != dir.version ||
	   !vault.hex_decode_into(next.head[:], dir.head_hash) {
		return {}, false
	}
	if prior.sequence > dir.version do return {}, false
	if prior.sequence > 0 {
		prefix_head: [32]byte
		if !vault.hex_decode_into(prefix_head[:], dir.log_hashes[prior.sequence - 1]) || prefix_head != prior.head do return {}, false
	}
	return next, true
}

@(private)
secure_form_verify_device :: proc(owner, bridge_id: string, digest: [32]byte, answer: contracts.Secure_Form_Answer, exact_proof: string) -> bool {
	if len(exact_proof) == 0 || len(exact_proof) > contracts.SECURE_FORM_PROOF_MAX do return false
	kr, unlocked := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	if !unlocked do return false
	floor, floor_status := keystore_read_epoch_floor(bridge_id)
	if floor_status != .Found || !floor.root.set || epoch_floor_check(&floor, bridge_id, &kr) != .None do return false
	device, device_valid := vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_id), context.temp_allocator)
	if !device_valid do return false

	proof: vault.Directory_Verification_Input
	if json.unmarshal_string(exact_proof, &proof, .JSON, context.temp_allocator) != nil do return false
	sequence, sequence_ok := vault.directory_decimal(answer.directory_sequence)
	if !sequence_ok || proof.version < 1 || sequence != u64(proof.version) ||
	   proof.owner != owner || proof.vault_id == "" || proof.head_hash != answer.directory_head ||
	   proof.pin_hash != proof.head_hash || proof.pin_seq != proof.version {
		return false
	}

	dir, valid := vault.directory_verify(proof)
	if !valid || !vault.directory_verify_keyring(&dir, &kr) do return false
	root, root_found := dir.ever_approved[dir.root_device_id]
	pin, pin_ok := vault.root_pin_from_hex(dir.root_device_id, root.sign_alg, dir.root_public_key)
	if !root_found || !pin_ok || !vault.root_pin_equal(&floor.root, &pin) do return false
	// Observe an authenticated directory revocation even when its submitted
	// signer is no longer authorized to answer.
	sync.mutex_lock(&secure_form_directory_mutex)
	lookup := Secure_Form_Directory_Key{owner, proof.vault_id}
	next, advanced := secure_form_directory_advance(secure_form_directory_checkpoints[lookup], &dir)
	if advanced {
		if secure_form_directory_checkpoints == nil do secure_form_directory_checkpoints = make(map[Secure_Form_Directory_Key]Secure_Form_Directory_Checkpoint, runtime.heap_allocator())
		if !(lookup in secure_form_directory_checkpoints) {
			// The map outlives the request arena.
			lookup = {strings.clone(owner, runtime.heap_allocator()), strings.clone(proof.vault_id, runtime.heap_allocator())}
		}
		secure_form_directory_checkpoints[lookup] = next
	}
	sync.mutex_unlock(&secure_form_directory_mutex)
	if !advanced do return false
	target, paired := dir.trusted[device]
	if !paired || target.kind != "bridge" do return false
	signer, signer_ok := dir.trusted[answer.device]
	if !signer_ok || signer.approval_seq > proof.version || !vault.kind_policy(vault.device_kind_from_id(signer.kind)).can_approve do return false
	head: [32]byte
	if !vault.hex_decode_into(head[:], dir.head_hash) || !contracts.secure_form_directory_matches(answer, digest, sequence, head) do return false
	message, message_ok := contracts.secure_form_answer_transcript(answer)
	sig, sig_ok := vault.signature_text_from_parts(signer.sign_alg, answer.signature, context.temp_allocator)
	if !message_ok || !sig_ok || !vault.verify(signer.sign_alg, signer.sign_public_key, message, sig) do return false
	return true
}

// An allocation failure for virtual memory falls back to a private heap
// allocation. Whether page locking succeeds never controls delivery.
@(private)
Secure_Form_Secret :: struct {
	vm: Secure_Key,
	bytes: []byte,
}

@(private)
secure_form_secret_alloc :: proc(size: int) -> Secure_Form_Secret {
	if size <= 0 do return {}
	result: Secure_Form_Secret
	if key, ok := secure_key_alloc(size); ok {
		result.vm, result.bytes = key, key.ptr[:size]
	} else {
		result.bytes = make([]byte, size)
	}
	return result
}

@(private)
secure_form_secret_free :: proc(secret: ^Secure_Form_Secret) {
	if secret.vm.ptr != nil {
		secure_key_wipe_and_free(&secret.vm)
	} else if len(secret.bytes) != 0 {
		crypto.zero_explicit(raw_data(secret.bytes), len(secret.bytes))
		delete(secret.bytes)
	}
	secret^ = {}
}

// The caller must first authenticate the envelope and recheck the current
// attempt's authorization and retention window. No plaintext enters the cache.
@(private)
secure_form_open_values :: proc(scalar: []byte, digest: [32]byte, answer: contracts.Secure_Form_Answer,
	schema: contracts.Secure_Form_Schema) -> (secret: Secure_Form_Secret, ok: bool) {
	if len(scalar) != 32 || len(answer.ciphertext) > contracts.SECURE_FORM_ENVELOPE_MAX do return
	signed_digest: [32]byte
	point: [65]byte
	nonce: [12]byte
	if !vault.hex_decode_into(signed_digest[:], answer.request_digest) || signed_digest != digest ||
	   !vault.hex_decode_into(point[:], answer.sender_key) || !vault.hex_decode_into(nonce[:], answer.nonce) {
		return
	}
	ciphertext, err := base64.decode(answer.ciphertext, allocator = context.temp_allocator)
	if err != nil || len(ciphertext) <= 16 || len(ciphertext) > contracts.SECURE_FORM_PLAINTEXT_MAX + 16 do return
	prv: ecdh.Private_Key
	pub: ecdh.Public_Key
	defer ecdh.private_key_clear(&prv)
	defer ecdh.public_key_clear(&pub)
	if !ecdh.private_key_set_bytes(&prv, .SECP256R1, scalar) || !ecdh.public_key_set_bytes(&pub, .SECP256R1, point[:]) do return
	shared, key: [32]byte
	defer crypto.zero_explicit(&shared, size_of(shared))
	defer crypto.zero_explicit(&key, size_of(key))
	if !ecdh.ecdh(&prv, &pub, shared[:]) do return
	hkdf.extract_and_expand(.SHA256, signed_digest[:], shared[:], transmute([]byte)string(contracts.SECURE_FORM_ANSWER), key[:])
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:])
	defer aes.reset_gcm(&gcm)
	body_len := len(ciphertext) - 16
	candidate := secure_form_secret_alloc(body_len)
	transferred := false
	defer if !transferred do secure_form_secret_free(&candidate)
	if !aes.open_gcm(&gcm, candidate.bytes, nonce[:], signed_digest[:], ciphertext[:body_len], ciphertext[body_len:]) do return
	values, valid := contracts.secure_form_parse_values(string(candidate.bytes), schema, context.temp_allocator)
	if !valid do return
	vault.control_wipe_value(values)
	json.destroy_value(values, context.temp_allocator)
	transferred = true
	return candidate, true
}

// Build and sign the public descriptor. This has no references to caller-
// provided identity fields: placement is resolved by the admission layer.
@(private)
secure_form_sign_registration :: proc(placement: contracts.Secure_Form_Request, schema: string) -> (
	reg: contracts.Secure_Form_Registration, scalar: Secure_Form_Secret, digest: [32]byte, ok: bool) {
	if _, valid := contracts.secure_form_parse_schema(schema); !valid do return
	r := placement
	r.schema_digest = secure_form_hex_digest(schema)
	id: [32]byte
	if !os_random.fill(id[:]) do return
	r.request_id = vault.hex_encode_lower(id[:], context.temp_allocator)
	candidate := secure_form_secret_alloc(32)
	transferred := false
	defer if !transferred do secure_form_secret_free(&candidate)
	key: ecdh.Private_Key
	defer ecdh.private_key_clear(&key)
	generated := false
	for _ in 0..<8 {
		if !os_random.fill(candidate.bytes) do return
		if ecdh.private_key_set_bytes(&key, .SECP256R1, candidate.bytes) {
			generated = true
			break
		}
	}
	if !generated do return
	pub: [65]byte
	ecdh.private_key_public_bytes(&key, pub[:])
	r.recipient_key = vault.hex_encode_lower(pub[:], context.temp_allocator)
	transcript, valid := contracts.secure_form_request_transcript(r)
	if !valid do return
	record: Bridge_Identity_Record
	defer crypto.zero_explicit(&record, size_of(record))
	if keystore_read_identity(r.bridge, &record) != .Found || bridge_identity_record_owner(&record) != r.owner do return
	identity: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&identity)
	if !ecdsa.private_key_set_bytes(&identity, .SECP256R1, record.scalar[:]) do return
	sig, signed := vault.sign_p256(&identity, transcript)
	if !signed do return
	digest = contracts.secure_form_digest(transcript)
	reg = {1, r, schema, vault.hex_encode_lower(sig.sig[:], context.temp_allocator)}
	transferred = true
	return reg, candidate, digest, true
}

@(private)
secure_form_hex_digest :: proc(s: string) -> string {
	digest := contracts.secure_form_digest(transmute([]byte)s)
	return vault.hex_encode_lower(digest[:], context.temp_allocator)
}

@(private)
Secure_Form_Child_Result :: struct {
	code: contracts.Secure_Form_Exit,
	exit_code: Maybe(int),
	stdout, stderr: [dynamic]byte,
	stdout_truncated, stderr_truncated: bool,
}

@(private)
secure_form_child_result_free :: proc(result: ^Secure_Form_Child_Result) {
	if len(result.stdout) > 0 do crypto.zero_explicit(raw_data(result.stdout), len(result.stdout))
	if len(result.stderr) > 0 do crypto.zero_explicit(raw_data(result.stderr), len(result.stderr))
	delete(result.stdout)
	delete(result.stderr)
	result^ = {}
}

@(private)
secure_form_child_drain :: proc(file: ^os.File, output: ^[dynamic]byte, truncated: ^bool) -> bool {
	ready, err := os.pipe_has_data(file)
	if err != nil || !ready do return false
	buf: [8192]byte
	defer crypto.zero_explicit(&buf, size_of(buf))
	n, _ := os.read(file, buf[:])
	if n <= 0 do return false
	if output^ == nil do output^ = make([dynamic]byte, 0, BRIDGE_PROCESS_OUTPUT_LIMIT)
	keep := min(n, BRIDGE_PROCESS_OUTPUT_LIMIT - len(output))
	append(output, ..buf[:keep])
	if keep < n do truncated^ = true
	return true
}

// The gate serializes live-state checks and the nonblocking write. It is
// called with no bytes immediately before spawning. The worker retains sole
// ownership of the plaintext and must scrub it after this proc returns.
@(private)
Secure_Form_Delivery_Gate :: #type proc(ctx: rawptr, file: ^os.File, data: []byte) -> (
	wrote: int, code: contracts.Secure_Form_Exit)

@(private)
secure_form_child_start :: proc(desc: os.Process_Desc) -> (os.Process, bool) {
	when ODIN_OS == .Windows {
		return {}, false
	} else {
		args := make([]cstring, len(desc.command) + 1, context.temp_allocator)
		for arg, i in desc.command do args[i] = strings.clone_to_cstring(arg, context.temp_allocator)
		envp := posix.environ
		if desc.env != nil {
			env := make([]cstring, len(desc.env) + 1, context.temp_allocator)
			for value, i in desc.env do env[i] = strings.clone_to_cstring(value, context.temp_allocator)
			envp = raw_data(env)
		}
		cwd := strings.clone_to_cstring(desc.working_dir, context.temp_allocator)
		in_fd := posix.FD(os.fd(desc.stdin))
		out_fd := posix.FD(os.fd(desc.stdout))
		err_fd := posix.FD(os.fd(desc.stderr))
		pid := posix.fork()
		if pid < 0 do return {}, false
		if pid == 0 {
			if posix.setsid() < 0 || (desc.working_dir != "" && posix.chdir(cwd) != .OK) do posix._exit(127)
			if posix.dup2(in_fd, posix.STDIN_FILENO) < 0 ||
			   posix.dup2(out_fd, posix.STDOUT_FILENO) < 0 ||
			   posix.dup2(err_fd, posix.STDERR_FILENO) < 0 {
				posix._exit(127)
			}
			_ = posix.execve(args[0], raw_data(args), envp)
			posix._exit(127)
		}
		process, err := os.process_open(int(pid))
		if err == nil do return process, true
		_ = posix.kill(pid, .SIGKILL)
		status: i32
		for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
		return {}, false
	}
}

@(private)
secure_form_run_child :: proc(script, working_dir: string, env: []string, stdin_bytes: []byte,
	timeout: time.Duration, gate: Secure_Form_Delivery_Gate, gate_ctx: rawptr) -> (result: Secure_Form_Child_Result) {
	result.code = .Not_Delivered
	when ODIN_OS == .Windows { return }
	if gate == nil || !contracts.secure_form_path(script) || timeout <= 0 do return
	if !bridge_process_slot_try_acquire() do return
	defer bridge_process_slot_release()
	bash := bridge_runtime_find_on_path("bash")
	defer delete(bash)
	if bash == "" do return
	in_r, in_w, in_err := os.pipe()
	if in_err != nil do return
	defer if in_r != nil do os.close(in_r)
	defer if in_w != nil do os.close(in_w)
	stdout_r, stdout_w, out_err := os.pipe()
	if out_err != nil do return
	defer os.close(stdout_r)
	defer if stdout_w != nil do os.close(stdout_w)
	stderr_r, stderr_w, err_err := os.pipe()
	if err_err != nil do return
	defer os.close(stderr_r)
	defer if stderr_w != nil do os.close(stderr_w)
	when ODIN_OS != .Windows {
		fd := posix.FD(os.fd(in_w))
		flags := posix.fcntl(fd, .GETFL)
		if flags < 0 || posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK) < 0 do return
		// Only the duplicated standard handles may survive exec.
		for file in ([]^os.File{in_r, in_w, stdout_r, stdout_w, stderr_r, stderr_w}) {
			pipe_fd := posix.FD(os.fd(file))
			old := posix.fcntl(pipe_fd, .GETFD)
			if old < 0 || posix.fcntl(pipe_fd, .SETFD, old | posix.FD_CLOEXEC) < 0 do return
		}
	}
	if _, code := gate(gate_ctx, nil, nil); code != .Success {
		result.code = code
		return
	}

	process, started := secure_form_child_start({command = {bash, script}, working_dir = working_dir,
		env = env, stdin = in_r, stdout = stdout_w, stderr = stderr_w})
	if !started do return
	os.close(in_r)
	in_r = nil
	os.close(stdout_w)
	stdout_w = nil
	os.close(stderr_w)
	stderr_w = nil

	limit := time.tick_now()
	state: os.Process_State
	written := 0
	for {
		out_read := secure_form_child_drain(stdout_r, &result.stdout, &result.stdout_truncated)
		err_read := secure_form_child_drain(stderr_r, &result.stderr, &result.stderr_truncated)
		current, wait_err := os.process_wait(process, 0)
		if wait_err == nil && current.exited {
			state = current
			result.code = .Stdin_Failed if written != len(stdin_bytes) else (.Success if state.exit_code == 0 else .Child_Failed)
			break
		}
		if time.tick_since(limit) >= timeout {
			result.code = .Execution_Expired
			bridge_model_process_kill(process)
			state, _ = os.process_wait(process)
			break
		}
		if in_w != nil {
			n, code := gate(gate_ctx, in_w, stdin_bytes[written:])
			if code != .Success || n < 0 || n > len(stdin_bytes) - written {
				result.code = code if code != .Success else .Stdin_Failed
				bridge_model_process_kill(process)
				state, _ = os.process_wait(process)
				break
			}
			written += n
			if written == len(stdin_bytes) {
				os.close(in_w)
				in_w = nil
			}
		}
		if in_w == nil {
			if _, code := gate(gate_ctx, nil, nil); code == .Cancelled {
				result.code = .Cancelled
				bridge_model_process_kill(process)
				state, _ = os.process_wait(process)
				break
			}
		}
		if !out_read && !err_read do time.sleep(time.Millisecond)
	}
	if state.exited do result.exit_code = state.exit_code
	// A grandchild may still own a write fd. Drain only an already-buffered,
	// bounded tail after the invoked Bash has terminated.
	for _ in 0..<16 {
		out_read := secure_form_child_drain(stdout_r, &result.stdout, &result.stdout_truncated)
		err_read := secure_form_child_drain(stderr_r, &result.stderr, &result.stderr_truncated)
		if !out_read && !err_read do break
	}
	return
}

@(private)
SECURE_FORM_RUNTIME_LIMIT :: 16
@(private)
SECURE_FORM_LOCAL_LIVENESS_MS :: 15_000
@(private)
Secure_Form_Live :: struct {
	waiter: Secure_Form_Waiter_State,
	run_count, execution_seconds: int,
	schema, token, register_wire, ciphertext, raw_submission: string,
	digest: [32]byte,
	recipient: Secure_Form_Secret,
	receipt, last_poll, forget, output_expiry: u64,
	env: []string,
	result: Secure_Form_Child_Result,
	worker: ^thread.Thread,
	cancelled, send_accepted, send_final: bool,
}
@(private)
secure_form_live_mu: sync.Mutex
@(private)
secure_form_live: map[string]^Secure_Form_Live
@(private)
secure_form_live_generation: int
@(private)
secure_form_live_sweeper: ^thread.Thread

@(private)
secure_form_now :: proc() -> u64 {
	when ODIN_OS == .Linux {
		stamp: posix.timespec
		// Linux clockid 7 is CLOCK_BOOTTIME, which counts suspended time.
		if posix.clock_gettime(posix.Clock(7), &stamp) == .OK {
			return u64(stamp.tv_sec) * 1000 + u64(stamp.tv_nsec) / 1_000_000
		}
	}
	return u64(time.tick_now()._nsec / 1_000_000)
}

@(private)
secure_form_runtime_frame :: proc(action: string, payload: $T) -> (string, bool) {
	frame := struct {type: string, protocol_version: int, payload: T}{action, 1, payload}
	bytes, err := json.marshal(frame, allocator = context.temp_allocator)
	return string(bytes), err == nil
}

@(private)
secure_form_environment_clear :: proc(w: ^Secure_Form_Live) {
	for v in w.env {
		if len(v) > 0 do crypto.zero_explicit(raw_data(v), len(v))
		delete(v)
	}
	delete(w.env)
	w.env = nil
}

@(private)
secure_form_environment_copy :: proc(input: []string) -> []string {
	env := make([]string, len(input))
	for v, i in input do env[i] = strings.clone(v)
	return env
}

@(private)
secure_form_forget_input :: proc(w: ^Secure_Form_Live) {
	secure_form_secret_free(&w.recipient)
	if w.ciphertext != "" {
		crypto.zero_explicit(raw_data(w.ciphertext), len(w.ciphertext))
		delete(w.ciphertext)
		w.ciphertext = ""
	}
	w.waiter.retained = false
}

@(private)
secure_form_set_terminal :: proc(w: ^Secure_Form_Live, code: contracts.Secure_Form_Exit) {
	w.waiter.attempt.terminal, w.waiter.attempt.code = true, code
	if w.waiter.attempt.number == 1 do w.send_final = true
	secure_form_environment_clear(w)
}

@(private)
secure_form_sweep_locked :: proc(now: u64) {
	for id, w in secure_form_live {
		if w.worker != nil && thread.is_done(w.worker) {
			thread.destroy(w.worker)
			w.worker = nil
		}
		if !w.waiter.attempt.terminal && !w.waiter.consumed {
			if !secure_form_waiter_check_pending(&w.waiter, now) {
				w.send_final = true
				secure_form_forget_input(w)
			} else if now - w.last_poll >= SECURE_FORM_LOCAL_LIVENESS_MS {
				w.cancelled = true
				secure_form_set_terminal(w, .Cancelled)
				secure_form_forget_input(w)
			}
		}
		if w.waiter.retained && (now - w.waiter.receipt >= contracts.SECURE_FORM_RETENTION_MS || !secure_form_instance_matches(w)) {
			secure_form_forget_input(w)
		}
		if w.output_expiry > 0 && now >= w.output_expiry {
			secure_form_discard_output(w)
		}
		if w.waiter.attempt.terminal && w.worker == nil do secure_form_environment_clear(w)
		if now < w.forget || w.worker != nil do continue
		delete_key(&secure_form_live, id)
		secure_form_forget_input(w)
		secure_form_child_result_free(&w.result)
		for s in ([]string{w.schema, w.token, w.register_wire, w.raw_submission, w.waiter.generation, id,
			w.waiter.binding.owner, w.waiter.binding.bridge, w.waiter.binding.instance, w.waiter.binding.task,
			w.waiter.binding.script, w.waiter.binding.schema_digest}) {
			delete(s)
		}
		free(w)
	}
}

@(private)
secure_form_hub_connected :: proc(generation: int) {
	sync.mutex_lock(&secure_form_live_mu)
	defer sync.mutex_unlock(&secure_form_live_mu)
	secure_form_live_generation = generation
	if secure_form_live_sweeper == nil do secure_form_live_sweeper = thread.create_and_start(secure_form_sweep_worker)
}

@(private)
secure_form_sweep_worker :: proc() {
	for {
		time.sleep(250 * time.Millisecond)
		sync.mutex_lock(&secure_form_live_mu)
		secure_form_sweep_locked(secure_form_now())
		sync.mutex_unlock(&secure_form_live_mu)
	}
}

@(private)
secure_form_hub_disconnected :: proc(generation: int) {
	sync.mutex_lock(&secure_form_live_mu)
	defer sync.mutex_unlock(&secure_form_live_mu)
	if secure_form_live_generation == generation do secure_form_live_generation = 0
	generation_buf: [32]byte
	g := fmt.bprintf(generation_buf[:], "%d", generation)
	for _, w in secure_form_live {
		if w.waiter.generation != g || w.waiter.consumed || w.waiter.attempt.terminal do continue
		secure_form_set_terminal(w, .Not_Delivered if !w.waiter.registered else .Unknown)
		secure_form_forget_input(w)
	}
}

@(private)
secure_form_hub_drain :: proc(conn: ^ws.Connection, generation: int) {
	now := secure_form_now()
	generation_buf: [32]byte
	g := fmt.bprintf(generation_buf[:], "%d", generation)
	arena: virtual.Arena
	arena_ready := false
	defer if arena_ready do virtual.arena_destroy(&arena)
	frames: [3 * SECURE_FORM_RUNTIME_LIMIT]string
	count := 0
	{
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		secure_form_sweep_locked(now)
		have_frame := false
		for _, w in secure_form_live {
			if w.waiter.generation == g && (w.register_wire != "" || w.send_accepted || w.send_final) {
				have_frame = true
				break
			}
		}
		if !have_frame || virtual.arena_init_growing(&arena) != nil do return
		arena_ready = true
		context.temp_allocator = virtual.arena_allocator(&arena)
		push :: proc(frames: []string, count: ^int, value: string) {
			if count^ < len(frames) {
				frames[count^] = value
				count^ += 1
			}
		}
		for id, w in secure_form_live {
			if w.waiter.generation != g do continue
			if w.register_wire != "" {
				if !w.waiter.attempt.terminal do push(frames[:], &count, strings.clone(w.register_wire, context.temp_allocator))
				delete(w.register_wire)
				w.register_wire = ""
			}
			if w.send_accepted {
				w.send_accepted = false
				if frame, ok := secure_form_runtime_frame(SECURE_FORM_ACK_FRAME, contracts.Secure_Form_Ack{1,id,g,"accepted",nil}); ok {
					push(frames[:], &count, frame)
				}
			}
			if w.send_final {
				w.send_final = false
				if !w.waiter.consumed && (w.waiter.attempt.code == .Cancelled || w.waiter.attempt.code == .Not_Delivered) {
					if frame, ok := secure_form_runtime_frame(SECURE_FORM_CANCEL_FRAME, contracts.Secure_Form_Reference{1,id,g}); ok do push(frames[:], &count, frame)
				} else if frame, ok := secure_form_runtime_frame(SECURE_FORM_ACK_FRAME, contracts.Secure_Form_Ack{1,id,g,"final",w.waiter.attempt.code}); ok {
					push(frames[:], &count, frame)
				}
			}
		}
	}
	for frame in frames[:count] do if !bridge_hub_send(conn, frame) do return
}

@(private)
secure_form_hub_receive :: proc(conn: ^ws.Connection, generation: int, raw: string) -> bool {
	receipt := secure_form_now()
	kind := extract_json_string(raw, "type", "")
	defer delete(kind)
	if kind != SECURE_FORM_REGISTER_ACK_FRAME && kind != SECURE_FORM_DECLINE_FRAME && kind != SECURE_FORM_ANSWER_FRAME do return false
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return true
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	limit := 1152
	if kind == SECURE_FORM_ANSWER_FRAME do limit += 6 * (contracts.SECURE_FORM_ENVELOPE_MAX + contracts.SECURE_FORM_PROOF_MAX)
	payload, valid := secure_form_frame_payload(raw, kind, limit)
	if !valid do return true
	id := extract_json_string(payload, "request_id", "")
	defer delete(id)
	ref_generation := extract_json_string(payload, "generation", "")
	defer delete(ref_generation)
	if ref_generation != fmt.tprintf("%d", generation) do return true
	ack: contracts.Secure_Form_Ack
	sent := false
	{
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		w, exists := secure_form_live[id]
		if !exists || w.waiter.generation != ref_generation do return true
		switch kind {
		case SECURE_FORM_REGISTER_ACK_FRAME:
			was_terminal := w.waiter.attempt.terminal
			_ = secure_form_waiter_register_frame(&w.waiter, raw, receipt)
			if !was_terminal && w.waiter.attempt.terminal {
				if w.waiter.attempt.code == .Not_Delivered do w.send_final = true
				secure_form_forget_input(w)
			}
		case SECURE_FORM_DECLINE_FRAME:
			ack, sent = secure_form_waiter_decline_frame(&w.waiter, raw, receipt)
			if sent && ack.state == "final" do secure_form_forget_input(w)
		case SECURE_FORM_ANSWER_FRAME:
			if !w.waiter.registered || w.worker != nil || !secure_form_waiter_check_pending(&w.waiter, receipt) do return true
			w.receipt = receipt
			w.raw_submission = strings.clone(payload)
			w.worker = thread.create_and_start_with_data(w, secure_form_attempt_worker)
			if w.worker == nil {
				delete(w.raw_submission)
				w.raw_submission = ""
				secure_form_set_terminal(w, .Not_Delivered)
				secure_form_forget_input(w)
			}
		}
	}
	if sent {
		if frame, ok := secure_form_runtime_frame(SECURE_FORM_ACK_FRAME, ack); ok do _ = bridge_hub_send(conn, frame)
	}
	return true
}

@(private)
secure_form_instance_matches :: proc(w: ^Secure_Form_Live) -> bool {
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for i := len(bridge_local_token_records) - 1; i >= 0; i -= 1 {
		record := bridge_local_token_records[i]
		if record.agent_instance_id != w.waiter.binding.instance || record.role != .Agent do continue
		return record.run_count == w.run_count && record.invalidated_at_unix_ms == 0
	}
	return false
}

@(private)
secure_form_delivery :: proc(raw: rawptr, file: ^os.File, bytes: []byte) -> (int, contracts.Secure_Form_Exit) {
	w := (^Secure_Form_Live)(raw)
	sync.mutex_lock(&secure_form_live_mu)
	defer sync.mutex_unlock(&secure_form_live_mu)
	now := secure_form_now()
	if w.cancelled || now - w.last_poll >= SECURE_FORM_LOCAL_LIVENESS_MS ||
	   !secure_form_instance_matches(w) {
		return 0, .Cancelled
	}
	if !w.waiter.retained || now - w.waiter.receipt >= contracts.SECURE_FORM_RETENTION_MS do return 0, .Retention_Expired
	if len(bytes) == 0 do return 0, .Success
	when ODIN_OS != .Windows {
		n := posix.write(posix.FD(os.fd(file)), raw_data(bytes), uint(len(bytes)))
		if n >= 0 do return int(n), .Success
		if posix.errno() == .EINTR || posix.errno() == .EAGAIN do return 0, .Success
	}
	return 0, .Stdin_Failed
}

@(private)
secure_form_attempt_worker :: proc(raw: rawptr) {
	w := (^Secure_Form_Live)(raw)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		if w.raw_submission != "" do crypto.zero_explicit(raw_data(w.raw_submission), len(w.raw_submission))
		delete(w.raw_submission)
		w.raw_submission = ""
		secure_form_set_terminal(w, .Not_Delivered)
		secure_form_forget_input(w)
		return
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	submission: string
	{
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		submission, w.raw_submission = w.raw_submission, ""
	}
	if submission != "" {
		defer {
			crypto.zero_explicit(raw_data(submission), len(submission))
			delete(submission)
		}
		value, parsed := contracts.secure_form_parse_submission(submission)
		answer, answer_ok := contracts.secure_form_parse_answer(value.envelope)
		valid := parsed && answer_ok && value.request_id == w.waiter.binding.request_id && value.generation == w.waiter.generation && secure_form_verify_device(w.waiter.binding.owner, w.waiter.binding.bridge,
			w.digest, answer, value.directory_proof)
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		if w.waiter.attempt.terminal do return
		if !valid {
			secure_form_set_terminal(w, .Unauthorized)
			secure_form_forget_input(w)
			return
		}
		now := secure_form_now()
		if w.cancelled || now - w.last_poll >= SECURE_FORM_LOCAL_LIVENESS_MS {
			secure_form_set_terminal(w, .Cancelled)
			secure_form_forget_input(w)
			return
		}
		if !secure_form_waiter_consume(&w.waiter, w.receipt, now) {
			if !w.waiter.attempt.terminal do secure_form_set_terminal(w, .Retention_Expired)
			w.send_final = true
			secure_form_forget_input(w)
			return
		}
		w.forget = max(w.waiter.form_deadline, w.receipt + contracts.SECURE_FORM_RETENTION_MS + 600_000) + 60_000
		w.ciphertext = strings.clone(value.envelope)
		w.send_accepted = true
	}
	secure_form_execute_attempt(w)
}

// A retry reuses the authenticated ciphertext, not a new authorization. If
// a newer independently verified directory exists, or the pinned vault is
// locked, the retained proof can no longer establish current signer authority.
@(private)
secure_form_device_fence_live :: proc(owner, bridge: string, answer: contracts.Secure_Form_Answer) -> bool {
	kr, unlocked := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	if !unlocked || vault.keyring_user_id(&kr) != owner do return false
	floor, found := keystore_read_epoch_floor(bridge)
	if found != .Found || !floor.root.set || epoch_floor_check(&floor, bridge, &kr) != .None do return false
	seq, valid := vault.directory_decimal(answer.directory_sequence)
	head: [32]byte
	if !valid || !vault.hex_decode_into(head[:], answer.directory_head) do return false
	buf: [16]byte
	vid := vault.vault_id_hex(kr.vault_id, buf[:])
	sync.mutex_lock(&secure_form_directory_mutex)
	defer sync.mutex_unlock(&secure_form_directory_mutex)
	checkpoint := secure_form_directory_checkpoints[{owner, vid}]
	return checkpoint.sequence > 0 && u64(checkpoint.sequence) == seq && checkpoint.head == head
}

@(private)
secure_form_execute_attempt :: proc(w: ^Secure_Form_Live) {
	assertion := bridge_agent_instance_assertion(w.waiter.binding.instance)
	defer if assertion != "" {
		crypto.zero_explicit(raw_data(assertion), len(assertion))
		delete(assertion)
	}
	owner, bridge, task, _, active := secure_form_placement({
		agent_instance_id = w.waiter.binding.instance, instance_token = assertion, run_count = w.run_count, role = .Agent,
	})
	if !active || owner != w.waiter.binding.owner || bridge != w.waiter.binding.bridge || task != w.waiter.binding.task {
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		secure_form_set_terminal(w, .Unauthorized)
		secure_form_forget_input(w)
		return
	}
	scalar: Secure_Form_Secret
	defer secure_form_secret_free(&scalar)
	envelope: string
	{
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		now := secure_form_now()
		if w.cancelled {
			secure_form_set_terminal(w, .Cancelled)
			return
		}
		if !w.waiter.retained || now - w.waiter.receipt >= contracts.SECURE_FORM_RETENTION_MS {
			secure_form_set_terminal(w, .Retention_Expired)
			secure_form_forget_input(w)
			return
		}
		scalar = secure_form_secret_alloc(32)
		copy(scalar.bytes, w.recipient.bytes)
		envelope = strings.clone(w.ciphertext, context.temp_allocator)
	}
	answer, parsed := contracts.secure_form_parse_answer(envelope)
	schema, schema_ok := contracts.secure_form_parse_schema(w.schema)
	plain: Secure_Form_Secret
	opened := false
	device_ok := parsed && secure_form_device_fence_live(w.waiter.binding.owner, w.waiter.binding.bridge, answer)
	_, gate_code := secure_form_delivery(w, nil, nil)
	if device_ok && schema_ok && gate_code == .Success {
		plain, opened = secure_form_open_values(scalar.bytes, w.digest, answer, schema)
	}
	secure_form_secret_free(&scalar)
	defer secure_form_secret_free(&plain)
	child := Secure_Form_Child_Result{code = .Unauthorized if gate_code == .Success else gate_code}
	if opened {
		prefix :: "{\"version\":1,\"values\":"
		input := secure_form_secret_alloc(len(prefix) + len(plain.bytes) + 2)
		copy(input.bytes, transmute([]byte)string(prefix))
		copy(input.bytes[len(prefix):], plain.bytes)
		input.bytes[len(input.bytes) - 2], input.bytes[len(input.bytes) - 1] = '}', '\n'
		secure_form_secret_free(&plain)
		dir := w.waiter.binding.script[:max(1, strings.last_index_byte(w.waiter.binding.script, '/'))]
		child = secure_form_run_child(w.waiter.binding.script, dir, w.env, input.bytes,
			time.Duration(w.execution_seconds) * time.Second, secure_form_delivery, w)
		secure_form_secret_free(&input)
	}
	sync.mutex_lock(&secure_form_live_mu)
	defer sync.mutex_unlock(&secure_form_live_mu)
	secure_form_child_result_free(&w.result)
	w.result = child
	w.output_expiry = secure_form_now() + SECURE_FORM_LOCAL_LIVENESS_MS
	secure_form_set_terminal(w, child.code)
	if child.code == .Cancelled || child.code == .Unauthorized do secure_form_forget_input(w)
}

@(private)
secure_form_local_method :: proc(method: string) -> bool {
	return method == "agent.secure_form.run" || method == "agent.secure_form.retry" ||
		method == "agent.secure_form.poll" || method == "agent.secure_form.cancel"
}

@(private)
Secure_Form_Local_Request :: struct {
	schema, script, request_id, poll_token: string,
	timeout, execution_timeout: int,
	after_attempt, attempt: u64,
	env: []string,
}

@(private)
secure_form_local_response :: proc(id: string, code: contracts.Secure_Form_Exit) -> string {
	return bridge_local_response_data(id, fmt.tprintf("{\"terminal\":true,\"code\":%d}", int(code)))
}

@(private)
secure_form_discard_output :: proc(w: ^Secure_Form_Live) {
	exit := w.result.exit_code
	secure_form_child_result_free(&w.result)
	w.result.exit_code = exit
	w.output_expiry = 0
}

@(private)
secure_form_local_report :: proc(id: string, w: ^Secure_Form_Live, include_output: bool) -> string {
	a := w.waiter.attempt
	reply := struct {
		request_id, poll_token: string,
		attempt: u64,
		terminal: bool,
		code: int,
		exit_code: Maybe(int),
		stdout_b64, stderr_b64: string,
		stdout_truncated, stderr_truncated: bool,
	}{
		request_id = w.waiter.binding.request_id, poll_token = w.token, attempt = a.number,
		terminal = a.terminal, code = int(a.code),
	}
	if include_output && a.terminal {
		reply.exit_code = w.result.exit_code
		reply.stdout_b64 = base64.encode(w.result.stdout[:], allocator = context.temp_allocator)
		reply.stderr_b64 = base64.encode(w.result.stderr[:], allocator = context.temp_allocator)
		reply.stdout_truncated, reply.stderr_truncated = w.result.stdout_truncated, w.result.stderr_truncated
	}
	encoded, err := json.marshal(reply, allocator = context.temp_allocator)
	if err != nil do return secure_form_local_response(id, .Unknown)
	response := bridge_local_response_data(id, string(encoded))
	// Output is handed to the authenticated caller once. It is not part of
	// the retry cache. Keep the numeric exit metadata for duplicate joins.
	if include_output && a.terminal do secure_form_discard_output(w)
	for s in ([]string{reply.stdout_b64, reply.stderr_b64, string(encoded)}) {
		if s != "" do crypto.zero_explicit(raw_data(s), len(s))
	}
	return response
}

@(private)
secure_form_placement :: proc(rec: Bridge_Local_Agent_Token_Record) -> (owner, bridge, task, conversation: string, ok: bool) {
	launch, active := bridge_runtime_instance_snapshot(rec.agent_instance_id)
	if !active || launch.runtime_status != "running" || bridge_agent_instance_run_count(rec.agent_instance_id) != rec.run_count do return
	path := [?]string{"api", "v1", "agent-actions", "context"}
	relay := bridge_local_relay_agent_envelope(path[:], "agent.context.get", "{}", rec, 5000)
	defer delete(relay.body)
	if !relay.ok || relay.status != 200 do return
	ctx, has_context := jsonx.extract_raw_object(relay.body, "data", true, context.temp_allocator)
	if !has_context do return
	instance := bridge_local_extract_json_string(ctx, "agent_instance_id", "", context.temp_allocator)
	if instance != rec.agent_instance_id do return
	bridge = bridge_local_extract_json_string(ctx, "bridge_id", "", context.temp_allocator)
	if bridge != bridge_config.daemon_id do return
	conversation = bridge_local_extract_json_string(ctx, "conversation_id", "", context.temp_allocator)
	current, has_task := jsonx.extract_raw_object(ctx, "current_task", true, context.temp_allocator)
	if !has_task do return
	task = bridge_local_extract_json_string(current, "task_id", "", context.temp_allocator)
	owner = bridge_enrolled_owner_user_id(bridge)
	ok = owner != "" && task != "" && conversation != ""
	return
}

@(private)
secure_form_local_poll :: proc(id, method: string, params: Secure_Form_Local_Request, rec: Bridge_Local_Agent_Token_Record) -> string {
	sync.mutex_lock(&secure_form_live_mu)
	defer sync.mutex_unlock(&secure_form_live_mu)
	now := secure_form_now()
	secure_form_sweep_locked(now)
	w, exists := secure_form_live[params.request_id]
	if !exists || w.waiter.binding.instance != rec.agent_instance_id || w.run_count != rec.run_count ||
	   w.token != params.poll_token || params.attempt != w.waiter.attempt.number {
		return secure_form_local_response(id, .Unauthorized)
	}
	w.last_poll = now
	if method == "agent.secure_form.cancel" {
		w.cancelled = true
		secure_form_forget_input(w)
		if !w.waiter.consumed && !w.waiter.attempt.terminal do secure_form_set_terminal(w, .Cancelled)
	}
	return secure_form_local_report(id, w, method == "agent.secure_form.poll")
}

@(private)
secure_form_local_retry :: proc(id: string, params: Secure_Form_Local_Request, rec: Bridge_Local_Agent_Token_Record,
	owner, bridge, task: string) -> string {
	sync.mutex_lock(&secure_form_live_mu)
	defer sync.mutex_unlock(&secure_form_live_mu)
	now := secure_form_now()
	secure_form_sweep_locked(now)
	w, exists := secure_form_live[params.request_id]
	if !exists || w.run_count != rec.run_count do return secure_form_local_response(id, .Unauthorized)
	caller := w.waiter.binding
	caller.owner, caller.bridge, caller.task, caller.instance = owner, bridge, task, rec.agent_instance_id
	candidate := w.waiter
	decision := secure_form_waiter_retry(&candidate, caller, now, params.after_attempt)
	switch decision.action {
	case .Reject:
		return secure_form_local_response(id, decision.code)
	case .Join:
		return secure_form_local_report(id, w, false)
	case .Start:
		if w.worker != nil do return secure_form_local_response(id, .Unknown)
		token: [32]byte
		if !os_random.fill(token[:]) do return secure_form_local_response(id, .Not_Delivered)
		delete(w.token)
		w.token = vault.hex_encode_lower(token[:], context.allocator)
		w.env = secure_form_environment_copy(params.env)
		w.waiter = candidate
		w.last_poll = now
		w.worker = thread.create_and_start_with_data(w, secure_form_attempt_worker)
		if w.worker == nil do secure_form_set_terminal(w, .Unknown)
		return secure_form_local_report(id, w, false)
	}
	return secure_form_local_response(id, .Unknown)
}

@(private)
secure_form_local_start :: proc(id: string, params: Secure_Form_Local_Request, rec: Bridge_Local_Agent_Token_Record,
	owner, bridge, task, conversation: string) -> string {
	if params.timeout < 10 || params.timeout > 600 || params.execution_timeout < 1 || params.execution_timeout > 600 ||
	   !contracts.secure_form_path(params.script) || len(params.schema) > contracts.SECURE_FORM_SCHEMA_MAX {
		return secure_form_local_response(id, .Unauthorized)
	}
	kr, unlocked := bridge_read_vault_keyring()
	defer vault.keyring_wipe(&kr)
	if !unlocked do return secure_form_local_response(id, .Unauthorized)
	floor, floor_status := keystore_read_epoch_floor(bridge)
	if floor_status != .Found || !floor.root.set || epoch_floor_check(&floor, bridge, &kr) != .None {
		return secure_form_local_response(id, .Unauthorized)
	}
	generation: int
	{
		sync.mutex_lock(&secure_form_live_mu)
		defer sync.mutex_unlock(&secure_form_live_mu)
		generation = secure_form_live_generation
	}
	if generation < 1 || secure_form_live_sweeper == nil do return secure_form_local_response(id, .Not_Delivered)
	now := secure_form_now()
	deadline := now + u64(params.timeout * 1000)
	wall_deadline := time.to_unix_nanoseconds(time.now()) / 1_000_000 + i64(params.timeout * 1000)
	reg, secret, digest, signed := secure_form_sign_registration({
		owner = owner, bridge = bridge, generation = fmt.tprintf("%d", generation),
		instance = rec.agent_instance_id, task = task, conversation = conversation,
		deadline = fmt.tprintf("%d", wall_deadline), script = params.script,
	}, params.schema)
	if !signed do return secure_form_local_response(id, .Unauthorized)
	transferred := false
	defer if !transferred do secure_form_secret_free(&secret)
	wire, encoded := secure_form_runtime_frame(SECURE_FORM_REGISTER_FRAME, reg)
	if !encoded || len(wire) > 65535 do return secure_form_local_response(id, .Not_Delivered)
	token: [32]byte
	if !os_random.fill(token[:]) do return secure_form_local_response(id, .Not_Delivered)
	sync.mutex_lock(&secure_form_live_mu)
	defer sync.mutex_unlock(&secure_form_live_mu)
	secure_form_sweep_locked(now)
	if secure_form_live_generation != generation || len(secure_form_live) >= SECURE_FORM_RUNTIME_LIMIT {
		return secure_form_local_response(id, .Not_Delivered)
	}
	if secure_form_live == nil do secure_form_live = make(map[string]^Secure_Form_Live)
	if reg.request.request_id in secure_form_live do return secure_form_local_response(id, .Not_Delivered)
	w := new(Secure_Form_Live)
	w.waiter = {
		binding = {
			strings.clone(reg.request.request_id), strings.clone(reg.request.schema_digest), strings.clone(params.script),
			strings.clone(owner), strings.clone(bridge), strings.clone(rec.agent_instance_id), strings.clone(task),
		},
		generation = strings.clone(reg.request.generation), register_started = now,
		form_deadline = deadline, attempt = {1, false, .Unknown},
	}
	w.run_count, w.execution_seconds = rec.run_count, params.execution_timeout
	w.schema, w.token, w.register_wire = strings.clone(params.schema), vault.hex_encode_lower(token[:], context.allocator), strings.clone(wire)
	w.recipient, w.digest, w.last_poll, w.forget = secret, digest, now, deadline + 960_000
	w.env = secure_form_environment_copy(params.env)
	secure_form_live[w.waiter.binding.request_id] = w
	transferred = true
	return secure_form_local_report(id, w, false)
}

@(private)
secure_form_local_call :: proc(id, method, raw: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return secure_form_local_response(id, .Not_Delivered)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	if len(raw) > 512 * 1024 do return secure_form_local_response(id, .Unauthorized)
	parsed, parse_err := json.parse_string(raw, .JSON, true, context.temp_allocator)
	fields, object_ok := parsed.(json.Object)
	if parse_err != nil || !object_ok do return secure_form_local_response(id, .Unauthorized)
	defer if "env" in fields do vault.control_wipe_value(fields["env"])
	for key in fields {
		allowed := false
		switch method {
		case "agent.secure_form.run":
			allowed = key == "schema" || key == "script" || key == "timeout" || key == "execution_timeout" || key == "env"
		case "agent.secure_form.retry":
			allowed = key == "request_id" || key == "after_attempt" || key == "env"
		case "agent.secure_form.poll", "agent.secure_form.cancel":
			allowed = key == "request_id" || key == "poll_token" || key == "attempt"
		}
		if !allowed do return secure_form_local_response(id, .Unauthorized)
	}
	params: Secure_Form_Local_Request
	if json.unmarshal_string(raw, &params, .JSON, context.temp_allocator) != nil {
		return secure_form_local_response(id, .Unauthorized)
	}
	defer for v in params.env {
		if len(v) > 0 do crypto.zero_explicit(raw_data(v), len(v))
	}
	for v in params.env {
		eq := strings.index_byte(v, '=')
		if eq < 1 || strings.index_byte(v, 0) != -1 do return secure_form_local_response(id, .Unauthorized)
	}
	if method == "agent.secure_form.poll" || method == "agent.secure_form.cancel" {
		return secure_form_local_poll(id, method, params, rec)
	}
	owner, bridge, task, conversation, ok := secure_form_placement(rec)
	if !ok do return secure_form_local_response(id, .Unauthorized)
	if method == "agent.secure_form.retry" do return secure_form_local_retry(id, params, rec, owner, bridge, task)
	return secure_form_local_start(id, params, rec, owner, bridge, task, conversation)
}
