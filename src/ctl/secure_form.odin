package main

import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "odin_test:contracts"
import "odin_test:lib/local_socket"

@(private)
Secure_Form_CLI_Request :: struct {
	schema, script, request_id, poll_token: string,
	timeout, execution_timeout: int,
	after_attempt, attempt: u64,
	env: []string,
}
@(private)
Secure_Form_CLI_Reply :: struct {
	request_id, poll_token, owner_link: string,
	attempt: u64,
	terminal: bool,
	code: int,
	exit_code: Maybe(int),
	stdout_b64, stderr_b64: string,
	stdout_truncated, stderr_truncated: bool,
}
@(private)
secure_form_cli_interrupt: bool

@(private)
ctl_secure_form_args :: proc(verb: string, args: []string) -> (opts: Secure_Form_CLI_Request, path: string, ok: bool) {
	if verb == "run" do opts.timeout, opts.execution_timeout = 180, 60
	seen: u8
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--agent-mode" || arg == "agent" || arg == "secure-form" || arg == verb do continue
		if !strings.has_prefix(arg, "-") do return
		if i+1 >= len(args) do return
		i += 1
		value := args[i]
		bit: u8
		switch arg {
		case "--agent-token", "--bridge-endpoint":
			continue
		case "--form":
			if verb != "run" do return
			path, bit = value, 1
		case "--script":
			if verb != "run" do return
			opts.script, bit = value, 2
		case "--timeout", "--execution-timeout":
			if verb != "run" do return
			n, parsed := strconv.parse_u64(value)
			if !parsed || n < 1 || n > 600 do return
			if arg == "--timeout" {
				if n < 10 do return
				opts.timeout, bit = int(n), 4
			} else {
				opts.execution_timeout, bit = int(n), 8
			}
		case "--request":
			if verb != "retry" || len(value) != 64 do return
			for c in value do if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') do return
			opts.request_id, bit = value, 1
		case "--after-attempt":
			if verb != "retry" || value == "" || value[0] == '0' do return
			n, parsed := strconv.parse_u64(value)
			if !parsed || n == 0 do return
			opts.after_attempt, bit = n, 2
		case:
			return
		}
		if seen & bit != 0 do return
		seen |= bit
	}
	ok = (seen & 3 == 3) &&
		(verb == "retry" || (verb == "run" && path != "" && contracts.secure_form_path(opts.script)))
	return
}

// Serialize only the members allowed for this method. In this Odin version
// omitempty does not omit numeric zero values.
@(private)
ctl_secure_form_encode :: proc(method: string, opts: Secure_Form_CLI_Request) -> ([]byte, json.Marshal_Error) {
	switch method {
	case "agent.secure_form.run":
		return json.marshal(struct {schema, script: string, timeout, execution_timeout: int, env: []string}{
			opts.schema, opts.script, opts.timeout, opts.execution_timeout, opts.env,
		})
	case "agent.secure_form.retry":
		return json.marshal(struct {request_id: string, after_attempt: u64, env: []string}{
			opts.request_id, opts.after_attempt, opts.env,
		})
	case:
		return json.marshal(struct {request_id, poll_token: string, attempt: u64}{
			opts.request_id, opts.poll_token, opts.attempt,
		})
	}
}

@(private)
ctl_secure_form_exchange :: proc(endpoint, token, method: string, opts: Secure_Form_CLI_Request) -> (reply: Secure_Form_CLI_Reply, code: contracts.Secure_Form_Exit) {
	encoded, err := ctl_secure_form_encode(method, opts)
	if err != nil do return {}, .Unauthorized
	defer {
		crypto.zero_explicit(raw_data(encoded), len(encoded))
		delete(encoded)
	}
	req := ctl_agent_jsonl_request(token, method, string(encoded))
	defer {
		crypto.zero_explicit(raw_data(req), len(req))
		delete(req)
	}
	raw: string
	got: bool
	if strings.has_prefix(endpoint, "unix:") {
		addr := strings.trim_prefix(endpoint, "unix:")
		if !local_socket.path_fits(addr) do return {}, .Not_Delivered
		sock, connected := local_socket.dial(addr)
		if !connected do return {}, .Not_Delivered
		defer local_socket.close(sock)
		for sent := 0; sent < len(req); {
			n := local_socket.send(sock, transmute([]byte)req[sent:])
			if n <= 0 do return {}, .Unknown
			sent += n
		}
		raw, got = ctl_agent_recv_unix(sock)
	} else if strings.has_prefix(endpoint, "tcp:") {
		parts := strings.split(endpoint, ":")
		defer delete(parts)
		if len(parts) != 3 do return {}, .Not_Delivered
		address, ip_ok := net.parse_ip4_address(parts[1])
		port, port_ok := strconv.parse_u64(parts[2])
		if !ip_ok || address != net.IP4_Loopback || !port_ok || port == 0 || port > 65535 do return {}, .Not_Delivered
		sock, connect_err := net.dial_tcp(address, int(port))
		if connect_err != nil do return {}, .Not_Delivered
		defer net.close(sock)
		for sent := 0; sent < len(req); {
			n, send_err := net.send_tcp(sock, transmute([]byte)req[sent:])
			if send_err != nil || n <= 0 do return {}, .Unknown
			sent += n
		}
		raw, got = ctl_agent_recv_tcp(sock)
	} else {
		return {}, .Not_Delivered
	}
	if !got || raw == "" do return {}, .Unknown
	defer {
		crypto.zero_explicit(raw_data(raw), len(raw))
		delete(raw)
	}
	envelope: struct {
		ok: bool,
		data: Secure_Form_CLI_Reply,
		error: struct {code: string},
	}
	if json.unmarshal_string(raw, &envelope, .JSON, context.temp_allocator) != nil do return {}, .Unknown
	if !envelope.ok {
		if envelope.error.code == "unauthenticated" || envelope.error.code == "forbidden" do return {}, .Unauthorized
		return {}, .Unknown
	}
	return envelope.data, .Success
}

