//! Versioned native state observation. Nothing here authorizes a notification.
//! The declaration is fixed by trusted spawn; SessionStart only identifies the
//! current child's native session. PTY/screen/user strings cannot acknowledge ESC.
use anyhow::{anyhow, bail, Result};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap, fs, io::Read, path::{Path, PathBuf},
    process::{Command, Stdio}, time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const PROFILE: &str = "codex-native-session-v1";
const MAX_LOG: usize = 8 * 1024 * 1024;
const ACK_TIMEOUT: Duration = Duration::from_secs(8);

pub fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

#[derive(Debug)]
pub struct NativeProfile {
    pub id: String,
    cwd: PathBuf,
    root: PathBuf,
    spawned_ms: u64,
    session: Option<Session>,
    observed: Option<(String,PathBuf)>,
    invalidated: bool,
    executable: Option<fs::File>,
    pending: HashMap<String, Pending>,
}
#[derive(Debug)]
struct Session { id: String, path: PathBuf, identity: u128, header: [u8;32] }
#[derive(Debug)]
struct Pending {
    turn: String, offset: usize, prefix: [u8; 32],
    started: Instant, sent_ms: Option<u64>, acknowledged: bool,
}
struct Snapshot { bytes: Vec<u8>, rows: Vec<Value>, active: Option<String>, identity: u128 }

#[derive(Debug, PartialEq, Eq)]
pub enum Ack { Waiting, Ready, Uncertain }

/// Only Linux has a demonstrated immutable execution backend here. Seal before
/// hashing so the digest, version probe and PTY exec all refer to identical bytes.
#[cfg(target_os="linux")]
fn sealed_executable_snapshot(mut source: fs::File) -> Result<fs::File> {
    use std::{io::{Seek, SeekFrom}, os::fd::{AsRawFd, FromRawFd}};
    let metadata=source.metadata()?;
    const LIMIT: u64=512*1024*1024;
    if !metadata.is_file() || metadata.len()>LIMIT { bail!("invalid native executable size"); }
    let fd=unsafe { libc::memfd_create(c"heimdall-native-executable".as_ptr(),
        libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING) };
    if fd<0 { return Err(std::io::Error::last_os_error().into()); }
    // FromRawFd transfers ownership immediately, including all error paths.
    let mut snapshot=unsafe { fs::File::from_raw_fd(fd) };
    let copied=std::io::copy(&mut (&mut source).take(LIMIT+1),&mut snapshot)?;
    if copied>LIMIT { bail!("native executable grew beyond bound"); }
    let seals=libc::F_SEAL_WRITE | libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_SEAL;
    if unsafe { libc::fcntl(snapshot.as_raw_fd(),libc::F_ADD_SEALS,seals) }<0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let actual=unsafe { libc::fcntl(snapshot.as_raw_fd(),libc::F_GET_SEALS) };
    if actual<0 || actual & seals != seals { bail!("native executable not sealed"); }
    snapshot.seek(SeekFrom::Start(0))?;
    Ok(snapshot)
}
#[cfg(not(target_os="linux"))]
fn sealed_executable_snapshot(_: fs::File) -> Result<fs::File> {
    bail!("immutable native executable backend unavailable")
}

