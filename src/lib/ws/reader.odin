package ws

import "core:net"
import "core:strings"
import "core:time"

WS_READER_DEFAULT_MAX_BUFFER_BYTES :: 32 * 1024 * 1024
WS_CONTINUATION_DEFAULT_MAX_BYTES  :: 32 * 1024 * 1024

Frame_Disconnect_Reason :: enum {
	None,
	Clean_Close,
	Read_Deadline,
	Fatal_Frame,
	Recv_Error,
}

Frame_Reader :: struct {
	socket:                 net.TCP_Socket,
	pending:                [dynamic]u8,
	fragmented:             [dynamic]u8,
	fragmenting:            bool,
	fragmented_opcode:      u8,
	disallow_64bit:         bool,
	max_buffer_bytes:       int,
	max_continuation_bytes: int,
	disconnect_reason:      Frame_Disconnect_Reason,
	// Compatibility fields for legacy callers/tests
	assembling:             bool,
	message:                [dynamic]u8,
}

reader_make :: proc(
	socket: net.TCP_Socket = 0,
	allow_64bit: bool = true,
	max_buffer_bytes := WS_READER_DEFAULT_MAX_BUFFER_BYTES,
	max_continuation_bytes := WS_CONTINUATION_DEFAULT_MAX_BYTES,
) -> Frame_Reader {
	buf_cap := max_buffer_bytes if max_buffer_bytes > 0 else WS_READER_DEFAULT_MAX_BUFFER_BYTES
	cont_cap := max_continuation_bytes if max_continuation_bytes > 0 else WS_CONTINUATION_DEFAULT_MAX_BYTES
	return Frame_Reader{
		socket                 = socket,
		pending                = make([dynamic]u8),
		fragmented             = make([dynamic]u8),
		fragmenting            = false,
		fragmented_opcode      = 0,
		disallow_64bit         = !allow_64bit,
		max_buffer_bytes       = buf_cap,
		max_continuation_bytes = cont_cap,
		disconnect_reason      = .None,
		assembling             = false,
		message                = make([dynamic]u8),
	}
}


reader_destroy :: proc(reader: ^Frame_Reader) {
	if reader == nil do return
	delete(reader.pending)
	delete(reader.fragmented)
	delete(reader.message)
	reader.pending = nil
	reader.fragmented = nil
	reader.message = nil
	reader.fragmenting = false
	reader.assembling = false
	reader.disconnect_reason = .None
}


// parse_frame_header decodes the framing header of an RFC 6455 frame.
parse_frame_header :: proc(
	b: []u8,
	allow_64bit: bool = true,
	max_buffer_bytes := WS_READER_DEFAULT_MAX_BUFFER_BYTES,
) -> (opcode: u8, fin: bool, masked: bool, payload_len: int, header_len: int, has_header: bool, ok: bool) {
	if len(b) < 2 do return 0, false, false, 0, 0, false, true

	fin = (b[0] & 0x80) != 0
	opcode = b[0] & 0x0f

	masked = (b[1] & 0x80) != 0
	len7 := int(b[1] & 0x7f)
	header_len = 2
	payload_len = 0

	switch len7 {
	case 126:
		if len(b) < 4 do return 0, false, false, 0, 0, false, true
		payload_len = int(b[2]) << 8 | int(b[3])
		header_len = 4
	case 127:
		if !allow_64bit {
			return 0, false, false, 0, 0, false, false
		}
		if len(b) < 10 do return 0, false, false, 0, 0, false, true
		u64_len: u64 = 0
		for i in 0 ..< 8 {
			u64_len = (u64_len << 8) | u64(b[2 + i])
		}
		if (u64_len & (u64(1) << 63)) != 0 || u64_len > u64(max(int) / 2) {
			return 0, false, false, 0, 0, false, false
		}
		payload_len = int(u64_len)
		header_len = 10
	case:
		payload_len = len7
	}

	max_buf := max_buffer_bytes if max_buffer_bytes > 0 else WS_READER_DEFAULT_MAX_BUFFER_BYTES
	if payload_len > max_buf {
		return 0, false, false, 0, 0, false, false
	}

	if masked {
		header_len += 4
	}

	return opcode, fin, masked, payload_len, header_len, true, true
}

// take_one_frame_from_pending parses a single RFC 6455 frame from a pending byte buffer.
take_one_frame_from_pending :: proc(
	pending: ^[dynamic]u8,
	allow_64bit: bool = true,
	max_buffer_bytes := WS_READER_DEFAULT_MAX_BUFFER_BYTES,
) -> (opcode: u8, fin: bool, payload: string, has_frame: bool, ok: bool) {
	b := pending[:]
	op, f, masked, payload_len, header_len, has_hdr, parse_ok := parse_frame_header(b, allow_64bit, max_buffer_bytes)
	if !parse_ok do return 0, false, "", false, false
	if !has_hdr do return 0, false, "", false, true

	frame_end := header_len + payload_len
	if len(b) < frame_end do return 0, false, "", false, true

	data_off := header_len
	if masked {
		mask_off := header_len - 4
		mask_key: [4]u8
		copy(mask_key[:], b[mask_off:header_len])
		for i in 0 ..< payload_len {
			pending[data_off + i] ~= mask_key[i % 4]
		}
	}

	payload = strings.clone(string(pending[data_off:frame_end]))
	remaining := len(pending^) - frame_end
	if remaining > 0 {
		copy(pending[:], pending[frame_end:])
	}
	resize(pending, remaining)

	return op, f, payload, true, true
}

