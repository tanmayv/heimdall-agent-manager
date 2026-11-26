package main

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/json"
import "core:sync"
import "core:os"
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
	   proof.owner != owner || proof.head_hash != answer.directory_head ||
	   proof.pin_hash != proof.head_hash || proof.pin_seq != proof.version {
		return false
	}

	dir, valid := vault.directory_verify(proof)
	if !valid || !vault.directory_verify_keyring(&dir, &kr) do return false
	root, root_found := dir.ever_approved[dir.root_device_id]
	pin, pin_ok := vault.root_pin_from_hex(dir.root_device_id, root.sign_alg, dir.root_public_key)
	if !root_found || !pin_ok || !vault.root_pin_equal(&floor.root, &pin) do return false
	target, paired := dir.trusted[device]
	if !paired || target.kind != "bridge" do return false
	signer, signer_ok := dir.trusted[answer.device]
	if !signer_ok || signer.approval_seq > proof.version || !vault.kind_policy(vault.device_kind_from_id(signer.kind)).can_approve do return false
	head: [32]byte
	if !vault.hex_decode_into(head[:], dir.head_hash) || !contracts.secure_form_directory_matches(answer, digest, sequence, head) do return false
	message, message_ok := contracts.secure_form_answer_transcript(answer)
	sig, sig_ok := vault.signature_text_from_parts(signer.sign_alg, answer.signature, context.temp_allocator)
	if !message_ok || !sig_ok || !vault.verify(signer.sign_alg, signer.sign_public_key, message, sig) do return false

	sync.mutex_lock(&secure_form_directory_mutex)
	defer sync.mutex_unlock(&secure_form_directory_mutex)
	lookup := Secure_Form_Directory_Key{owner, proof.vault_id}
	next, advanced := secure_form_directory_advance(secure_form_directory_checkpoints[lookup], &dir)
	if !advanced do return false
	if secure_form_directory_checkpoints == nil do secure_form_directory_checkpoints = make(map[Secure_Form_Directory_Key]Secure_Form_Directory_Checkpoint)
	if !(lookup in secure_form_directory_checkpoints) {
		// The map outlives the request arena.
		lookup = {strings.clone(owner), strings.clone(proof.vault_id)}
	}
	secure_form_directory_checkpoints[lookup] = next
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
