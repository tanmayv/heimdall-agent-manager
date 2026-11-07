#!/usr/bin/env python3
"""Review-only root transaction. --plan is safe; --apply ALWAYS refuses.

The proposed transaction is deliberately unreachable from the CLI. Removing the
guard requires a separately reviewed successor, native validation, and explicit
user authorization. No environment variable or manifest field overrides it.
Only the raw native member is an input; no archive extraction runs as root.
"""
import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import tempfile

BASE = Path("/Library/HeimdallProtectedNative")
SHA = "fd4bb93679bfcc546765a3363a0df9a855f364b61ea6681009b28ba4c2e5b60d"
VERSION = "codex-0.162.0-darwin-x64-" + SHA
MAX_IMAGE = 512 * 1024 * 1024


def sha256_file(image):
    digest = hashlib.sha256()
    total = 0
    for chunk in iter(lambda: image.read(65536), b""):
        total += len(chunk)
        if total > MAX_IMAGE:
            raise ValueError("image grew beyond bound")
        digest.update(chunk)
    return digest.hexdigest()


def identity(m):
    return (m.st_dev, m.st_ino, m.st_size, m.st_uid, m.st_gid,
            m.st_mode, m.st_nlink, m.st_mtime_ns, m.st_ctime_ns)


def open_input(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        m = os.fstat(fd)
        if not stat.S_ISREG(m.st_mode) or not 4 <= m.st_size <= MAX_IMAGE:
            raise ValueError("input must be a bounded regular native image")
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def copy_verified(source, destination, expected=SHA):
    """Fresh inode, no source metadata/xattrs/ACLs, bounded bytes, no execution.

    Caller must own a fresh inaccessible destination directory. A writer to the
    input cannot acquire a descriptor to the independent destination inode.
    """
    with open_input(source) as reader:
        before = identity(os.fstat(reader.fileno()))
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(fd, "wb") as writer:
            total = 0
            digest = hashlib.sha256()
            while True:
                chunk = reader.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_IMAGE:
                    raise ValueError("input grew beyond bound")
                writer.write(chunk)
                digest.update(chunk)
            if total != before[2] or identity(os.fstat(reader.fileno())) != before:
                raise ValueError("input changed during copy")
            if digest.hexdigest() != expected:
                raise ValueError("native digest mismatch")
            writer.flush()
            os.fsync(writer.fileno())
    # Independently hash newly created bytes, rather than trusting source stat.
    with open_input(destination) as image:
        if image.read(4) != b"\xcf\xfa\xed\xfe":
            raise ValueError("expected thin little-endian Mach-O64")
        image.seek(0)
        if sha256_file(image) != expected:
            raise ValueError("destination digest mismatch")


def no_acl(path):
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    lib.acl_get_file.argtypes = [ctypes.c_char_p, ctypes.c_int]
    lib.acl_get_file.restype = ctypes.c_void_p
    lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                  ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_free.argtypes = [ctypes.c_void_p]
    acl = lib.acl_get_file(os.fsencode(path), 0x100)  # ACL_TYPE_EXTENDED
    if not acl:
        if ctypes.get_errno() == errno.ENOENT and path.exists():
            return
        raise ValueError("ACL unavailable: " + str(path))
    try:
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        result = lib.acl_get_entry(acl, 0, ctypes.byref(entry))
        if result == 0 or ctypes.get_errno() != errno.ENOENT:
            raise ValueError("explicit/uninterpreted ACL: " + str(path))
    finally:
        lib.acl_free(acl)


def protected_chain(path):
    for item in (path, *path.parents):
        m = item.lstat()
        if not stat.S_ISDIR(m.st_mode) or m.st_uid != 0 or m.st_mode & 0o022:
            raise ValueError("unprotected ancestor: " + str(item))
        if getattr(m, "st_flags", -1) & ~0x00100000:
            raise ValueError("unreviewed ancestor flags: " + str(item))
        no_acl(item)
        local_apfs(item)


def local_apfs(path):
    # Darwin LP64 statfs, xnu-12377.1.9 bsd/sys/mount.h:104-122.
    class Statfs(ctypes.Structure):
        _fields_ = [("bsize", ctypes.c_uint32), ("iosize", ctypes.c_int32),
                    ("counts", ctypes.c_uint64 * 5), ("fsid", ctypes.c_int32 * 2),
                    ("owner", ctypes.c_uint32), ("type", ctypes.c_uint32),
                    ("flags", ctypes.c_uint32), ("subtype", ctypes.c_uint32),
                    ("kind", ctypes.c_char * 16), ("mount", ctypes.c_char * 1024),
                    ("source", ctypes.c_char * 1024), ("ext", ctypes.c_uint32),
                    ("reserved", ctypes.c_uint32 * 7)]
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    lib.statfs.argtypes = [ctypes.c_char_p, ctypes.POINTER(Statfs)]
    mount = Statfs()
    if lib.statfs(os.fsencode(path), ctypes.byref(mount)) != 0:
        raise OSError(ctypes.get_errno(), "statfs")
    if (mount.kind != b"apfs" or not mount.flags & 0x1000 or mount.owner != 0
            or mount.flags & (0x00200000 | 0x200 | 0x20 | 0x4)):
        # No ignore-ownership, removable, union, or noexec filesystem.
        raise ValueError("requires local APFS")
    return (bytes(mount.fsid), bytes(mount.mount), bytes(mount.source))


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def exact_directory(path, mode):
    m = path.lstat()
    if (not stat.S_ISDIR(m.st_mode) or m.st_uid != 0 or m.st_gid != 0
            or stat.S_IMODE(m.st_mode) != mode or getattr(m, "st_flags", -1) != 0):
        raise ValueError("unexpected managed directory: " + str(path))


def proposed_install(source):
    """UNEXECUTED proposal; no caller from main. No repair/delete/enable path.

    Assumes the separately approved root transaction runs from root-only tools
    and a trusted interpreter with isolated imports; see the runbook. All root
    administrators must obey the append-only contract, including backups/MDM.
    """
    if platform.system() != "Darwin" or platform.machine() != "x86_64" or os.geteuid() != 0:
        raise ValueError("root on native x86_64 Darwin required")
    os.umask(0o077)
    protected_chain(BASE.parent)
    mount = local_apfs(BASE.parent)
    # Bootstrap mkdir is exclusive: an existing base is inspected, never fixed.
    try:
        BASE.mkdir(mode=0o755)
        os.chown(BASE, 0, 0)
        os.chmod(BASE, 0o755)
    except FileExistsError:
        pass
    protected_chain(BASE)
    exact_directory(BASE, 0o755)
    if local_apfs(BASE) != mount:
        raise ValueError("unexpected mount boundary")
    lockfd = os.open(BASE / ".admin.lock", os.O_RDWR | os.O_CREAT |
                     os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
    try:
        lock = os.fstat(lockfd)
        if (not stat.S_ISREG(lock.st_mode) or lock.st_uid != 0 or lock.st_gid != 0
                or stat.S_IMODE(lock.st_mode) != 0o600 or lock.st_nlink != 1):
            raise ValueError("untrusted lock")
        if getattr(lock, "st_flags", -1) != 0:
            raise ValueError("unexpected lock flags")
        no_acl(BASE / ".admin.lock")
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        versions = BASE / "versions"
        if not versions.exists():
            versions.mkdir(mode=0o755)
            os.chown(versions, 0, 0)
            os.chmod(versions, 0o755)
        protected_chain(versions)
        exact_directory(versions, 0o755)
        if local_apfs(versions) != mount:
            raise ValueError("unexpected versions mount")
        final = versions / VERSION
        if os.path.lexists(final):
            raise ValueError("version already exists; never overwrite or repair")
        stage = Path(tempfile.mkdtemp(prefix=".stage-", dir=versions))
        os.chown(stage, 0, 0)
        exact_directory(stage, 0o700)
        # On any failure retain root-only stage for separately approved cleanup.
        # Never recursively delete paths in an error handler.
        image = stage / "codex"
        copy_verified(source, image)
        os.chown(image, 0, 0)
        os.chmod(image, 0o555)
        no_acl(image)
        m = image.lstat()
        if m.st_nlink != 1 or getattr(m, "st_flags", -1) != 0:
            raise ValueError("unexpected links/flags")
        manifest = dict(schema=1, sha256=SHA, version=VERSION,
                        policy="root-created-append-only-retain-v1",
                        production_admissible=False, enabled=False,
                        closure_proven=False)
        with (stage / "install.json").open("x") as output:
            json.dump(manifest, output, sort_keys=True, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(stage / "install.json", 0o444)
        os.chown(stage / "install.json", 0, 0)
        no_acl(stage / "install.json")
        os.chmod(stage, 0o555)
        protected_chain(stage)
        if local_apfs(stage) != mount:
            raise ValueError("unexpected stage mount")
        fsync_dir(stage)
        # Administrators serialize on the persistent lock. No other TCB writer
        # may create this final name. Runtime never creates any name here.
        os.rename(stage, final)
        fsync_dir(versions)
        fsync_dir(BASE)
        print(str(final / "codex"))
    finally:
        os.close(lockfd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true")
    group.add_argument("--verify-input", metavar="RAW_IMAGE")
    group.add_argument("--apply", metavar="RAW_IMAGE")
    args = parser.parse_args()
    if args.apply:
        parser.exit(78, "REFUSED: review-only proposal; no privileged deployment authorized\n")
    if args.verify_input:
        with open_input(args.verify_input) as image:
            if sha256_file(image) != SHA:
                parser.exit(1, "native digest mismatch\n")
        print("Pinned input digest matches; no protection/closure/admission claim")
    else:
        print(json.dumps(dict(base=str(BASE), version=VERSION,
                              image=str(BASE / "versions" / VERSION / "codex"),
                              sha256=SHA, apply_available=False,
                              closure_proven=False, enabled=False), indent=2))


if __name__ == "__main__":
    main()
