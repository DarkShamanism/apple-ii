"""Hash-pinned, project-local Z80 tools. Never installs into system Python."""
import hashlib
from pathlib import Path
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build' / (ROOT / 'VERSION').read_text().strip()
PACKAGES = {
    'pyserial': ('pyserial-3.5-py2.py3-none-any.whl', '07/bc/587a445451b253b285629263eb51c2d8e9bcea4fc97826266d186f96f558', 'c4451db6ba391ca6ca299fb3ec7bae67a5c55dde170964c7a14ceefec02f2cf0'),
    'pyz80': ('pyz80-1.3.0-py3-none-any.whl', 'd5/c6/439a84a9a241df9895e19cd66bdcdca49f1d75af692aa16ddf96a4f14afa', '1e52fac500e948b58f2b58babc79f29e73d2eca9cedf4f8b021db0f1e08e7aeb'),
    'z80': ('z80-1.2.0-cp312-cp312-win_amd64.whl', '17/45/f325ee2e7c1db162b30106793802bd51c0147fe3f37c5e02c9c1810fb6d1', 'e8c923ad83f0615c9b8f16d4335bcc644882b8addb70aeb6b9c13f16c7d7ee6f'),
}


def prepare(name):
    filename, remote, digest = PACKAGES[name]
    cache = BUILD / 'z80-tools'
    cache.mkdir(parents=True, exist_ok=True)
    wheel = cache / filename
    if not wheel.exists():
        with urllib.request.urlopen(f'https://files.pythonhosted.org/packages/{remote}/{filename}', timeout=30) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('Downloaded tool hash mismatch')
        wheel.write_bytes(data)
    if hashlib.sha256(wheel.read_bytes()).hexdigest() != digest:
        raise ValueError('Cached tool hash mismatch')
    dest = cache / name
    # Verify extracted modules on every use, including the emulator native extension.
    with zipfile.ZipFile(wheel) as archive:
        for item in archive.infolist():
            target = (dest / item.filename).resolve()
            if not target.is_relative_to(dest.resolve()):
                raise ValueError('Unsafe wheel path')
            if item.is_dir():
                continue
            data = archive.read(item)
            if not target.exists() or target.read_bytes() != data:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
    sys.path.insert(0, str(dest))
    return dest


if __name__ == '__main__':
    for package in sys.argv[1:] or ['pyz80', 'z80']:
        print(prepare(package))
