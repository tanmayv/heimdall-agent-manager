//! Disabled-cutover transport primitive. Receipts survive Bridge reconnects,
//! not daemon loss. Prepare never writes; dispatch requires its opaque ticket.
use std::{collections::HashMap, io::{self, Write}, time::{Duration, Instant}};

#[derive(Clone, PartialEq, Eq)]
pub struct Delivery {
    pub instance: String,
    pub pid: i32,
    pub launch_key: String,
    pub launch_epoch: String,
    pub run_count: String,
    pub operation_id: String,
    pub delivery_id: String,
    pub message: Vec<u8>,
    pub interrupt: bool,
}

impl std::fmt::Debug for Delivery {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Delivery").field("delivery_id", &self.delivery_id)
            .field("message_bytes", &self.message.len()).field("interrupt", &self.interrupt).finish_non_exhaustive()
    }
}

pub fn id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 256 && s.bytes().all(|b| (0x21..=0x7e).contains(&b))
}
pub fn message_valid(bytes: &[u8]) -> bool {
    if bytes.is_empty() || bytes.len() > 16 * 1024 { return false; }
    let Ok(text) = std::str::from_utf8(bytes) else { return false };
    !text.chars().any(|c| c.is_control() && c != '\n' && c != '\t')
}
impl Delivery {
    pub fn valid(&self) -> bool {
        let decimal = &self.run_count;
        self.pid > 0 && [&self.instance, &self.launch_key, &self.launch_epoch, &self.operation_id, &self.delivery_id].into_iter().all(|s| id(s))
            && !decimal.is_empty() && decimal.len() <= 19 && !decimal.starts_with('0') && decimal.bytes().all(|b| b.is_ascii_digit())
            && decimal.parse::<i64>().is_ok()
            && message_valid(&self.message)
    }
}

// Local binary protocol modes; never inferred from a transport failure.
pub const PREPARE: u8 = 0;
pub const DISPATCH: u8 = 1;
pub const QUERY: u8 = 2;
pub const PARTIAL: u8 = 0;
pub const DELIVERED: u8 = 1;
pub const RECOVERY_REQUIRED: u8 = 2;
pub const CHILD_MISMATCH: u8 = 3;

/// Trusted host configuration for a specifically validated runtime. Never read
/// from a notification request or inferred from a provider name/DEC2004 alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputProfile { id: String, settle: Duration, frame_timeout: Duration, native_ack: bool }
impl InputProfile {
    pub(crate) fn native_codex(id: String) -> Self {
        Self { id,settle:Duration::ZERO,frame_timeout:Duration::ZERO,native_ack:true }
    }
    pub fn readline_keyseq_timeout(timeout_ms: u32, settle_ms: u32) -> Result<Self, &'static str> {
        // The trusted configurator must verify a complete standalone ESC->abort
        // binding as well as this timeout; default Readline ESC is only a prefix.
        if timeout_ms==0 || timeout_ms>=settle_ms || settle_ms>10000 { return Err("notification: invalid input profile"); }
        Ok(Self { id:format!("readline-bound-escape-v1:{timeout_ms}:{settle_ms}"), settle:Duration::from_millis(settle_ms.into()),frame_timeout:Duration::from_millis(timeout_ms.into()),native_ack:false })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Receipt {
    pub ticket: String,
    pub esc_written: bool,
    pub message_written: usize,
    pub enter_written: bool,
    pub status: u8,
    pub input_profile: String,
    pub retry_after_ms: u32,
}
impl Receipt {
    pub fn absent(status: u8) -> Self {
        Self { ticket: String::new(), esc_written: false, message_written: 0, enter_written: false, status, input_profile:String::new(), retry_after_ms:0 }
    }
}
#[derive(Default)]
struct PasteProgress { native_acknowledged: bool, prefix_written: usize, suffix_written: usize, ready_at: Option<Instant>, prefix_started: Option<Instant>, suffix_started: Option<Instant> }
struct Entry { intent: Delivery, receipt: Receipt, paste: PasteProgress, paste_generation: Option<u64>, active: bool }
#[derive(Default)]
pub struct Deliveries { entries: HashMap<String, Entry>, profile: Option<InputProfile> }
impl Deliveries {
    pub(crate) fn configure_profile(&mut self, profile: InputProfile) -> Result<(), &'static str> {
        if !self.entries.is_empty() || self.profile.is_some() { return Err("notification: profile already bound"); }
        self.profile=Some(profile); Ok(())
    }
    pub(crate) fn native_acknowledged(&self, delivery: &str) -> bool { self.entries.get(delivery).is_some_and(|e|e.paste.native_acknowledged) }
    pub(crate) fn acknowledge_native(&mut self, delivery: &str) {
        if let Some(e)=self.entries.get_mut(delivery) { e.paste.native_acknowledged=true; }
    }
    pub fn pending(&self) -> bool { self.entries.values().any(|e| e.active && !e.receipt.enter_written) }

