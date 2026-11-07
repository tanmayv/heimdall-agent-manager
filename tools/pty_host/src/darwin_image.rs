//! Inspection substrate for a future protected-canonical Darwin image backend.
//!
//! A held inode and matching digest do not freeze bytes. There is deliberately
//! no constructor for an accepted lifetime-policy proof yet: even a root-owned
//! candidate cannot be activated by this module. Inspection is not authority.

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Component, Path, PathBuf},
};

pub const MAC_CODEX_SHA256: &str =
    "fd4bb93679bfcc546765a3363a0df9a855f364b61ea6681009b28ba4c2e5b60d";
const MAX_IMAGE: u64 = 512 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Identity {
    dev: u64,
    ino: u64,
    size: u64,
    uid: u32,
    gid: u32,
    mode: u32,
    links: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl Identity {
    fn read(m: &fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            size: m.len(),
            uid: m.uid(),
            gid: m.gid(),
            mode: m.mode(),
            links: m.nlink(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        }
    }
}

/// Owned descriptor and observations, never an immutable executable claim.
pub struct Candidate {
    path: PathBuf,
    file: File,
    identity: Identity,
    digest: String,
    ancestors: Vec<(PathBuf, Identity)>,
}

fn no_links(path: &Path) -> Result<Vec<(PathBuf, Identity)>> {
    if !path.is_absolute()
        || path
            .components()
            .any(|c| !matches!(c, Component::RootDir | Component::Normal(_)))
    {
        bail!("darwin_image: noncanonical_path");
    }
    let mut ancestors = Vec::new();
    for parent in path.ancestors().skip(1) {
        let m = fs::symlink_metadata(parent).context("darwin_image: ancestor_unavailable")?;
        if !m.is_dir() || m.file_type().is_symlink() {
            bail!("darwin_image: symlink_or_nondirectory_ancestor");
        }
        ancestors.push((parent.to_owned(), Identity::read(&m)));
    }
    Ok(ancestors)
}

fn digest(file: &File) -> Result<String> {
    let before = Identity::read(&file.metadata()?);
    if before.size > MAX_IMAGE {
        bail!("darwin_image: oversized_image");
    }
    let mut reader = file.try_clone()?;
    reader.seek(SeekFrom::Start(0))?;
    let mut hash = Sha256::new();
    let mut bytes = 0u64;
    let mut buffer = [0; 65536];
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        bytes += n as u64;
        if bytes > MAX_IMAGE {
            bail!("darwin_image: growing_image");
        }
        hash.update(&buffer[..n]);
    }
    if bytes != before.size || before != Identity::read(&file.metadata()?) {
        bail!("darwin_image: changed_during_hash");
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

impl Candidate {
    /// Bounded, no-follow inspection. The digest must be the actual native
    /// image, not a launcher that executes another pathname later.
    pub fn inspect(path: &Path, expected_sha256: &str) -> Result<Self> {
        if expected_sha256.len() != 64
            || !expected_sha256
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            bail!("darwin_image: invalid_digest");
        }
        let ancestors = no_links(path)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)?;
        let m = file.metadata()?;
        if !m.is_file() || m.len() < 4 || m.len() > MAX_IMAGE {
            bail!("darwin_image: invalid_image");
        }
        let mut header = [0; 4];
        (&file).read_exact(&mut header)?;
        if ![
            b"\xcf\xfa\xed\xfe",
            b"\xfe\xed\xfa\xcf",
            b"\xca\xfe\xba\xbe",
        ]
        .contains(&&header)
        {
            bail!("darwin_image: not_macho");
        }
        let actual = digest(&file)?;
        if actual != expected_sha256 {
            bail!("darwin_image: digest_mismatch");
        }
        let candidate = Self {
            path: path.to_owned(),
            identity: Identity::read(&file.metadata()?),
            file,
            digest: actual,
            ancestors,
        };
        candidate.revalidate()?;
        Ok(candidate)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Detect replacement and same-inode overwrite, including a writer opened
    /// before inspection. Successful revalidation still does not seal the file.
    pub fn revalidate(&self) -> Result<()> {
        let named = fs::symlink_metadata(&self.path)?;
        if !named.is_file()
            || named.file_type().is_symlink()
            || Identity::read(&named) != self.identity
            || Identity::read(&self.file.metadata()?) != self.identity
            || digest(&self.file)? != self.digest
        {
            bail!("darwin_image: image_changed");
        }
        let current = no_links(&self.path)?;
        if current != self.ancestors {
            bail!("darwin_image: ancestor_changed");
        }
        Ok(())
    }

    /// No runtime flag, manifest, root UID or caller assertion can supply the
    /// missing daemon/updater/delete/GC/lifetime proof. Production stays off.
    pub fn authorize_activation(&self) -> Result<()> {
        self.revalidate()?;
        if self.identity.uid != 0
            || self.identity.mode & 0o222 != 0
            || self.identity.mode & 0o111 == 0
            || self.identity.links != 1
        {
            bail!("darwin_image: unprotected_image");
        }
        for (_, m) in &self.ancestors {
            if m.uid != 0 || m.mode & 0o022 != 0 {
                bail!("darwin_image: writable_or_untrusted_ancestor");
            }
        }
        platform_protections(&self.file, &self.path, &self.ancestors)?;
        self.revalidate()?;
        bail!("darwin_image: lifetime_policy_unproven")
    }
}

#[cfg(not(target_os = "macos"))]
fn platform_protections(_: &File, _: &Path, _: &[(PathBuf, Identity)]) -> Result<()> {
    bail!("darwin_image: native_platform_required")
}

#[cfg(target_os = "macos")]
fn no_extended_acl(path: &Path) -> Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    unsafe extern "C" {
        fn acl_get_file(path: *const libc::c_char, kind: libc::c_int) -> *mut libc::c_void;
        fn acl_get_entry(
            acl: *mut libc::c_void,
            entry: libc::c_int,
            out: *mut *mut libc::c_void,
        ) -> libc::c_int;
        fn acl_free(acl: *mut libc::c_void) -> libc::c_int;
    }
    let name = CString::new(path.as_os_str().as_bytes())?;
    let acl = unsafe { acl_get_file(name.as_ptr(), 0x100) };
    if acl.is_null() {
        if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)
            && fs::symlink_metadata(path).is_ok()
        {
            return Ok(()); // Darwin reports absence of an extended ACL.
        }
        bail!("darwin_image: acl_unavailable");
    }
    let mut entry = std::ptr::null_mut();
    let result = unsafe { acl_get_entry(acl, 0, &mut entry) };
    let error = std::io::Error::last_os_error();
    unsafe {
        acl_free(acl);
    }
    // Even deny-only ACLs require a reviewed interpretation; do not infer
    // effective protection by discarding entries we do not understand.
    if result == 0 {
        bail!("darwin_image: acl_policy_unproven");
    }
    if error.raw_os_error() != Some(libc::ENOENT) {
        bail!("darwin_image: acl_unavailable");
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn platform_protections(file: &File, path: &Path, ancestors: &[(PathBuf, Identity)]) -> Result<()> {
    use std::os::fd::AsRawFd;
    for item in std::iter::once(path).chain(ancestors.iter().map(|(p, _)| p.as_path())) {
        no_extended_acl(item)?;
    }
    let mut mount = std::mem::MaybeUninit::<libc::statfs>::uninit();
    if unsafe { libc::fstatfs(file.as_raw_fd(), mount.as_mut_ptr()) } != 0 {
        bail!("darwin_image: mount_unavailable");
    }
    let mount = unsafe { mount.assume_init() };
    let kind = unsafe { std::ffi::CStr::from_ptr(mount.f_fstypename.as_ptr()) };
    if mount.f_flags & (libc::MNT_LOCAL as u32) == 0 || kind.to_bytes() != b"apfs" {
        bail!("darwin_image: mount_policy_unproven");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::Write,
        os::unix::fs::{symlink, PermissionsExt},
    };
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn fixture() -> (PathBuf, Cleanup) {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "ham-darwin-candidate-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let root = fs::canonicalize(root).unwrap();
        let cleanup = Cleanup(root.clone());
        (root, cleanup)
    }
    fn image(path: &Path, tail: u8) -> String {
        fs::write(path, [0xcf, 0xfa, 0xed, 0xfe, tail]).unwrap();
        digest(&File::open(path).unwrap()).unwrap()
    }
    #[test]
    fn descriptor_and_digest_do_not_authorize_user_image() {
        let (root, _cleanup) = fixture();
        let path = root.join("codex");
        let hash = image(&path, 1);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o555)).unwrap();
        let candidate = Candidate::inspect(&path, &hash).unwrap();
        assert!(candidate.revalidate().is_ok());
        assert!(candidate.authorize_activation().is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn path_replacement_and_preheld_writer_never_relabel_admission() {
        let (root, _cleanup) = fixture();
        let path = root.join("codex");
        let hash = image(&path, 1);
        let mut writer = OpenOptions::new().write(true).open(&path).unwrap();
        let candidate = Candidate::inspect(&path, &hash).unwrap();
        writer.seek(SeekFrom::Start(4)).unwrap();
        writer.write_all(&[2]).unwrap();
        writer.sync_all().unwrap();
        assert!(candidate.revalidate().is_err());
        assert!(candidate.authorize_activation().is_err());
        let hash = image(&path, 1);
        let candidate = Candidate::inspect(&path, &hash).unwrap();
        let other = root.join("other");
        image(&other, 2);
        fs::rename(other, &path).unwrap();
        assert!(candidate.revalidate().is_err());
        assert!(candidate.authorize_activation().is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn links_noncanonical_paths_and_digest_substitution_refuse() {
        let (root, _cleanup) = fixture();
        let path = root.join("codex");
        let hash = image(&path, 1);
        let link = root.join("link");
        symlink(&path, &link).unwrap();
        assert!(Candidate::inspect(&link, &hash).is_err());
        assert!(Candidate::inspect(&root.join("../codex"), &hash).is_err());
        assert!(Candidate::inspect(&path, &"0".repeat(64)).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_acl_absence_and_explicit_grant_are_not_confused() {
        let (root, _cleanup) = fixture();
        let path = root.join("codex");
        image(&path, 1);
        assert!(no_extended_acl(&path).is_ok());
        let identity = std::process::Command::new("/usr/bin/id")
            .arg("-un")
            .output()
            .unwrap();
        assert!(identity.status.success());
        let name = std::str::from_utf8(&identity.stdout).unwrap().trim();
        assert!(!name.is_empty());
        let grant = format!("user:{name} allow read,write");
        assert!(std::process::Command::new("/bin/chmod")
            .args(["+a", &grant])
            .arg(&path)
            .status()
            .unwrap()
            .success());
        assert!(no_extended_acl(&path)
            .unwrap_err()
            .to_string()
            .contains("acl_policy_unproven"));
        fs::remove_dir_all(root).unwrap();
    }
}