impl NativeProfile {
    /// A declaration never overrides an executable or chooses arbitrary timing.
    /// Unknown binaries/versions remain normal children with no native capability.
    pub fn for_spawn(program: &str, cwd: Option<&str>, env: &[(String,String)], declaration: Option<&str>) -> Result<Option<Self>> {
        let Some(declaration)=declaration else { return Ok(None) };
        if declaration != PROFILE { bail!("notification profile: unknown declaration"); }
        // portable-pty closes inherited descriptors. Linux can execute the
        // daemon-held fd through procfs; Darwin needs its own proven backend.
        if !cfg!(target_os="linux") {
            #[cfg(target_os="macos")]
            let _=crate::darwin_image::Candidate::inspect(Path::new(program),crate::darwin_image::MAC_CODEX_SHA256)
                .and_then(|candidate|candidate.authorize_activation());
            // No accepted lifetime-policy constructor or native backend exists.
            // Inspection must never implicitly enable a profile, even if a
            // future refactor changes the inspection result.
            return Ok(None);
        }
        let path=Path::new(program);
        if !path.is_absolute() || path.file_name().and_then(|n| n.to_str())!=Some("codex") { return Ok(None); }
        let executable=fs::canonicalize(path)?;
        let source=fs::File::open(&executable)?;
        // Pin immutable bytes, not just an inode: a same-UID installer/child
        // can overwrite the original file in place after admission.
        let mut file=sealed_executable_snapshot(source)?;
        let metadata=file.metadata()?;
        if !metadata.is_file() || metadata.len()>512*1024*1024 { return Ok(None); }
        let mut header=[0u8;4]; file.read_exact(&mut header)?;
        if header!=*b"\x7fELF" && ![b"\xcf\xfa\xed\xfe",b"\xfe\xed\xfa\xcf",b"\xca\xfe\xba\xbe"].contains(&&header) { return Ok(None); }
        let mut digest=Sha256::new(); digest.update(header);
        let mut buffer=[0u8;65536];
        loop { let n=file.read(&mut buffer)?; if n==0 { break } digest.update(&buffer[..n]); }
        let hash=digest.finalize().iter().map(|b|format!("{b:02x}")).collect::<String>();
        // Actual native release bytes observed on the supported Linux host.
        // A version string or arbitrary spawn declaration is never admission.
        if hash!="50ed828f357c655a3c82054d346cab8434f24901f14ec19b8267571bdd008b38" { return Ok(None); }
        #[cfg(unix)]
        let pinned={use std::os::fd::AsRawFd;format!("/proc/{}/fd/{}",std::process::id(),file.as_raw_fd())};
        #[cfg(not(unix))]
        let pinned=String::new();
        // Both version validation and the eventual PTY exec use this held fd,
        // never a second lookup of the caller-controlled executable path.
        let mut probe=Command::new(&pinned);
        probe.arg("--version").stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        for (name,_) in std::env::vars_os() {
            if name.to_string_lossy().starts_with("HEIMDALL_") { probe.env_remove(name); }
        }
        let mut child=probe.spawn()?;
        let start=Instant::now();
        let success=loop {
            if let Some(status)=child.try_wait()? { break status.success(); }
            if start.elapsed()>Duration::from_secs(2) { let _=child.kill(); let _=child.wait(); return Ok(None); }
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut output=String::new();
        child.stdout.take().ok_or_else(||anyhow!("missing version output"))?.take(4097).read_to_string(&mut output)?;
        if !success || output.trim()!="codex-cli 0.162.0" { return Ok(None); }
        let cwd=fs::canonicalize(cwd.ok_or_else(||anyhow!("notification profile: missing cwd"))?)?;
        let home=env.iter().rev().find(|(k,_)|k=="CODEX_HOME").map(|(_,v)|PathBuf::from(v))
            .or_else(||std::env::var_os("CODEX_HOME").map(PathBuf::from))
            .unwrap_or_else(||PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".codex"));
        let root=fs::canonicalize(home.join("sessions"))?;
        Ok(Some(Self { id:format!("{PROFILE}:0.162.0:{hash}"), cwd,root,spawned_ms:wall_ms(),session:None,observed:None,invalidated:false,executable:Some(file),pending:HashMap::new() }))
    }

    pub(crate) fn executable_path(&self) -> Option<String> {
        #[cfg(unix)]
        { use std::os::fd::AsRawFd;self.executable.as_ref().map(|f|format!("/proc/{}/fd/{}",std::process::id(),f.as_raw_fd())) }
        #[cfg(not(unix))]
        { None }
    }
    /// Startup may precede creation of the rollout file. Retain only the exact
    /// immutable observation; metadata validation is retried before Prepare.
    pub fn observe(&mut self,session:&str,path:&str,source:&str)->Result<()> {
        if source!="startup" { self.invalidated=true;bail!("native session lifecycle changed"); }
        if self.invalidated { bail!("native profile invalidated"); }
        let path=PathBuf::from(path);
        if !crate::delivery::id(session) || !path.is_absolute() || path.components().any(|c|matches!(c,std::path::Component::ParentDir)) ||
            path.extension().and_then(|s|s.to_str())!=Some("jsonl") || path.as_os_str().len()>4096 {
            // This is an authenticated current-child lifecycle observation.
            // A malformed replacement cannot leave the previous session usable.
            self.invalidated=true;
            bail!("native session observation malformed");
        }
        if let Some((id,original))=&self.observed {
            if id!=session || original!=&path { self.invalidated=true;bail!("native session observation replaced"); }
        } else { self.observed=Some((session.into(),path)); }
        Ok(())
    }
    pub fn ensure_bound(&mut self)->bool {
        if self.invalidated { return false }
        if self.session.is_some() { return true }
        let Some((id,path))=self.observed.clone() else { return false };
        self.bind(&id,path.to_str().unwrap_or("")).is_ok()
    }

