"""Exercise both pinned RAR/SFX layers using only the AppImage extractor."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

appdir = Path(sys.argv[1] if len(sys.argv) > 1 else "squashfs-root").resolve()
extractor = appdir / "usr/bin/bsdtar"
libraries = appdir / "usr/lib/xgecu-extract"
assert extractor.is_file()
assert any((appdir / "usr/share/doc/xgecu-pro/extractor-notices").glob("*.txt"))
vendor = Path("../minipro-rs/crates/minipro-db/src/vendor.rs").read_text()
expected = re.search(r'const DEFAULT_VENDOR_SHA256: &str =\s*"([a-f0-9]{64})"', vendor).group(1)
source = re.search(r'pub const DEFAULT_VENDOR_ARCHIVE: &str =\s*"(https://[^"]+)"', vendor).group(1)
environment = {**os.environ, "PATH": "/xgecu-test-no-host-tools", "LD_LIBRARY_PATH": str(libraries)}
with tempfile.TemporaryDirectory(prefix="xgecu-appimage-extract-") as temporary:
    # The helper deliberately removes its archive after preparing the cache.
    # Fetch a separate digest-checked test copy; never publish vendor data.
    archive = Path(temporary) / "vendor.rar"
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(source, timeout=60) as response, archive.open("wb") as output:
        for chunk in iter(lambda: response.read(65536), b""):
            size += len(chunk)
            assert size <= 96 * 1024 * 1024
            digest.update(chunk)
            output.write(chunk)
    assert size >= 1024 * 1024 and digest.hexdigest() == expected
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
