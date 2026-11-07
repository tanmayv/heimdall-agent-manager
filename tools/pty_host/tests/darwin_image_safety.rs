#![cfg(target_os = "macos")]
//! Actual Mach-O/PTY controls, never a provider or immutable-backend pass.
use ham_pty_host::{darwin_image::Candidate, PtyHost, SpawnConfig};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    process::Command,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn hash(path: &Path) -> String {
    let mut h = Sha256::new();
    let mut file = File::open(path).unwrap();
    let mut b = [0; 65536];
    loop {
        let n = file.read(&mut b).unwrap();
        if n == 0 {
            break;
        }
        h.update(&b[..n]);
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
fn config(path: &Path, root: &Path) -> SpawnConfig {
    let mut c = SpawnConfig::new(
        path.to_string_lossy(),
        vec!["argument with spaces".into(), "日本語".into()],
    );
    c.cwd = Some(root.to_string_lossy().into());
    c.login_shell = false;
    c.extra_env
        .push(("GUARD_PROBE".into(), "private-nonsecret".into()));
    c
}
fn run_control(path: &Path, root: &Path) -> String {
    let mut host = PtyHost::spawn(config(path, root)).expect("real PTY control required");
    let rx = host.take_output_rx().unwrap();
    if host.wait_timeout(Duration::from_secs(5)).is_none() {
        host.kill();
        let _ = host.wait();
        panic!("private control timed out");
    }
    let mut output = Vec::new();
    while let Ok(bytes) = rx.recv_timeout(Duration::from_millis(250)) {
        output.extend(bytes);
    }
    assert_eq!(host.wait(), 0);
    host.release_pty();
    String::from_utf8(output).unwrap()
}

#[test]
fn native_macho_rename_and_preheld_writer_refuse_guarded_pty() {
    let root = std::env::temp_dir().join(format!(
        "ham-darwin-pty-proof-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&root).unwrap();
    let root = fs::canonicalize(root).unwrap();
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    let _cleanup = Cleanup(root.clone());
    let a = root.join("A");
    let b = root.join("B");
    let source = root.join("probe.c");
    fs::write(&source,concat!("#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\n#include <sys/ioctl.h>\n",
        "int main(int n,char **v){char cwd[4096];struct winsize w={0};ioctl(0,TIOCGWINSZ,&w);puts(PROBE);",
        "if(n==3)printf(\"%s|%s\\n\",v[1],v[2]);printf(\"TTY=%d%d%d FG=%d SIZE=%dx%d\\n\",isatty(0),isatty(1),isatty(2),tcgetpgrp(0)==getpgrp(),w.ws_row,w.ws_col);",
        "printf(\"CWD=%s ENV=%s\\n\",getcwd(cwd,sizeof(cwd)),getenv(\"GUARD_PROBE\"));return 0;}\n")).unwrap();
    for (out, label) in [(&a, "IMAGE_A"), (&b, "IMAGE_B")] {
        assert!(Command::new("/usr/bin/clang")
            .arg(&source)
            .arg(format!("-DPROBE=\"{label}\""))
            .arg("-o")
            .arg(out)
            .status()
            .unwrap()
            .success());
    }
    let active = root.join("codex");
    fs::copy(&a, &active).unwrap();
    let digest = hash(&active);
    let candidate = Candidate::inspect(&active, &digest).unwrap();
    assert!(candidate.revalidate().is_ok());
    assert!(
        ham_pty_host::native_notification::NativeProfile::for_spawn(
            active.to_str().unwrap(),
            Some(root.to_str().unwrap()),
            &[],
            Some(ham_pty_host::native_notification::PROFILE)
        )
        .unwrap()
        .is_none(),
        "production native profile remains disabled"
    );
    let refused = PtyHost::spawn_darwin_candidate(config(&active, &root), &candidate);
    assert!(
        refused.is_err(),
        "user image must not execute via guarded PTY"
    );
    fs::rename(&b, &active).unwrap();
    assert!(candidate.revalidate().is_err());
    assert!(PtyHost::spawn_darwin_candidate(config(&active, &root), &candidate).is_err());
    let control = run_control(&active, &root);
    assert!(control.contains("IMAGE_B") && !control.contains("IMAGE_A"));
    assert!(control.contains("argument with spaces|日本語"));
    assert!(control.contains("TTY=111 FG=1 SIZE=24x80"));
    assert!(control.contains(&format!("CWD={} ENV=private-nonsecret", root.display())));

    fs::copy(&a, &active).unwrap();
    // The writer predates admission and still refers to the same inode. Keep
    // mutation entirely within this disposable image; never an installed file.
    let mut writer = OpenOptions::new().write(true).open(&active).unwrap();
    let candidate = Candidate::inspect(&active, &hash(&active)).unwrap();
    let mut replacement = fs::read(&a).unwrap();
    let at = replacement
        .windows(7)
        .position(|w| w == b"IMAGE_A")
        .unwrap();
    replacement[at + 6] = b'B';
    writer.seek(SeekFrom::Start(0)).unwrap();
    writer.write_all(&replacement).unwrap();
    writer.sync_all().unwrap();
    assert!(candidate.revalidate().is_err());
    assert!(PtyHost::spawn_darwin_candidate(config(&active, &root), &candidate).is_err());
    // Re-signing changed Mach-O bytes is intentionally unnecessary: refusal
    // happens before exec, including when the OS would later reject a signature.
    println!("darwin_guard: actual Mach-O rename control=B; preheld-writer same-inode change detected; guarded PTY refused both; no native capability enabled");
}

#[test]
fn staged_pinned_vendor_image_is_inspection_not_execution_authority() {
    let Some(path) = std::env::var_os("HEIMDALL_DARWIN_STAGED_IMAGE") else {
        assert_ne!(
            std::env::var("HEIMDALL_DARWIN_PACKAGE_REQUIRED").as_deref(),
            Ok("1"),
            "required private staged image missing"
        );
        eprintln!("[skip] pinned private package requires HEIMDALL_DARWIN_STAGED_IMAGE");
        return;
    };
    let path = std::path::PathBuf::from(path);
    assert_ne!(
        std::os::unix::fs::MetadataExt::uid(&path.metadata().unwrap()),
        0,
        "only this task's private user-owned staging is eligible for this negative probe"
    );
    let candidate =
        Candidate::inspect(&path, ham_pty_host::darwin_image::MAC_CODEX_SHA256).unwrap();
    assert!(candidate.revalidate().is_ok());
    assert!(candidate
        .authorize_activation()
        .unwrap_err()
        .to_string()
        .contains("unprotected_image"));
    assert!(ham_pty_host::native_notification::NativeProfile::for_spawn(
        path.to_str().unwrap(),
        None,
        &[],
        Some(ham_pty_host::native_notification::PROFILE)
    )
    .unwrap()
    .is_none());
    println!("darwin_guard: pinned native0.162 bytes verified; user-owned private stage refused; vendor not executed");
}
