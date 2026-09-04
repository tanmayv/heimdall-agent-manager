//! REQ PTYH-2: Framed attach/detach protocol.
//!
//! # Wire format
//!
//! Every message is a length-prefixed frame:
//!
//! ```text
//! +--------------------+------------------------+
//! | u32 len (BE)       | payload (len bytes)    |
//! +--------------------+------------------------+
//! ```
//!
//! The first payload byte is a **tag**; the remaining bytes are the tag's
//! fields. Integers are big-endian. This is deliberately hand-rolled (no serde)
//! so the format is fully explicit + easy to reimplement from another language.
//!
//! ## client -> host
//!
//! | tag  | name    | fields                                             |
//! |------|---------|----------------------------------------------------|
//! | 0x01 | Attach  | (none)                                              |
//! | 0x02 | Input   | raw bytes -> child stdin                            |
//! | 0x03 | Key     | u8 named-key code (see [`NamedKey`])                |
//! | 0x04 | Resize  | u16 rows, u16 cols                                  |
//! | 0x05 | Capture | (none) -> host replies with Screen                 |
//! | 0x06 | Detach  | (none) -> host drops this client, child survives   |
//! | 0x07 | Ping    | (none) -> host replies Pong                         |
//!
//! ## host -> client
//!
//! | tag  | name        | fields                                          |
//! |------|-------------|-------------------------------------------------|
//! | 0x81 | Output      | raw PTY bytes                                    |
//! | 0x82 | Screen      | serialized [`ScreenSnapshot`] (see below)       |
//! | 0x83 | ChildExited | i32 exit code                                   |
//! | 0x84 | Pong        | (none)                                           |
//!
//! ### Screen payload
//!
//! ```text
//! u16 rows, u16 cols, u16 cursor_row, u16 cursor_col,
//! u16 n_lines, then n_lines × (u32 len + utf8 bytes)
//! ```

use std::io::{self, Read, Write};

/// Named keys the client can send symbolically (0x03 Key). The host translates
/// these to the canonical control/escape byte sequences before writing to the
/// PTY, so terminal apps see exactly what a real keyboard would produce.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum NamedKey {
    Enter = 1,
    Esc = 2,
    CtrlC = 3,
    Tab = 4,
    Up = 5,
    Down = 6,
    Left = 7,
    Right = 8,
    Backspace = 9,
    CtrlD = 10,
    CtrlBackslash = 11,
    Home = 12,
    End = 13,
    PageUp = 14,
    PageDown = 15,
    Delete = 16,
}

impl NamedKey {
    pub fn from_u8(v: u8) -> Option<NamedKey> {
        use NamedKey::*;
        Some(match v {
            1 => Enter,
            2 => Esc,
            3 => CtrlC,
            4 => Tab,
            5 => Up,
            6 => Down,
            7 => Left,
            8 => Right,
            9 => Backspace,
            10 => CtrlD,
            11 => CtrlBackslash,
            12 => Home,
            13 => End,
            14 => PageUp,
            15 => PageDown,
            16 => Delete,
            _ => return None,
        })
    }

    /// The bytes this key produces on an xterm-style terminal.
    pub fn to_bytes(self) -> &'static [u8] {
        use NamedKey::*;
        match self {
            Enter => b"\r",
            Esc => b"\x1b",
            CtrlC => b"\x03",
            Tab => b"\t",
            Up => b"\x1b[A",
            Down => b"\x1b[B",
            Right => b"\x1b[C",
            Left => b"\x1b[D",
            Backspace => b"\x7f",
            CtrlD => b"\x04",
            CtrlBackslash => b"\x1c",
            Home => b"\x1b[H",
            End => b"\x1b[F",
            PageUp => b"\x1b[5~",
            PageDown => b"\x1b[6~",
            Delete => b"\x1b[3~",
        }
    }
}

/// A screen snapshot sent over the wire (rendered lines + cursor + size).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScreenSnapshot {
    pub rows: u16,
    pub cols: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub lines: Vec<String>,
}

/// client -> host messages.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientMsg {
    Attach,
    Input(Vec<u8>),
    Key(NamedKey),
    Resize { rows: u16, cols: u16 },
    Capture,
    Detach,
    Ping,
}

/// host -> client messages.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostMsg {
    Output(Vec<u8>),
    Screen(ScreenSnapshot),
    ChildExited(i32),
    Pong,
}

// ---- tags ---------------------------------------------------------------

