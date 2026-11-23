package fetch

// Streaming DEFLATE (RFC 1951) decoder with a hard output cap.
//
// core:compress/zlib inflates into one in-memory buffer that it grows up to
// COMPRESS_OUTPUT_ALLOCATE_MAX (4 GiB on 64-bit) before a caller can look at
// the size, so it cannot enforce the 512 MiB extraction limit of spec §14
// step 7 early. This decoder keeps only the 32 KiB window, hands output to a
// sink as it goes, and stops as soon as the output would pass `max_out`.
//
// The structure follows zlib's reference decoder puff.c (canonical Huffman
// decoding by code length): small, and every malformed input is an error
// rather than undefined behaviour.

import "core:io"

WINDOW_SIZE :: 32768
READ_CHUNK :: 64 * 1024

// Bit_Reader reads bytes from an io.Reader, at most `limit` of them (-1 =
// unlimited), and bits LSB-first for DEFLATE.
Bit_Reader :: struct {
	r:        io.Reader,
	buf:      []byte,
	pos, n:   int,
	limit:    i64,
	consumed: i64, // bytes taken from the underlying reader so far
	bitbuf:   u64,
	bitcnt:   uint,
	io_error: bool, // a read failed (as opposed to clean end of input)
}

bit_reader_init :: proc(br: ^Bit_Reader, r: io.Reader, buf: []byte, limit: i64 = -1) {
	br^ = Bit_Reader {
		r     = r,
		buf   = buf,
		limit = limit,
	}
}

// read_byte returns false at end of input (or past the limit).
read_byte :: proc(br: ^Bit_Reader) -> (b: byte, ok: bool) {
	if br.pos >= br.n {
		if br.limit >= 0 && br.consumed >= br.limit do return 0, false
		want := len(br.buf)
		if br.limit >= 0 do want = int(min(i64(want), br.limit - br.consumed))
		n, err := io.read(br.r, br.buf[:want])
		if n <= 0 {
			if err != nil && err != .EOF do br.io_error = true
			return 0, false
		}
		br.pos, br.n = 0, n
		br.consumed += i64(n)
	}
	b = br.buf[br.pos]
	br.pos += 1
	return b, true
}

// read_full fills dst exactly; false at end of input.
read_full :: proc(br: ^Bit_Reader, dst: []byte) -> bool {
	for &d in dst {
		d = read_byte(br) or_return
	}
	return true
}

@(private)
bits :: #force_inline proc(br: ^Bit_Reader, need: uint) -> (v: u32, ok: bool) {
	for br.bitcnt < need {
		b := read_byte(br) or_return
		br.bitbuf |= u64(b) << br.bitcnt
		br.bitcnt += 8
	}
	v = u32(br.bitbuf & ((u64(1) << need) - 1))
	br.bitbuf >>= need
	br.bitcnt -= need
	return v, true
}

// align_to_byte drops the bits left in the current byte. Bits are only loaded
// when needed, so fewer than 8 remain and the next read_byte is exact.
align_to_byte :: proc(br: ^Bit_Reader) {
	br.bitbuf = 0
	br.bitcnt = 0
}

Inflate_Result :: enum {
	Ok,
	Too_Large, // output would exceed max_out
	Corrupt, // malformed stream
	Truncated, // input ended before the final block
	Read_Error, // the underlying reader failed
	Sink_Failed, // the sink refused the data
}

// Sink receives decompressed bytes in order; returning false aborts.
Sink :: struct {
	write: proc(user: rawptr, data: []byte) -> bool,
	user:  rawptr,
}

@(private)
Huffman :: struct {
	count:  [16]u16, // number of codes of each length
	symbol: [288]u16, // symbols ordered by code
}

@(private)
Inflater :: struct {
	br:          ^Bit_Reader,
	sink:        Sink,
	window:      [WINDOW_SIZE]byte,
	wpos:        int, // next write index in window
	flush_start: int, // window[flush_start:wpos] not yet given to the sink
	total:       i64,
	max_out:     i64,
	result:      Inflate_Result,
}

@(private)
LENGTH_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private)
LENGTH_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private)
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private)
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}
@(private)
CODE_LENGTH_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