@(private)
ctl_secure_form_print_stream :: proc(file: ^os.File, encoded: string, truncated: bool) {
	if encoded != "" && len(encoded) < 2 * 1024 * 1024 {
		buf, err := base64.decode(encoded, allocator = context.temp_allocator)
		defer if len(buf) > 0 do crypto.zero_explicit(raw_data(buf), len(buf))
		if err == nil {
			for cursor := 0; cursor < len(buf); {
				n, write_err := os.write(file, buf[cursor:])
				if n <= 0 || write_err != nil do break
				cursor += n
			}
		}
		crypto.zero_explicit(raw_data(encoded), len(encoded))
	}
	if truncated do _, _ = os.write(file, transmute([]byte)string("\n[secure-form output truncated]\n"))
}

@(private)
ctl_secure_form_owner_link_line :: proc(reply: Secure_Form_CLI_Reply, expected: string) -> string {
	if reply.request_id != expected || len(expected) != 64 do return ""
	for c in expected { if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) do return "" }
	suffix := strings.concatenate({"/#/secure-forms/", expected}, context.temp_allocator)
	if !strings.has_suffix(reply.owner_link, suffix) do return ""
	base := reply.owner_link[:len(reply.owner_link)-len(suffix)]
	if !strings.has_prefix(base, "https://") && !strings.has_prefix(base, "http://") do return ""
	if strings.contains_any(base, "?#@ \t\r\n") do return ""
	return fmt.tprintf("secure-form owner link: %s", reply.owner_link)
}

@(private)
ctl_secure_form :: proc(endpoint, token, verb: string, args: []string) {
	opts, schema_path, parsed := ctl_secure_form_args(verb, args[1:])
	if !parsed || token == "" do os.exit(int(contracts.Secure_Form_Exit.Unauthorized))
	if endpoint == "" do os.exit(int(contracts.Secure_Form_Exit.Not_Delivered))
	method := "agent.secure_form.retry"
	if verb == "run" {
		method = "agent.secure_form.run"
		file, err := os.open(schema_path)
		if err != nil do os.exit(int(contracts.Secure_Form_Exit.Unauthorized))
		buf: [contracts.SECURE_FORM_SCHEMA_MAX + 1]byte
		total := 0
		for total < len(buf) {
			n, read_err := os.read(file, buf[total:])
			total += max(0, n)
			if read_err != nil || n == 0 do break
		}
		os.close(file)
		if total > contracts.SECURE_FORM_SCHEMA_MAX do os.exit(int(contracts.Secure_Form_Exit.Unauthorized))
		opts.schema = strings.clone(string(buf[:total]), context.temp_allocator)
		if _, valid := contracts.secure_form_parse_schema(opts.schema); !valid do os.exit(int(contracts.Secure_Form_Exit.Unauthorized))
	}
	env, env_err := os.environ(context.temp_allocator)
	if env_err != nil do os.exit(int(contracts.Secure_Form_Exit.Not_Delivered))
	opts.env = env
	when ODIN_OS != .Windows {
		_ = posix.signal(.SIGINT, proc "c"(_: posix.Signal) { sync.atomic_store(&secure_form_cli_interrupt, true) })
		_ = posix.signal(.SIGTERM, proc "c"(_: posix.Signal) { sync.atomic_store(&secure_form_cli_interrupt, true) })
	}
	reply, transport_code := ctl_secure_form_exchange(endpoint, token, method, opts)
	if transport_code != .Success do os.exit(int(transport_code))
	if reply.request_id == "" {
		if !reply.terminal || reply.code < 20 || reply.code > 29 do os.exit(int(contracts.Secure_Form_Exit.Unknown))
		os.exit(reply.code)
	}
	fmt.eprintfln("secure-form request %s, attempt %d", reply.request_id, reply.attempt)
	link_printed := false
	if line := ctl_secure_form_owner_link_line(reply, reply.request_id); line != "" {
		fmt.eprintln(line)
		link_printed = true
	}
	poll := Secure_Form_CLI_Request{request_id = strings.clone(reply.request_id), poll_token = strings.clone(reply.poll_token), attempt = reply.attempt}
	initial_poll := true
	for {
		if sync.atomic_load(&secure_form_cli_interrupt) {
			_, cancel_code := ctl_secure_form_exchange(endpoint, token, "agent.secure_form.cancel", poll)
			os.exit(int(contracts.Secure_Form_Exit.Cancelled if cancel_code == .Success else cancel_code))
		}
		if !initial_poll do time.sleep(250 * time.Millisecond)
		initial_poll = false
		reply, transport_code = ctl_secure_form_exchange(endpoint, token, "agent.secure_form.poll", poll)
		if transport_code != .Success do os.exit(int(contracts.Secure_Form_Exit.Unknown))
		if !link_printed {
			if line := ctl_secure_form_owner_link_line(reply, poll.request_id); line != "" {
				fmt.eprintln(line)
				link_printed = true
			}
		}
		if !reply.terminal do continue
		if reply.code != 0 && (reply.code < 20 || reply.code > 29) do os.exit(int(contracts.Secure_Form_Exit.Unknown))
		ctl_secure_form_print_stream(os.stdout, reply.stdout_b64, reply.stdout_truncated)
		ctl_secure_form_print_stream(os.stderr, reply.stderr_b64, reply.stderr_truncated)
		if code, present := reply.exit_code.?; present do fmt.eprintfln("\nsecure-form code %d, script exit %d", reply.code, code)
		else do fmt.eprintfln("\nsecure-form code %d", reply.code)
		os.exit(reply.code)
	}
}