const T_ATTACH: u8 = 0x01;
const T_INPUT: u8 = 0x02;
const T_KEY: u8 = 0x03;
const T_RESIZE: u8 = 0x04;
const T_CAPTURE: u8 = 0x05;
const T_DETACH: u8 = 0x06;
const T_PING: u8 = 0x07;

const T_OUTPUT: u8 = 0x81;
const T_SCREEN: u8 = 0x82;
const T_EXITED: u8 = 0x83;
const T_PONG: u8 = 0x84;

// ---- encoding -----------------------------------------------------------

impl ClientMsg {
    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            ClientMsg::Attach => p.push(T_ATTACH),
            ClientMsg::Input(b) => {
                p.push(T_INPUT);
                p.extend_from_slice(b);
            }
            ClientMsg::Key(k) => {
                p.push(T_KEY);
                p.push(*k as u8);
            }
            ClientMsg::Resize { rows, cols } => {
                p.push(T_RESIZE);
                p.extend_from_slice(&rows.to_be_bytes());
                p.extend_from_slice(&cols.to_be_bytes());
            }
            ClientMsg::Capture => p.push(T_CAPTURE),
            ClientMsg::Detach => p.push(T_DETACH),
            ClientMsg::Ping => p.push(T_PING),
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<ClientMsg> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        Ok(match tag {
            T_ATTACH => ClientMsg::Attach,
            T_INPUT => ClientMsg::Input(rest.to_vec()),
            T_KEY => {
                let code = *rest.first().ok_or_else(|| bad("key missing code"))?;
                ClientMsg::Key(NamedKey::from_u8(code).ok_or_else(|| bad("bad key code"))?)
            }
            T_RESIZE => {
                if rest.len() < 4 {
                    return Err(bad("resize too short"));
                }
                let rows = u16::from_be_bytes([rest[0], rest[1]]);
                let cols = u16::from_be_bytes([rest[2], rest[3]]);
                ClientMsg::Resize { rows, cols }
            }
            T_CAPTURE => ClientMsg::Capture,
            T_DETACH => ClientMsg::Detach,
            T_PING => ClientMsg::Ping,
            _ => return Err(bad("unknown client tag")),
        })
    }
}

impl HostMsg {
    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            HostMsg::Output(b) => {
                p.push(T_OUTPUT);
                p.extend_from_slice(b);
            }
            HostMsg::Screen(s) => {
                p.push(T_SCREEN);
                p.extend_from_slice(&s.rows.to_be_bytes());
                p.extend_from_slice(&s.cols.to_be_bytes());
                p.extend_from_slice(&s.cursor_row.to_be_bytes());
                p.extend_from_slice(&s.cursor_col.to_be_bytes());
                p.extend_from_slice(&(s.lines.len() as u16).to_be_bytes());
                for line in &s.lines {
                    let b = line.as_bytes();
                    p.extend_from_slice(&(b.len() as u32).to_be_bytes());
                    p.extend_from_slice(b);
                }
            }
            HostMsg::ChildExited(code) => {
                p.push(T_EXITED);
                p.extend_from_slice(&code.to_be_bytes());
            }
            HostMsg::Pong => p.push(T_PONG),
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<HostMsg> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        Ok(match tag {
            T_OUTPUT => HostMsg::Output(rest.to_vec()),
            T_SCREEN => {
                if rest.len() < 10 {
                    return Err(bad("screen header too short"));
                }
                let rows = u16::from_be_bytes([rest[0], rest[1]]);
                let cols = u16::from_be_bytes([rest[2], rest[3]]);
                let cursor_row = u16::from_be_bytes([rest[4], rest[5]]);
                let cursor_col = u16::from_be_bytes([rest[6], rest[7]]);
                let n = u16::from_be_bytes([rest[8], rest[9]]) as usize;
                let mut off = 10;
                let mut lines = Vec::with_capacity(n);
                for _ in 0..n {
                    if off + 4 > rest.len() {
                        return Err(bad("screen line len truncated"));
                    }
                    let len = u32::from_be_bytes([
                        rest[off],
                        rest[off + 1],
                        rest[off + 2],
                        rest[off + 3],
                    ]) as usize;
                    off += 4;
                    if off + len > rest.len() {
                        return Err(bad("screen line body truncated"));
                    }
                    let s = String::from_utf8_lossy(&rest[off..off + len]).into_owned();
                    off += len;
                    lines.push(s);
                }
                HostMsg::Screen(ScreenSnapshot {
                    rows,
                    cols,
                    cursor_row,
                    cursor_col,
                    lines,
                })
            }
            T_EXITED => {
                if rest.len() < 4 {
                    return Err(bad("exited too short"));
                }
                let code = i32::from_be_bytes([rest[0], rest[1], rest[2], rest[3]]);
                HostMsg::ChildExited(code)
            }
            T_PONG => HostMsg::Pong,
            _ => return Err(bad("unknown host tag")),
        })
    }
}

fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

/// Read one length-prefixed frame payload from `r`. Returns `Ok(None)` on clean
/// EOF at a frame boundary.
pub fn read_frame<R: Read>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match r.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len_buf) as usize;
    // Guard against absurd frames.
    if len > 64 * 1024 * 1024 {
        return Err(bad("frame too large"));
    }
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload)?;
    Ok(Some(payload))
}

/// Read + decode one [`ClientMsg`]. `Ok(None)` on clean EOF.
pub fn read_client_msg<R: Read>(r: &mut R) -> io::Result<Option<ClientMsg>> {
    match read_frame(r)? {
        Some(p) => Ok(Some(ClientMsg::decode_payload(&p)?)),
        None => Ok(None),
    }
}

/// Read + decode one [`HostMsg`]. `Ok(None)` on clean EOF.
pub fn read_host_msg<R: Read>(r: &mut R) -> io::Result<Option<HostMsg>> {
    match read_frame(r)? {
        Some(p) => Ok(Some(HostMsg::decode_payload(&p)?)),
        None => Ok(None),
    }
}

/// Write a client message to `w`.
pub fn write_client_msg<W: Write>(w: &mut W, msg: &ClientMsg) -> io::Result<()> {
    w.write_all(&msg.encode())?;
    w.flush()
}

/// Write a host message to `w`.
pub fn write_host_msg<W: Write>(w: &mut W, msg: &HostMsg) -> io::Result<()> {
    w.write_all(&msg.encode())?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn round_client(m: ClientMsg) {
        let bytes = m.encode();
        let mut cur = Cursor::new(bytes);
        let got = read_client_msg(&mut cur).unwrap().unwrap();
        assert_eq!(got, m);
    }

    fn round_host(m: HostMsg) {
        let bytes = m.encode();
        let mut cur = Cursor::new(bytes);
        let got = read_host_msg(&mut cur).unwrap().unwrap();
        assert_eq!(got, m);
    }

    #[test]
    fn client_roundtrips() {
        round_client(ClientMsg::Attach);
        round_client(ClientMsg::Input(b"echo hi\n".to_vec()));
        round_client(ClientMsg::Key(NamedKey::CtrlC));
        round_client(ClientMsg::Resize { rows: 40, cols: 120 });
        round_client(ClientMsg::Capture);
        round_client(ClientMsg::Detach);
        round_client(ClientMsg::Ping);
    }

    #[test]
    fn host_roundtrips() {
        round_host(HostMsg::Output(b"\x1b[31mred\x1b[0m".to_vec()));
        round_host(HostMsg::ChildExited(0));
        round_host(HostMsg::ChildExited(137));
        round_host(HostMsg::Pong);
        round_host(HostMsg::Screen(ScreenSnapshot {
            rows: 24,
            cols: 80,
            cursor_row: 3,
            cursor_col: 5,
            lines: vec!["hello".into(), "".into(), "world".into()],
        }));
    }

    #[test]
    fn all_named_keys_roundtrip_and_have_bytes() {
        for code in 1u8..=16 {
            let k = NamedKey::from_u8(code).unwrap();
            assert_eq!(k as u8, code);
            assert!(!k.to_bytes().is_empty());
            round_client(ClientMsg::Key(k));
        }
    }

    #[test]
    fn multiple_frames_in_stream() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&ClientMsg::Attach.encode());
        buf.extend_from_slice(&ClientMsg::Input(b"a".to_vec()).encode());
        buf.extend_from_slice(&ClientMsg::Detach.encode());
        let mut cur = Cursor::new(buf);
        assert_eq!(read_client_msg(&mut cur).unwrap().unwrap(), ClientMsg::Attach);
        assert_eq!(
            read_client_msg(&mut cur).unwrap().unwrap(),
            ClientMsg::Input(b"a".to_vec())
        );
        assert_eq!(read_client_msg(&mut cur).unwrap().unwrap(), ClientMsg::Detach);
        assert!(read_client_msg(&mut cur).unwrap().is_none());
    }

    #[test]
    fn clean_eof_returns_none() {
        let mut cur = Cursor::new(Vec::<u8>::new());
        assert!(read_client_msg(&mut cur).unwrap().is_none());
    }
}
