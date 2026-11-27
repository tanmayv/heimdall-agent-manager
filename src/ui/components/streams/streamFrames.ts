// S1 stream piece wire contract (src/contracts/stream.odin).
const ID_BYTES = 32;
const PIECE_HEADER = 4 + ID_BYTES + 13;
const PIECE_LIMIT = 12 * 1024;
const FRAME_LIMIT = 1_000_000;
const JPEG_MIME = 'image/jpeg';

export function createFrameAssembler(streamId: string) {
  let pending: { seq: bigint; count: number; parts: Uint8Array<ArrayBuffer>[]; bytes: number } | undefined;
  let latest: bigint | undefined;

  return (wire: ArrayBuffer): Blob | undefined => {
    const bytes = new Uint8Array(wire);
    const mimeEnd = PIECE_HEADER + JPEG_MIME.length;
    if (bytes.length <= mimeEnd || bytes.length > mimeEnd + PIECE_LIMIT ||
        bytes[0] !== 4 || bytes[1] !== 0 || bytes[2] !== 0 || bytes[3] !== ID_BYTES ||
        bytes[PIECE_HEADER - 1] !== JPEG_MIME.length) return;
    for (let i = 0; i < ID_BYTES; i++) if (bytes[4 + i] !== streamId.charCodeAt(i)) return;
    for (let i = 0; i < JPEG_MIME.length; i++) {
      if (bytes[PIECE_HEADER + i] !== JPEG_MIME.charCodeAt(i)) return;
    }
    const header = new DataView(wire, 4 + ID_BYTES);
    const seq = header.getBigUint64(0);
    const index = header.getUint16(8);
    const count = header.getUint16(10);
    if (!count || index >= count || (latest !== undefined && seq <= latest)) return;
    if (pending && seq < pending.seq) return;
    if (index === 0) {
      if (pending?.seq === seq) return;
      pending = { seq, count, parts: [], bytes: 0 };
    }
    if (!pending || seq !== pending.seq || count !== pending.count ||
        index !== pending.parts.length || pending.bytes + bytes.length - mimeEnd > FRAME_LIMIT) {
      pending = undefined;
      return;
    }
    pending.parts.push(bytes.subarray(mimeEnd));
    pending.bytes += bytes.length - mimeEnd;
    if (pending.parts.length !== count) return;
    const frame = new Blob(pending.parts, { type: JPEG_MIME });
    latest = seq;
    pending = undefined;
    return frame;
  };
}
