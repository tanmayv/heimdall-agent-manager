import { deflateRawSync } from 'node:zlib';
import { crc32 } from '../../src/ui/utils/htmlBundle.ts';

export type Entry = { name: string; data: Uint8Array | string; method?: number; flags?: number; declared?: number; crc?: number; madeBy?: number; external?: number; raw?: boolean };

const enc = (s: string) => new TextEncoder().encode(s);

/** Minimal ZIP writer with full control over hostile fields. */
export function zip(entries: Entry[]): Uint8Array {
  const chunks: number[] = [];
  const u16 = (v: number) => chunks.push(v & 0xff, (v >>> 8) & 0xff);
  const u32 = (v: number) => chunks.push(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff);
  const bytes = (b: Uint8Array) => { for (const x of b) chunks.push(x); };
  const prepared = entries.map((e) => {
    const plain = typeof e.data === 'string' ? enc(e.data) : e.data;
    const method = e.method ?? 0;
    const stored = method === 8 && !e.raw ? new Uint8Array(deflateRawSync(plain)) : plain;
    return { e, plain, stored, method, name: enc(e.name), size: e.declared ?? plain.length, crc: e.crc ?? crc32(plain), offset: 0 };
  });
  for (const p of prepared) {
    p.offset = chunks.length;
    u32(0x04034b50); u16(20); u16(p.e.flags ?? 0x0800); u16(p.method); u16(0); u16(0x21); u32(p.crc); u32(p.stored.length); u32(p.size); u16(p.name.length); u16(0);
    bytes(p.name); bytes(p.stored);
  }
  const cd = chunks.length;
  for (const p of prepared) {
    u32(0x02014b50); u16(p.e.madeBy ?? 0x0314); u16(20); u16(p.e.flags ?? 0x0800); u16(p.method); u16(0); u16(0x21); u32(p.crc); u32(p.stored.length); u32(p.size);
    u16(p.name.length); u16(0); u16(0); u16(0); u16(0); u32(p.e.external ?? (0o100644 << 16) >>> 0); u32(p.offset);
    bytes(p.name);
  }
  const cdSize = chunks.length - cd;
  u32(0x06054b50); u16(0); u16(0); u16(prepared.length); u16(prepared.length); u32(cdSize); u32(cd); u16(0);
  return Uint8Array.from(chunks);
}