    /// Authenticated current-child SessionStart; immutable after the first bind.
    /// Clear/resume/ambiguous state requires a fresh child, never retargeting.
    pub fn bind(&mut self, session: &str, path: &str) -> Result<()> {
        if self.invalidated || !crate::delivery::id(session) || path.len()>4096 { bail!("notification session: malformed"); }
        let path=fs::canonicalize(path)?;
        if !path.starts_with(&self.root) || path.extension().and_then(|e|e.to_str())!=Some("jsonl") {
            bail!("notification session: outside native session root");
        }
        if let Some(current)=&self.session {
            if current.id==session && current.path==path { return Ok(()) }
            bail!("notification session: already bound");
        }
        let snapshot=read_snapshot(&path)?;
        let first=snapshot.rows.first().ok_or_else(||anyhow!("missing native metadata"))?;
        let meta=&first["payload"];
        if first["type"]!="session_meta" || meta["id"]!=session ||
            meta["cwd"].as_str()!=self.cwd.to_str() ||
            meta["cli_version"]!="0.162.0" ||
            meta["timestamp"].as_str().and_then(timestamp_ms).is_none_or(|t|t.saturating_add(1000)<self.spawned_ms || t>wall_ms().saturating_add(1000)) {
            bail!("notification session: native metadata mismatch");
        }
        let header=Sha256::digest(&snapshot.bytes[..snapshot.bytes.iter().position(|b|*b==b'\n').unwrap()+1]).into();
        self.session=Some(Session{id:session.into(),path,identity:snapshot.identity,header});
        Ok(())
    }
    pub fn bound(&self) -> bool { !self.invalidated && self.session.is_some() }

    /// Called immediately before the first physical ESC. Idle is explicitly
    /// unsupported: no ESC/paste is written without an independently active turn.
    pub fn begin(&mut self, delivery: &str) -> Result<()> {
        if self.invalidated { bail!("native profile invalidated"); }
        let session=self.session.as_ref().ok_or_else(||anyhow!("native session unavailable"))?;
        let snapshot=read_snapshot(&session.path)?;
        let header: [u8;32]=Sha256::digest(&snapshot.bytes[..snapshot.bytes.iter().position(|b|*b==b'\n').ok_or_else(||anyhow!("missing native metadata"))?+1]).into();
        if snapshot.identity!=session.identity || header!=session.header { bail!("native session replaced"); }
        let turn=snapshot.active.ok_or_else(||anyhow!("native idle/unknown state unsupported"))?;
        if self.pending.len()>=256 && !self.pending.contains_key(delivery) { bail!("native receipt capacity"); }
        self.pending.insert(delivery.into(),Pending{ turn,offset:snapshot.bytes.len(),prefix:Sha256::digest(&snapshot.bytes).into(),
            started:Instant::now(),sent_ms:None,acknowledged:false });
        Ok(())
    }
    pub fn sent(&mut self, delivery: &str) {
        if let Some(p)=self.pending.get_mut(delivery) { p.sent_ms=Some(wall_ms()); }
    }
    pub fn poll(&mut self, delivery: &str) -> Ack {
        if self.invalidated { return Ack::Uncertain }
        let Some(p)=self.pending.get_mut(delivery) else { return Ack::Uncertain };
        if p.started.elapsed()>=ACK_TIMEOUT { return Ack::Uncertain }
        let Some(sent)=p.sent_ms else { return Ack::Uncertain };
        let Some(session)=&self.session else { return Ack::Uncertain };
        let Ok(snapshot)=read_snapshot(&session.path) else { return Ack::Uncertain };
        if snapshot.identity!=session.identity || snapshot.bytes.len()<p.offset || <[u8;32]>::from(Sha256::digest(&snapshot.bytes[..p.offset]))!=p.prefix { return Ack::Uncertain }
        // Parse only complete rows beyond the immutable pre-ESC boundary.
        let Ok(tail)=std::str::from_utf8(&snapshot.bytes[p.offset..]) else { return Ack::Uncertain };
        let mut ready=false;
        for line in tail.lines() {
            let Ok(row)=serde_json::from_str::<Value>(line) else { return Ack::Uncertain };
            if row["type"]!="event_msg" { continue }
            let body=&row["payload"];
            match body["type"].as_str() {
                Some("task_started") => return Ack::Uncertain,
                Some("task_complete"|"turn_aborted") => {
                    if body["turn_id"]!=p.turn || body["type"]!="turn_aborted" || body["reason"]!="interrupted" ||
                       row["timestamp"].as_str().and_then(timestamp_ms).is_none_or(|t|t<sent) {
                        return Ack::Uncertain;
                    }
                    ready=true;
                }
                _ => {}
            }
        }
        p.acknowledged=ready;
        if ready { Ack::Ready } else { Ack::Waiting }
    }
}