    pub(crate) fn started(&self, delivery_id: &str) -> bool {
        self.entries.get(delivery_id).is_some_and(|e| e.receipt.esc_written || e.paste.prefix_written > 0)
    }
    pub(crate) fn recover(&mut self, delivery_id: &str) -> Receipt {
        let e = self.entries.get_mut(delivery_id).unwrap();
        e.receipt.status = RECOVERY_REQUIRED;
        e.receipt.retry_after_ms=0;
        e.receipt.clone()
    }
    pub(crate) fn bind_paste_generation(&mut self, delivery_id: &str, generation: u64) -> bool {
        let started=self.started(delivery_id);
        let e=self.entries.get_mut(delivery_id).unwrap();
        if started && e.paste_generation.is_some_and(|old| old!=generation) { return false; }
        e.paste_generation=Some(generation);
        true
    }

    pub fn apply(&mut self, intent: &Delivery, mode: u8, ticket: &str, writer: &mut dyn Write) -> Result<Receipt, &'static str> {
        self.apply_at(intent,mode,ticket,writer,Instant::now())
    }
    pub(crate) fn apply_at(&mut self, intent: &Delivery, mode: u8, ticket: &str, writer: &mut dyn Write, now: Instant) -> Result<Receipt, &'static str> {
        if !intent.valid() || mode > QUERY || (mode == PREPARE && !ticket.is_empty()) || (mode != PREPARE && !id(ticket)) {
            return Err("notification: malformed request");
        }
        if mode==PREPARE && intent.interrupt && self.profile.is_none() {
            return Err("notification: interrupt_profile_unsupported_not_delivered");
        }
        if let Some(e) = self.entries.get(&intent.delivery_id) {
            if &e.intent != intent { return Err("notification: delivery id conflict"); }
        } else {
            // Never reconstruct a lost receipt by sending ESC/text again.
            if mode != PREPARE { return Ok(Receipt::absent(RECOVERY_REQUIRED)); }
            // No eviction: evicting a completed id would permit replay. A fresh
            // child is required once the bounded receipt window is exhausted.
            if self.entries.len() >= 256 { return Err("notification: receipt capacity exhausted"); }
            let mut entropy = [0u8; 32];
            getrandom::fill(&mut entropy).map_err(|_| "notification: receipt entropy unavailable")?;
            let nonce = entropy.iter().map(|b| format!("{b:02x}")).collect::<String>();
            let mut receipt = Receipt::absent(PARTIAL);
            receipt.ticket = nonce;
            if let Some(profile)=&self.profile { receipt.input_profile=profile.id.clone(); }
            self.entries.insert(intent.delivery_id.clone(), Entry { intent: intent.clone(), receipt, paste: PasteProgress::default(), paste_generation: None, active: false });
        }
        let busy = self.entries.iter().any(|(k,e)| k != &intent.delivery_id && e.active && !e.receipt.enter_written);
        let e = self.entries.get_mut(&intent.delivery_id).unwrap();
        if mode != PREPARE && e.receipt.ticket != ticket { return Ok(Receipt::absent(RECOVERY_REQUIRED)); }
        e.receipt.retry_after_ms=if e.receipt.status==PARTIAL { remaining_ms(e.paste.ready_at,now) } else { 0 };
        let frame_timeout=self.profile.as_ref().map_or(Duration::ZERO,|p| p.frame_timeout);
        if e.receipt.status==PARTIAL && frame_expired(&e.paste,now,frame_timeout) {
            e.receipt.status=RECOVERY_REQUIRED; e.receipt.retry_after_ms=0;
        }
        if mode != DISPATCH || e.receipt.enter_written || e.receipt.status == RECOVERY_REQUIRED { return Ok(e.receipt.clone()); }
        if busy { return Err("notification: another delivery is incomplete"); }
        e.active = true;
        // Keep offsets after every successful kernel write. Interrupted writes
        // report no progress; short writes resume only their unwritten suffix.
        let _ = write_remaining(writer, &e.intent, &mut e.receipt, &mut e.paste, self.profile.as_ref(),now);
        if self.profile.is_none() && frame_expired(&e.paste,now,Duration::ZERO) { e.receipt.status=RECOVERY_REQUIRED; }
        e.receipt.retry_after_ms=if e.receipt.status==PARTIAL { remaining_ms(e.paste.ready_at,now) } else { 0 };
        Ok(e.receipt.clone())
    }
}

