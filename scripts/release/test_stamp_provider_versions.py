"""Keep release catalog hashes aligned with the Hub's canonical wire body.

Run with: python3 -I scripts/release/test_stamp_provider_versions.py
"""
from contextlib import closing
import importlib.util
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "stamp_provider_versions", ROOT / "scripts/release/stamp-provider-versions.py")
STAMP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAMP)


class CatalogHashParityTest(unittest.TestCase):
    def test_migration_218_matches_odin_canonical_hash(self):
        directory = ROOT / "src/hub/repository/sqlite/migrations"
        order = STAMP.ORDER.search((directory.parent / "migrations.odin").read_text())
        self.assertIsNotNone(order)
        names = re.findall(r'"([^"]+\.sql)"', order[4])
        # Freeze the snapshot so later release migrations do not change this
        # regression. The independent Odin ACP install test derives this value
        # from provider_service.catalog_etag after upgrading v0.5.58 through 218.
        names = names[:names.index("218_acp_adapter_install.sql") + 1]
        canonical = "sha256:a704ff6a13004d6abb9c04a7ad54512c9cf5aa7a5bc27e5487c2e6b25a59cef1"
        with closing(STAMP.catalog_database(directory, names)) as db:
            self.assertEqual(STAMP.catalog_etag(db), canonical)
            self.assertEqual(db.execute(
                "SELECT catalog_etag FROM provider_catalog_meta").fetchone()[0], canonical)


if __name__ == "__main__":
    unittest.main()
