import base64
import hashlib
import importlib.util
import io
import pathlib
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("prepare", pathlib.Path(__file__).with_name("prepare_darwin_native_package.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PackageSafety(unittest.TestCase):
    def package(self, root, entries):
        path = root / "source.tgz"
        with tarfile.open(path, "w:gz") as tar:
            for name, body, kind in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.size = len(body) if kind == tarfile.REGTYPE else 0
                member.linkname = "/tmp/never-extract"
                tar.addfile(member, io.BytesIO(body))
        integrity = "sha512-" + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()
        return path, dict(integrity=integrity, member="package/native", native_sha256=hashlib.sha256(b"image").hexdigest())

    def test_only_exact_regular_native_member_is_extracted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            archive, pin = self.package(root, [("../../escape", b"unrelated", tarfile.REGTYPE), ("package/native", b"image", tarfile.REGTYPE)])
            out = root / "codex"
            prepare.extract_image(archive, out, pin)
            self.assertEqual(out.read_bytes(), b"image")
            self.assertEqual(sorted(p.name for p in root.iterdir()), ["codex", "source.tgz"])

    def test_tampered_archive_wrong_image_duplicate_and_symlink_refuse(self):
        for entries in ([('package/native', b'other', tarfile.REGTYPE)],
                        [('package/native', b'image', tarfile.SYMTYPE)],
                        [('package/native', b'image', tarfile.REGTYPE)] * 2):
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                archive, pin = self.package(root, entries)
                with self.assertRaises(ValueError):
                    prepare.extract_image(archive, root / "codex", pin)
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            archive, pin = self.package(root, [('package/native', b'image', tarfile.REGTYPE)])
            archive.write_bytes(archive.read_bytes() + b'tampered')
            with self.assertRaisesRegex(ValueError, 'integrity'):
                prepare.extract_image(archive, root / 'codex', pin)
            self.assertFalse((root / 'codex').exists())

    def test_global_or_existing_output_is_not_preparation_scope(self):
        for path in ('/nix/store/new-codex', '/usr/local/bin/codex', str(pathlib.Path.home())):
            with self.subTest(path=path), self.assertRaises(ValueError):
                prepare.private_output(path)


if __name__ == '__main__':
    unittest.main()