fn read_snapshot(path: &Path) -> Result<Snapshot> {
    // No following a replaced symlink, unbounded history read or partial row.
    if fs::symlink_metadata(path)?.file_type().is_symlink() { bail!("native session replaced"); }
    let file=fs::File::open(path)?;
    #[cfg(unix)]
    let identity={ use std::os::unix::fs::MetadataExt; let m=file.metadata()?; (u128::from(m.dev())<<64)|u128::from(m.ino()) };
    #[cfg(not(unix))]
    let identity=0;
    let mut bytes=Vec::new();
    file.take((MAX_LOG+1) as u64).read_to_end(&mut bytes)?;
    if bytes.len()>MAX_LOG { bail!("native state exceeds bound"); }
    let complete=bytes.iter().rposition(|b|*b==b'\n').map_or(0,|i|i+1);
    bytes.truncate(complete);
    let text=std::str::from_utf8(&bytes)?;
    let mut rows=Vec::new(); let mut active=None; let mut previous=None;
    for line in text.lines() {
        let row:Value=serde_json::from_str(line)?;
        let ordinal=row["ordinal"].as_u64().ok_or_else(||anyhow!("missing native ordinal"))?;
        if previous.is_some_and(|old|ordinal<=old) { bail!("native ordinal regression"); }
        previous=Some(ordinal);
        if row["type"]=="event_msg" {
            let body=&row["payload"];
            match body["type"].as_str() {
                Some("task_started") => { active=Some(body["turn_id"].as_str().filter(|s|crate::delivery::id(s)).ok_or_else(||anyhow!("missing turn"))?.to_owned()); }
                Some("turn_aborted"|"task_complete") => {
                    if active.as_deref()!=body["turn_id"].as_str() { bail!("native terminal turn mismatch"); }
                    active=None;
                }
                _=>{}
            }
        }
        rows.push(row);
    }
    Ok(Snapshot{bytes,rows,active,identity})
}