// inflate decodes one raw DEFLATE stream from br into sink. On Ok, br is
// positioned at the byte after the stream (bits of the last byte dropped).
// Returns the number of bytes produced.
inflate :: proc(br: ^Bit_Reader, sink: Sink, max_out: i64) -> (total: i64, result: Inflate_Result) {
	z := new(Inflater, context.temp_allocator)
	z.br = br
	z.sink = sink
	z.max_out = max_out
	result = run_inflate(z)
	if result == .Ok && !flush(z) do result = z.result
	if result == .Truncated && br.io_error do result = .Read_Error
	return z.total, result
}

@(private)
flush :: proc(z: ^Inflater) -> bool {
	if z.wpos > z.flush_start {
		if !z.sink.write(z.sink.user, z.window[z.flush_start:z.wpos]) {
			z.result = .Sink_Failed
			return false
		}
	}
	if z.wpos == WINDOW_SIZE do z.wpos = 0
	z.flush_start = z.wpos
	return true
}

@(private)
put :: #force_inline proc(z: ^Inflater, b: byte) -> bool {
	z.window[z.wpos] = b
	z.wpos += 1
	z.total += 1
	if z.wpos == WINDOW_SIZE do return flush(z)
	return true
}

@(private)
run_inflate :: proc(z: ^Inflater) -> Inflate_Result {
	for {
		last, ok1 := bits(z.br, 1)
		if !ok1 do return .Truncated
		kind, ok2 := bits(z.br, 2)
		if !ok2 do return .Truncated
		r: Inflate_Result
		switch kind {
		case 0:
			r = stored_block(z)
		case 1:
			r = fixed_block(z)
		case 2:
			r = dynamic_block(z)
		case:
			return .Corrupt
		}
		if r != .Ok do return r
		if last == 1 {
			align_to_byte(z.br)
			return .Ok
		}
	}
}

@(private)
stored_block :: proc(z: ^Inflater) -> Inflate_Result {
	align_to_byte(z.br)
	hdr: [4]byte
	if !read_full(z.br, hdr[:]) do return .Truncated
	length := u16(hdr[0]) | u16(hdr[1]) << 8
	nlength := u16(hdr[2]) | u16(hdr[3]) << 8
	if length != ~nlength do return .Corrupt
	if z.total + i64(length) > z.max_out do return .Too_Large
	for _ in 0 ..< length {
		b, ok := read_byte(z.br)
		if !ok do return .Truncated
		if !put(z, b) do return z.result
	}
	return .Ok
}

// construct builds a canonical decoding table. Returns < 0 for an
// over-subscribed set, > 0 for an incomplete one, 0 for complete.
@(private)
construct :: proc(h: ^Huffman, lengths: []u16) -> int {
	h.count = {}
	for l in lengths do h.count[l] += 1
	if int(h.count[0]) == len(lengths) do return 0 // no codes: complete, but decoding fails
	left := 1
	for l in 1 ..< 16 {
		left <<= 1
		left -= int(h.count[l])
		if left < 0 do return left
	}
	offs: [16]u16
	for l in 1 ..< 15 do offs[l + 1] = offs[l] + h.count[l]
	for l, sym in lengths {
		if l != 0 {
			h.symbol[offs[l]] = u16(sym)
			offs[l] += 1
		}
	}
	return left
}

@(private)
decode :: proc(br: ^Bit_Reader, h: ^Huffman) -> (sym: int, ok: bool) {
	code, first, index := 0, 0, 0
	for l in 1 ..< 16 {
		b := bits(br, 1) or_return
		code |= int(b)
		count := int(h.count[l])
		if code - count < first do return int(h.symbol[index + (code - first)]), true
		index += count
		first += count
		first <<= 1
		code <<= 1
	}
	return -1, true // ran out of codes: corrupt
}

