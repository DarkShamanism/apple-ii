"""Make A2TS.DSK: the test-screen loader and its four screens on a bootable ProDOS disk.

Run by build.ps1 after the portal build, which makes the screens. The disk begins as a copy of
the ProDOS boot disk the other release disks are made from. That disk is nearly full of
utilities, so everything except PRODOS and BASIC.SYSTEM is deleted from the copy first; it then
boots straight to BASIC, where BRUN A2TS starts the loader. AppleCommander exits 0 even when an
action fails, so every file is read back and compared before the disk is accepted.
"""
import argparse
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vsdrive_lab import AppleCommander, directory, volume_name

KEEP = ('PRODOS', 'BASIC.SYSTEM')
VOLUME = 'A2TS.SCREENS'
# name on the disk, file under the build folder, load address
FILES = (('A2TS', 'A2TS-LOADER.BIN', 0x6000), ('LORES.COLOR', 'site/dist/assets/lores-color.bin', 0x0400),
         ('LORES.MONO', 'site/dist/assets/lores-mono.bin', 0x0400), ('HIRES.MONO', 'site/dist/assets/hires-mono.bin', 0x2000),
         ('DHGR.MONO', 'site/dist/assets/dhgr-mono.bin', 0x2000))


def make(template, java, jar, build):
    build = Path(build)
    tool = AppleCommander(java, jar)
    disk = build / 'A2TS.DSK'
    work = build / 'A2TS.DSK.tmp'
    shutil.copyfile(template, work)
    try:
        names = [name for name, _ in directory(work.read_bytes())]
        missing = [name for name in KEEP if name not in names]
        if missing:
            raise ValueError(f'the boot disk template has no {", ".join(missing)}')
        for name in names:
            if name not in KEEP:
                tool.run('-d', work, name)
        left = [name for name, _ in directory(work.read_bytes())]
        if sorted(left) != sorted(KEEP):
            raise ValueError(f'could not clear the template: {left} remain')
        tool.run('-n', work, VOLUME)
        if volume_name(work.read_bytes()) != VOLUME:
            raise ValueError('the volume could not be named')
        for name, source, address in FILES:
            data = (build / source).read_bytes()
            tool.run('-p', work, name, 'bin', address, data=data)
            if tool.run('-g', work, name) != data:
                raise ValueError(f'{name} did not read back from the disk')
        for name in KEEP:                      # the system files still read as they did on the template
            if tool.run('-g', work, name) != tool.run('-g', template, name):
                raise ValueError(f'{name} changed while the disk was made')
        work.replace(disk)
    finally:
        work.unlink(missing_ok=True)
    return disk


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for option in ('--template', '--java', '--jar', '--build'):
        parser.add_argument(option, required=True)
    args = parser.parse_args()
    try:
        print(f'Built {make(args.template, args.java, args.jar, args.build)}')
    except (ValueError, OSError) as error:
        sys.exit(f'Test-screen disk failed: {error}')
