# Optional Intel macOS release

The **Release local binaries** workflow builds Linux x64, Linux ARM64,
Apple Silicon macOS and Windows x64 by default. Intel macOS (`darwin-amd64`)
is disabled by default, including for tag pushes.

To include Intel macOS, run the workflow manually and enable **Build and publish
Intel macOS (Darwin x64) binaries** (`build_darwin_x64`). This selects its build
and storeless verification jobs and includes its tarball in the release notes
and `SHA256SUMS`, together with its desktop DMG/zip/pkg and macOS updater
metadata. Default releases advertise only Apple Silicon in `latest-mac.yml`.
The other manual publishing options still apply.

Promotion supports releases with or without Intel macOS. If its tarball or
checksum entry is present, both must be present. Installer support for existing
Intel macOS releases is unchanged.

Local workflow regression checks:

```bash
python3 tests/test_release_targets.py
```