fn remaining_ms(ready_at: Option<Instant>, now: Instant) -> u32 {
    ready_at.and_then(|at| at.checked_duration_since(now)).map_or(0,|left| left.as_millis().saturating_add(u128::from(left.subsec_nanos()%1_000_000!=0)).min(10000) as u32)
}
fn frame_expired(paste: &PasteProgress, now: Instant, timeout: Duration) -> bool {
    [(paste.prefix_written,PASTE_BEGIN.len(),paste.prefix_started),(paste.suffix_written,PASTE_END.len(),paste.suffix_started)].into_iter().any(|(written,size,at)| written>0 && written<size && at.is_none_or(|start| now.saturating_duration_since(start)>=timeout))
}

fn segment(w: &mut dyn Write, bytes: &[u8], offset: &mut usize, deadline: Instant) -> io::Result<()> {
    while *offset < bytes.len() {
        if Instant::now() >= deadline { return Err(io::ErrorKind::TimedOut.into()); }
        match w.write(&bytes[*offset..]) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => *offset += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
pub const PASTE_BEGIN: &[u8] = b"\x1b[200~";
pub const PASTE_END: &[u8] = b"\x1b[201~";
fn delimiter(w: &mut dyn Write, bytes: &[u8], offset: &mut usize, started: &mut Option<Instant>, profile: Option<&InputProfile>, now: Instant, deadline: Instant) -> io::Result<()> {
    if *offset==bytes.len() { return Ok(()); }
    if *offset==0 { *started=Some(now); }
    if let Some(profile)=profile.filter(|p|!p.native_ack) {
        let left=profile.frame_timeout.saturating_sub(now.saturating_duration_since(started.unwrap()));
        segment(w,bytes,offset,deadline.min(Instant::now()+left))
    } else {
        // Without a validated parser horizon only a complete one-write delimiter
        // is accepted. A partial delimiter enters recovery before body/Enter.
        let n=w.write(&bytes[*offset..])?;
        if n==0 { return Err(io::ErrorKind::WriteZero.into()); }
        *offset+=n;
        if *offset<bytes.len() { return Err(io::ErrorKind::WouldBlock.into()); }
        Ok(())
    }
}
fn write_remaining(w: &mut dyn Write, d: &Delivery, r: &mut Receipt, paste: &mut PasteProgress, profile: Option<&InputProfile>, now: Instant) -> io::Result<()> {
    let started=Instant::now();
    let deadline = started + Duration::from_millis(100);
    if d.interrupt && !r.esc_written {
        segment(w, b"\x1b", &mut 0, deadline)?;
        r.esc_written = true;
        paste.ready_at=Some(now.max(Instant::now())+profile.expect("interrupt profile checked before I/O").settle);
        // No sleeping child lock or queued writer. The Bridge schedules a later
        // exact-ticket dispatch after this monotonic disambiguation boundary.
        return Ok(());
    }
    if d.interrupt && profile.is_some_and(|p|p.native_ack) && !paste.native_acknowledged { return Ok(()); }
    if remaining_ms(paste.ready_at,now)>0 { return Ok(()); }
    delimiter(w,PASTE_BEGIN,&mut paste.prefix_written,&mut paste.prefix_started,profile,now,deadline)?;
    segment(w, &d.message, &mut r.message_written, deadline)?;
    delimiter(w,PASTE_END,&mut paste.suffix_written,&mut paste.suffix_started,profile,now,deadline)?;
    if !r.enter_written {
        segment(w, b"\r", &mut 0, deadline)?;
        r.enter_written = true;
    }
    // Completion means the PTY accepted all bytes, not that an agent read them.
    r.status = DELIVERED;
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub fn intent() -> Delivery { Delivery { instance:"inst".into(), pid:42, launch_key:"key".into(), launch_epoch:"epoch".into(), run_count:"1".into(), operation_id:"op".into(), delivery_id:"delivery".into(), message:b"literal $() text".to_vec(), interrupt:true } }
    pub fn store() -> Deliveries {
        let mut s=Deliveries::default(); s.configure_profile(InputProfile::readline_keyseq_timeout(50,100).unwrap()).unwrap(); s
    }
    #[test]
    fn native_profile_never_turns_elapsed_time_into_an_acknowledgment() {
        let mut d=Deliveries::default();
        d.configure_profile(InputProfile::native_codex("native-test".into())).unwrap();
        let intent=intent();let mut bytes=Vec::new();let now=Instant::now();
        let p=d.apply_at(&intent,PREPARE,"",&mut bytes,now).unwrap();
        let first=d.apply_at(&intent,DISPATCH,&p.ticket,&mut bytes,now).unwrap();
        assert!(first.esc_written);assert_eq!(bytes,b"\x1b");
        for elapsed in [1,100,10000] {
            let partial=d.apply_at(&intent,DISPATCH,&p.ticket,&mut bytes,now+Duration::from_millis(elapsed)).unwrap();
            assert_eq!(partial.status,PARTIAL);assert_eq!(bytes,b"\x1b");
        }
        d.acknowledge_native(&intent.delivery_id);
        let done=d.apply_at(&intent,DISPATCH,&p.ticket,&mut bytes,now+Duration::from_secs(11)).unwrap();
        assert_eq!(done.status,DELIVERED);
        let once=bytes.clone();assert_eq!(d.apply(&intent,DISPATCH,&p.ticket,&mut bytes).unwrap(),done);assert_eq!(bytes,once);
    }

    struct Short { bytes: Vec<u8>, budget: usize }
    impl Write for Short {
        fn write(&mut self, b: &[u8]) -> io::Result<usize> {
            if self.budget == 0 { return Err(io::ErrorKind::WouldBlock.into()); }
            let n = b.len().min(self.budget).min(2);
            self.bytes.extend_from_slice(&b[..n]); self.budget -= n; Ok(n)
        }
        fn flush(&mut self) -> io::Result<()> { Ok(()) }
    }
    #[test]
    fn notification_every_partial_boundary_and_lost_reply() {
      for text in ["literal $() text", "first\nsecond\t€😀"] {
       for interrupt in [false,true] {
        let mut d = intent(); d.message=text.as_bytes().to_vec(); d.interrupt=interrupt;
        let esc: &[u8]=if interrupt { b"\x1b" } else { b"" };
        let expected = [esc, PASTE_BEGIN, d.message.as_slice(), PASTE_END, b"\r"].concat();
        for boundary in 0..=expected.len() {
            let mut store = store(); let now=Instant::now();
            let mut w = Short { bytes:vec![], budget:boundary };
            let p = store.apply(&d, PREPARE, "", &mut w).unwrap();
            assert!(w.bytes.is_empty());
            let first=store.apply_at(&d, DISPATCH, &p.ticket, &mut w,now).unwrap();
            let base=if interrupt {200}else{0};
            let partial = if interrupt {store.apply_at(&d, DISPATCH, &p.ticket, &mut w,now+Duration::from_millis(base)).unwrap()}else{first};
            assert_eq!(partial.enter_written, boundary == expected.len());
            assert_eq!(partial.message_written,boundary.saturating_sub(esc.len()+PASTE_BEGIN.len()).min(d.message.len()));
            let queried = store.apply_at(&d, QUERY, &p.ticket, &mut w,now+Duration::from_millis(base)).unwrap();
            assert_eq!(partial, queried);
            w.budget = 999;
            let mut done=partial;
            for step in [10,120,130] { done=store.apply_at(&d, DISPATCH, &p.ticket, &mut w,now+Duration::from_millis(base+step)).unwrap(); }
            assert_eq!(done.status, DELIVERED);
            store.apply(&d, DISPATCH, &p.ticket, &mut w).unwrap();
            assert_eq!(w.bytes, expected);
        }
       }
      }
    }
    #[test]
    fn notification_conflicts_lost_host_capacity_and_serialization() {
        let d = intent(); let mut s = store(); let mut w = Short { bytes:vec![], budget:1 };
        let p = s.apply(&d, PREPARE, "", &mut w).unwrap();
        s.apply(&d, DISPATCH, &p.ticket, &mut w).unwrap();
        let mut changed = d.clone(); changed.interrupt = false;
        assert!(s.apply(&changed, PREPARE, "", &mut w).is_err());
        changed = d.clone(); changed.message.push(b'x');
        assert!(s.apply(&changed, DISPATCH, &p.ticket, &mut w).is_err());
        changed.delivery_id = "second".into();
        let p2 = s.apply(&changed, PREPARE, "", &mut w).unwrap();
        assert!(s.apply(&changed, DISPATCH, &p2.ticket, &mut w).is_err());
        assert!(s.pending());
        let mut lost = store();
        assert_eq!(lost.apply(&d, DISPATCH, &p.ticket, &mut w).unwrap().status, RECOVERY_REQUIRED);
        let replacement = lost.apply(&d, PREPARE, "", &mut w).unwrap();
        assert_ne!(replacement.ticket, p.ticket);
        assert_eq!(lost.apply(&d, DISPATCH, &p.ticket, &mut w).unwrap().status, RECOVERY_REQUIRED);
        for i in 1..256 { let mut n=d.clone(); n.delivery_id=format!("id{i}"); lost.apply(&n, PREPARE, "", &mut w).unwrap(); }
        assert!(lost.apply(&changed, PREPARE, "", &mut w).is_err());
        assert_eq!(w.bytes,b"\x1b");
    }
    #[test]
    fn notification_noninterrupt_and_invalid_text() {
        let mut d=intent(); d.interrupt=false;
        let mut s=Deliveries::default(); let mut w=Vec::new();
        let p=s.apply(&d, PREPARE, "", &mut w).unwrap();
        let r=s.apply(&d, DISPATCH, &p.ticket, &mut w).unwrap();
        assert!(!r.esc_written); assert_eq!(w,[PASTE_BEGIN,d.message.as_slice(),PASTE_END,b"\r"].concat());
        for bytes in [vec![0xff], b"bad\x1b".to_vec(),b"bad\r".to_vec(),vec![b'x';16385]] { d.message=bytes; assert!(!d.valid()); }
    }

    #[test]
    fn notification_interrupted_writer_has_finite_budget() {
        struct Interrupted;
        impl Write for Interrupted {
            fn write(&mut self,_:&[u8])->io::Result<usize> { Err(io::ErrorKind::Interrupted.into()) }
            fn flush(&mut self)->io::Result<()> { Ok(()) }
        }
        let d=intent(); let mut store=store(); let mut w=Interrupted;
        let p=store.apply(&d,PREPARE,"",&mut w).unwrap();
        let start=Instant::now();
        let r=store.apply(&d,DISPATCH,&p.ticket,&mut w).unwrap();
        assert!(start.elapsed()<Duration::from_millis(500));
        assert_eq!(r.status,PARTIAL); assert!(!r.esc_written);
    }

    #[test]
    fn notification_unverified_interrupt_has_no_default_profile_or_early_resume() {
        let d=intent(); let mut unknown=Deliveries::default(); let mut bytes=vec![];
        assert_eq!(unknown.apply(&d,PREPARE,"",&mut bytes).unwrap_err(),"notification: interrupt_profile_unsupported_not_delivered");
        assert!(bytes.is_empty());
        assert_eq!(unknown.apply(&d,QUERY,"old-ticket",&mut bytes).unwrap().status,RECOVERY_REQUIRED);
        assert!(InputProfile::readline_keyseq_timeout(0,100).is_err());
        assert!(InputProfile::readline_keyseq_timeout(100,100).is_err());
        let mut s=store(); let p=s.apply(&d,PREPARE,"",&mut bytes).unwrap(); let now=Instant::now();
        let esc=s.apply_at(&d,DISPATCH,&p.ticket,&mut bytes,now).unwrap();
        assert!(esc.esc_written && esc.retry_after_ms>0); assert_eq!(bytes,b"\x1b");
        for _ in 0..4 { let early=s.apply_at(&d,DISPATCH,&p.ticket,&mut bytes,now).unwrap(); assert_eq!(early.message_written,0); assert_eq!(bytes,b"\x1b"); }
        assert!(s.configure_profile(InputProfile::readline_keyseq_timeout(2,4).unwrap()).is_err());
        let done=s.apply_at(&d,DISPATCH,&p.ticket,&mut bytes,now+Duration::from_millis(200)).unwrap();
        assert_eq!(done.status,DELIVERED); assert_eq!(done.retry_after_ms,0);
    }

    #[test]
    fn notification_expired_or_unverified_partial_delimiter_requires_recovery() {
        for suffix in [false,true] {
            let mut d=intent(); d.interrupt=false;
            let mut s=store(); let mut w=Short { bytes:vec![],budget:if suffix {PASTE_BEGIN.len()+d.message.len()+1}else{1} };
            let p=s.apply(&d,PREPARE,"",&mut w).unwrap(); let now=Instant::now();
            let partial=s.apply_at(&d,DISPATCH,&p.ticket,&mut w,now).unwrap(); assert_eq!(partial.status,PARTIAL);
            let before=w.bytes.clone(); w.budget=999;
            assert_eq!(s.apply_at(&d,QUERY,&p.ticket,&mut w,now+Duration::from_millis(60)).unwrap().status,RECOVERY_REQUIRED);
            let expired=s.apply_at(&d,DISPATCH,&p.ticket,&mut w,now+Duration::from_millis(60)).unwrap();
            assert_eq!(expired.status,RECOVERY_REQUIRED); assert_eq!(w.bytes,before);
        }
        let mut d=intent();d.interrupt=false;let mut s=Deliveries::default();let mut w=Short {bytes:vec![],budget:1};
        let p=s.apply(&d,PREPARE,"",&mut w).unwrap();
        assert_eq!(s.apply(&d,DISPATCH,&p.ticket,&mut w).unwrap().status,RECOVERY_REQUIRED);
        assert_eq!(w.bytes,b"\x1b");
    }
}