/// Exact native RFC3339 UTC millisecond timestamps, without permissive locale
/// parsing. Unsupported timestamp layouts fail closed.
fn timestamp_ms(text: &str) -> Option<u64> {
    let b=text.as_bytes();
    if !text.is_ascii() || b.len()!=24 || b[4]!=b'-' || b[7]!=b'-' || b[10]!=b'T' || b[13]!=b':' || b[16]!=b':' || b[19]!=b'.' || b[23]!=b'Z' { return None }
    let n=|a:usize,z:usize| text[a..z].parse::<i64>().ok();
    let mut year=n(0,4)?; let month=n(5,7)?; let day=n(8,10)?;
    let hour=n(11,13)?;let minute=n(14,16)?;let second=n(17,19)?;let ms=n(20,23)?;
    if !(1970..=9999).contains(&year) || !(1..=12).contains(&month) || !(1..=31).contains(&day) || !(0..24).contains(&hour) || !(0..60).contains(&minute) || !(0..60).contains(&second) { return None }
    year-=i64::from(month<=2);
    let era=year/400;let yoe=year-era*400;
    let doy=(153*(month+if month>2 {-3}else{9})+2)/5+day-1;
    let days=era*146097+yoe*365+yoe/4-yoe/100+doy-719468;
    u64::try_from(((days*24+hour)*60+minute)*60000+second*1000+ms).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root()->PathBuf {
        static NEXT:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0);
        let p=std::env::temp_dir().join(format!("ham-native-{}-{}-{}",std::process::id(),wall_ms(),NEXT.fetch_add(1,std::sync::atomic::Ordering::Relaxed)));
        fs::create_dir_all(&p).unwrap();fs::canonicalize(p).unwrap()
    }
    fn make_profile(root:&Path)->NativeProfile {
        NativeProfile{id:PROFILE.into(),cwd:root.into(),root:root.into(),spawned_ms:1794039000000,session:None,observed:None,invalidated:false,executable:None,pending:HashMap::new()}
    }
    fn row(ord:u64,typ:&str,payload:Value)->String {
        serde_json::json!({"ordinal":ord,"timestamp":"2026-11-07T08:11:43.926Z","type":typ,"payload":payload}).to_string()+"\n"
    }
    fn setup(root:&Path)->(NativeProfile,PathBuf) {
        let path=root.join("session.jsonl");
        let meta=serde_json::json!({"id":"session","cwd":root.to_str().unwrap(),"cli_version":"0.162.0","timestamp":"2026-11-07T08:11:38.662Z"});
        fs::write(&path,row(0,"session_meta",meta)+&row(1,"event_msg",serde_json::json!({"type":"task_started","turn_id":"turn"}))).unwrap();
        let mut profile=make_profile(root); profile.bind("session",path.to_str().unwrap()).unwrap();
        (profile,path)
    }
    fn append(path:&Path,text:&str) {
        use std::io::Write;
        fs::OpenOptions::new().append(true).open(path).unwrap().write_all(text.as_bytes()).unwrap();
    }
    #[test]
    fn typed_fresh_same_turn_ack_excludes_echo_and_replay() {
        let root=root();let (mut profile,path)=setup(&root);
        profile.begin("delivery").unwrap();profile.pending.get_mut("delivery").unwrap().sent_ms=Some(1794039103900);
        append(&path,&row(2,"event_msg",serde_json::json!({"type":"user_message","message":"{\"type\":\"turn_aborted\",\"reason\":\"interrupted\",\"turn_id\":\"turn\"}"})));
        append(&path,&row(3,"response_item",serde_json::json!({"type":"turn_aborted","reason":"interrupted","turn_id":"turn"})));
        assert_eq!(profile.poll("delivery"),Ack::Waiting);
        append(&path,&row(4,"event_msg",serde_json::json!({"type":"turn_aborted","reason":"interrupted","turn_id":"turn"})));
        assert_eq!(profile.poll("delivery"),Ack::Ready);
        assert_eq!(profile.poll("delivery"),Ack::Ready);
        assert!(profile.begin("next").is_err(),"idle is explicitly unsupported");
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn stale_wrong_turn_timeout_and_mutated_prefix_fail_closed() {
        for case in 0..4 {
            let root=root();let (mut profile,path)=setup(&root);
            profile.begin("delivery").unwrap();
            profile.pending.get_mut("delivery").unwrap().sent_ms=Some(if case==0 {1794039104000}else{1794039103900});
            if case==2 {profile.pending.get_mut("delivery").unwrap().started=Instant::now()-ACK_TIMEOUT;}
            if case==3 {fs::write(&path,"{}\n").unwrap();}
            else {append(&path,&row(2,"event_msg",serde_json::json!({"type":"turn_aborted","reason":"interrupted","turn_id":if case==1 {"other"} else {"turn"}})));}
            assert_eq!(profile.poll("delivery"),Ack::Uncertain,"case {case}");
            fs::remove_dir_all(root).unwrap();
        }
    }
    #[test]
    fn session_replacement_version_and_old_start_are_rejected() {
        let root=root();let (mut profile,path)=setup(&root);
        assert!(profile.bind("other",path.to_str().unwrap()).is_err());
        let mut newer=make_profile(&root);newer.spawned_ms=1794039200000;
        assert!(newer.bind("session",path.to_str().unwrap()).is_err());
        let text=fs::read_to_string(&path).unwrap().replace("0.162.0","999.0.0");
        fs::write(&path,text).unwrap();
        assert!(make_profile(&root).bind("session",path.to_str().unwrap()).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn startup_observation_is_lazy_and_clear_or_resume_permanently_invalidates() {
        for source in ["clear","resume",""] {
            let root=root();let path=root.join("later.jsonl");let mut p=make_profile(&root);
            p.observe("session",path.to_str().unwrap(),"startup").unwrap();
            assert!(!p.ensure_bound(),"startup can precede native file creation");
            let (existing,original)=setup(&root);drop(existing);
            fs::rename(original,&path).unwrap();
            assert!(p.ensure_bound(),"same original observation resolves once native metadata exists");
            assert!(p.observe("other","",source).is_err());
            assert!(!p.ensure_bound());assert!(p.begin("delivery").is_err());
            assert!(p.observe("session",path.to_str().unwrap(),"startup").is_err());
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn malformed_startup_observation_invalidates_previously_bound_session() {
        for (id,path) in [("replacement",""),("", "/tmp/replacement.jsonl"),
            ("replacement","relative.jsonl"),("replacement","/tmp/not-a-transcript")] {
            let root=root();let (mut p,original)=setup(&root);
            p.observe("session",original.to_str().unwrap(),"startup").unwrap();
            assert!(p.ensure_bound());
            assert!(p.observe(id,path,"startup").is_err());
            assert!(!p.ensure_bound());
            assert!(p.begin("new-delivery").is_err());
            assert!(p.observe("session",original.to_str().unwrap(),"startup").is_err());
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn unknown_native_binary_is_refused_before_version_execution() {
        let root=root();let program=root.join("codex");
        fs::write(&program,b"\x7fELFnot-an-admitted-vendor-release").unwrap();
        let result=NativeProfile::for_spawn(program.to_str().unwrap(),None,&[],Some(PROFILE));
        assert!(matches!(result,Ok(None)),"unknown executable digest must not run a version probe");
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(target_os="linux")]
    #[test]
    fn sealed_descriptor_rejects_mutation_and_survives_original_inode_overwrite() {
        use std::{io::{Seek,SeekFrom,Write},os::fd::AsRawFd};
        let root=root();let original=root.join("original");let moved=root.join("moved");
        fs::write(&original,b"verified original").unwrap();
        let mut file=sealed_executable_snapshot(fs::File::open(&original).unwrap()).unwrap();
        let pinned=format!("/proc/{}/fd/{}",std::process::id(),file.as_raw_fd());
        // Mutate the same inode, then replace the pathname as a separate case.
        fs::write(&original,b"in-place attacker overwrite").unwrap();
        assert_eq!(fs::read(&pinned).unwrap(),b"verified original");
        fs::rename(&original,&moved).unwrap();fs::write(&original,b"unverified replacement").unwrap();
        assert_eq!(fs::read(&pinned).unwrap(),b"verified original");
        file.seek(SeekFrom::Start(0)).unwrap();
        assert!(file.write_all(b"altered").is_err());
        assert!(file.set_len(0).is_err());
        assert!(file.set_len(4096).is_err());
        // Reopening through procfs does not grant a writable alias.
        let mut reopened=fs::OpenOptions::new().write(true).open(&pinned).unwrap();
        assert!(reopened.write_all(b"altered").is_err());
        assert!(unsafe { libc::fcntl(file.as_raw_fd(),libc::F_ADD_SEALS,0) }<0);
        assert_eq!(fs::read(&pinned).unwrap(),b"verified original");
        drop(reopened);drop(file);fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn native_utc_timestamp_is_exact_and_bounded() {
        assert_eq!(timestamp_ms("1970-01-01T00:00:00.000Z"),Some(0));
        assert_eq!(timestamp_ms("2026-11-07T08:11:43.926Z"),Some(1794039103926));
        assert_eq!(timestamp_ms("2026-11-07T08:11:43Z"),None);
        assert_eq!(timestamp_ms("2026-11-07T24:11:43.926Z"),None);
    }
}