@(private)
codes :: proc(z: ^Inflater, lencode, distcode: ^Huffman) -> Inflate_Result {
	for {
		sym, ok := decode(z.br, lencode)
		if !ok do return .Truncated
		if sym < 0 do return .Corrupt
		if sym < 256 {
			if z.total + 1 > z.max_out do return .Too_Large
			if !put(z, byte(sym)) do return z.result
			continue
		}
		if sym == 256 do return .Ok
		sym -= 257
		if sym >= 29 do return .Corrupt
		extra, ok2 := bits(z.br, uint(LENGTH_EXTRA[sym]))
		if !ok2 do return .Truncated
		length := int(LENGTH_BASE[sym]) + int(extra)
		dsym, ok3 := decode(z.br, distcode)
		if !ok3 do return .Truncated
		if dsym < 0 || dsym >= 30 do return .Corrupt
		dextra, ok4 := bits(z.br, uint(DIST_EXTRA[dsym]))
		if !ok4 do return .Truncated
		dist := int(DIST_BASE[dsym]) + int(dextra)
		if i64(dist) > z.total do return .Corrupt // before the start of the output
		if z.total + i64(length) > z.max_out do return .Too_Large
		for _ in 0 ..< length {
			b := z.window[(z.wpos - dist + WINDOW_SIZE) % WINDOW_SIZE]
			if !put(z, b) do return z.result
		}
	}
}

@(private)
fixed_block :: proc(z: ^Inflater) -> Inflate_Result {
	lencode, distcode: Huffman
	lengths: [288]u16
	for i in 0 ..< 144 do lengths[i] = 8
	for i in 144 ..< 256 do lengths[i] = 9
	for i in 256 ..< 280 do lengths[i] = 7
	for i in 280 ..< 288 do lengths[i] = 8
	construct(&lencode, lengths[:])
	dl: [30]u16
	for &d in dl do d = 5
	construct(&distcode, dl[:])
	return codes(z, &lencode, &distcode)
}

@(private)
dynamic_block :: proc(z: ^Inflater) -> Inflate_Result {
	nlen_v, ok1 := bits(z.br, 5)
	ndist_v, ok2 := bits(z.br, 5)
	ncode_v, ok3 := bits(z.br, 4)
	if !(ok1 && ok2 && ok3) do return .Truncated
	nlen := int(nlen_v) + 257
	ndist := int(ndist_v) + 1
	ncode := int(ncode_v) + 4
	if nlen > 286 || ndist > 30 do return .Corrupt

	lengths: [286 + 30]u16
	for i in 0 ..< ncode {
		v, ok := bits(z.br, 3)
		if !ok do return .Truncated
		lengths[CODE_LENGTH_ORDER[i]] = u16(v)
	}
	lencode, distcode: Huffman
	if construct(&lencode, lengths[:19]) != 0 do return .Corrupt // must be complete

	lengths = {}
	index := 0
	for index < nlen + ndist {
		sym, ok := decode(z.br, &lencode)
		if !ok do return .Truncated
		if sym < 0 do return .Corrupt
		if sym < 16 {
			lengths[index] = u16(sym)
			index += 1
			continue
		}
		value: u16 = 0
		repeat: u32
		switch sym {
		case 16:
			if index == 0 do return .Corrupt
			value = lengths[index - 1]
			r, okr := bits(z.br, 2)
			if !okr do return .Truncated
			repeat = 3 + r
		case 17:
			r, okr := bits(z.br, 3)
			if !okr do return .Truncated
			repeat = 3 + r
		case:
			r, okr := bits(z.br, 7)
			if !okr do return .Truncated
			repeat = 11 + r
		}
		if index + int(repeat) > nlen + ndist do return .Corrupt
		for _ in 0 ..< repeat {
			lengths[index] = value
			index += 1
		}
	}
	if lengths[256] == 0 do return .Corrupt // no end-of-block code

	// Incomplete codes are allowed only for a single length-1 code (puff.c).
	err := construct(&lencode, lengths[:nlen])
	if err < 0 || (err > 0 && nlen - int(lencode.count[0]) != 1) do return .Corrupt
	err = construct(&distcode, lengths[nlen:nlen + ndist])
	if err < 0 || (err > 0 && ndist - int(distcode.count[0]) != 1) do return .Corrupt
	return codes(z, &lencode, &distcode)
}