take_one_frame :: proc(reader: ^Frame_Reader) -> (opcode: u8, fin: bool, payload: string, has_frame: bool, ok: bool) {
	op, f, text, has, take_ok := take_one_frame_from_pending(&reader.pending, !reader.disallow_64bit, reader.max_buffer_bytes)
	if !take_ok {
		reader.disconnect_reason = .Fatal_Frame
	}
	return op, f, text, has, take_ok
}


take_frame :: proc(reader: ^Frame_Reader) -> (opcode: u8, payload: string, has_frame: bool, ok: bool) {
	for {
		op, fin, frame_payload, has_one, one_ok := take_one_frame(reader)
		if !one_ok {
			return 0, "", false, false
		}
		if !has_one {
			return 0, "", false, true
		}

		// Control frames (0x8 close, 0x9 ping, 0xA pong)
		if (op & 0x08) != 0 {
			if !fin {
				// RFC 6455: control frames must not be fragmented
				delete(frame_payload)
				reader.disconnect_reason = .Fatal_Frame
				return 0, "", false, false
			}
			if op == 0x8 {
				reader.disconnect_reason = .Clean_Close
			}
			return op, frame_payload, true, true
		}

		switch op {
		case 0x1, 0x2:
			if reader.fragmenting {
				delete(frame_payload)
				reader.disconnect_reason = .Fatal_Frame
				return 0, "", false, false
			}
			if fin {
				return op, frame_payload, true, true
			}
			reader.fragmenting = true
			reader.assembling = true
			reader.fragmented_opcode = op
			clear(&reader.fragmented)
			clear(&reader.message)
			append(&reader.fragmented, ..transmute([]u8)frame_payload)
			append(&reader.message, ..transmute([]u8)frame_payload)
			delete(frame_payload)
			// Loop for next frame
		case 0x0:
			if !reader.fragmenting {
				delete(frame_payload)
				reader.disconnect_reason = .Fatal_Frame
				return 0, "", false, false
			}
			max_cont := reader.max_continuation_bytes if reader.max_continuation_bytes > 0 else WS_CONTINUATION_DEFAULT_MAX_BYTES
			if len(reader.fragmented) + len(frame_payload) > max_cont {
				delete(frame_payload)
				reader.disconnect_reason = .Fatal_Frame
				return 0, "", false, false
			}
			append(&reader.fragmented, ..transmute([]u8)frame_payload)
			append(&reader.message, ..transmute([]u8)frame_payload)
			delete(frame_payload)
			if fin {
				reader.fragmenting = false
				reader.assembling = false
				clear(&reader.message)
				assembled := strings.clone(string(reader.fragmented[:]))
				clear(&reader.fragmented)
				return reader.fragmented_opcode, assembled, true, true
			}
			// Loop for next frame
		case:
			delete(frame_payload)
			reader.disconnect_reason = .Fatal_Frame
			return 0, "", false, false
		}

	}
}

read_frame :: proc(
	socket: net.TCP_Socket,
	reader: ^Frame_Reader,
	timeout: time.Duration = 0,
) -> (opcode: u8, payload: string, ok: bool) {
	reader.disconnect_reason = .None
	if op, text, has_frame, take_ok := take_frame(reader); !take_ok {
		return 0, "", false
	} else if has_frame {
		return op, text, true
	}

	if timeout > 0 {
		_ = net.set_option(socket, .Receive_Timeout, timeout)
	}

	buf: [8192]u8
	max_buf := reader.max_buffer_bytes if reader.max_buffer_bytes > 0 else WS_READER_DEFAULT_MAX_BUFFER_BYTES
	for {
		n, err := net.recv_tcp(socket, buf[:])
		if err != nil {
			if err == net.TCP_Recv_Error.Would_Block || err == net.TCP_Recv_Error.Timeout {
				reader.disconnect_reason = .Read_Deadline
			} else {
				reader.disconnect_reason = .Recv_Error
			}
			return 0, "", false
		}
		if n <= 0 {
			reader.disconnect_reason = .Clean_Close
			return 0, "", false
		}
		if len(reader.pending) + n > max_buf {
			reader.disconnect_reason = .Fatal_Frame
			return 0, "", false
		}
		append(&reader.pending, ..buf[:n])
		if op, text, has_frame, take_ok := take_frame(reader); !take_ok {
			return 0, "", false
		} else if has_frame {
			return op, text, true
		}
	}
}

read_text_blocking :: proc(
	socket: net.TCP_Socket,
	reader: ^Frame_Reader,
	timeout: time.Duration = 0,
) -> (string, bool) {
	for {
		op, payload, ok := read_frame(socket, reader, timeout)
		if !ok do return "", false
		switch op {
		case 0x8:
			delete(payload)
			reader.disconnect_reason = .Clean_Close
			return "", false
		case 0x9:
			pong := [2]u8{0x8A, 0x00}
			_, _ = net.send_tcp(socket, pong[:])
			delete(payload)
			continue
		case 0xA:
			delete(payload)
			continue
		case 0x1, 0x2:
			return payload, true
		case:
			delete(payload)
			reader.disconnect_reason = .Fatal_Frame
			return "", false
		}
	}
}
