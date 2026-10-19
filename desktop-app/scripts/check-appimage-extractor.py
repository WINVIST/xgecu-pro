"""Exercise both pinned RAR/SFX layers using only the AppImage extractor."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

appdir = Path("squashfs-root").resolve()
extractor = appdir / "usr/bin/bsdtar"
libraries = appdir / "usr/lib/xgecu-extract"
assert extractor.is_file()
assert any((appdir / "usr/share/doc/xgecu-pro/extractor-notices").glob("*.txt"))
archive = Path.home() / ".cache/minipro/xgpro_vendor.rar"
assert archive.is_file(), "The helper's fresh-cache test must provision the pinned archive"
vendor = Path("../minipro-rs/crates/minipro-db/src/vendor.rs").read_text()
expected = re.search(r'const DEFAULT_VENDOR_SHA256: &str =\s*"([a-f0-9]{64})"', vendor).group(1)
with archive.open("rb") as handle:
    digest = hashlib.file_digest(handle, "sha256").hexdigest() if hasattr(hashlib,"file_digest") else None
if digest is None:
    h = hashlib.sha256()
    with archive.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            h.update(chunk)
    digest = h.hexdigest()
assert digest == expected
environment = {**os.environ, "PATH": "/xgecu-test-no-host-tools", "LD_LIBRARY_PATH": str(libraries)}
with tempfile.TemporaryDirectory(prefix="xgecu-appimage-extract-") as temporary:
    outer = Path(temporary) / "outer"
    inner = Path(temporary) / "inner"
    outer.mkdir()
    inner.mkdir()
    subprocess.run([str(extractor), "-xf", str(archive), "-C", str(outer)], env=environment, check=True)
    installers = list(outer.rglob("*.exe"))
    assert len(installers) == 1, "Expected one vendor SFX installer; never execute it"
    subprocess.run([str(extractor), "-xf", str(installers[0]), "-C", str(inner), "InfoICT76.dll", "algoT76"], env=environment, check=True)
    assert (inner / "InfoICT76.dll").stat().st_size > 0
    assert any(p.stat().st_size > 0 for p in (inner / "algoT76").rglob("*.alg"))
print("AppImage extractor verified for both pinned archive layers without host tools")
