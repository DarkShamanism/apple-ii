"""Deploy this release's receivers into an ADTPro VSDRIVE ProDOS image, or restore a backup.

Run by the launcher with ADTPro closed. The image is backed up first, the work is
done on a copy with AppleCommander, and the copy replaces the image only after
every file reads back byte for byte from the volume directory's first block,
the only block ADTPro's SpeediBoot reads.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

BLOCK = 512
SETS = {
    'Receiver only': [('A2MC.RX', 'A2MC-RX.BIN', 0x1000)],
    'All receivers': [('A2MC.RX', 'A2MC-RX.BIN', 0x1000), ('A2HR.RX', 'A2HR-RX.BIN', 0x6000),
                      ('A2SC.PROBE', 'A2SC-PROBE.BIN', 0x6000)],
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def directory(image):
    """Active entries of a ProDOS volume directory: (name, directory block number)."""
    if len(image) % BLOCK or len(image) < 7 * BLOCK:
        raise ValueError('Not a ProDOS-ordered (.po) image: size is not a whole number of blocks')
    block, entries, seen = 2, [], set()
    header = image[2 * BLOCK + 4:2 * BLOCK + 4 + 0x27]
    if header[0] >> 4 != 0xF:
        raise ValueError('Not a ProDOS volume: block 2 does not hold a volume directory header')
    prodos_name(header)
    length, per_block = header[0x1F], header[0x20]
    if length < 0x27 or per_block < 2:
        raise ValueError('Damaged ProDOS volume directory header')
    while block and block not in seen:
        seen.add(block)
        base = block * BLOCK
        if base + BLOCK > len(image):
            raise ValueError('ProDOS directory points outside the image')
        for index in range(1 if block == 2 else 0, per_block):
            entry = image[base + 4 + index * length:base + 4 + (index + 1) * length]
            if entry[0] >> 4:
                entries.append((prodos_name(entry), block))
        block = image[base + 2] | image[base + 3] << 8
    return entries


def prodos_name(entry):
    name = entry[1:1 + (entry[0] & 0xF)]
    if not name or not all(48 <= c <= 57 or 65 <= c <= 90 or c == 46 for c in name) or not 65 <= name[0] <= 90:
        raise ValueError('Not a ProDOS volume: a directory entry has an invalid name')
    return name.decode('ascii')


def volume_name(image):
    return prodos_name(image[2 * BLOCK + 4:2 * BLOCK + 4 + 16])


class AppleCommander:
    """AppleCommander exits 0 even when an action fails, so callers verify by reading back."""
    def __init__(self, java, jar):
        for path, what in ((java, 'Java'), (jar, 'AppleCommander')):
            if not Path(path).is_file():
                raise ValueError(f'{what} not found: {path}')
        self.command = [str(java), '-jar', str(jar)]

    def run(self, *args, data=None):
        result = subprocess.run(self.command + [str(a) for a in args], input=data, capture_output=True, timeout=120)
        return result.stdout


def verified_artifacts(build_dir, names):
    manifest = json.loads((build_dir / 'build-manifest.json').read_text())['artifacts']
    files = {}
    for name in names:
        data = (build_dir / name).read_bytes()
        if manifest.get(name) != sha256(data):
            raise ValueError(f'{name} does not match this build\'s build-manifest.json; run build.ps1')
        files[name] = data
    return files


def replace_file(source, target):
    # Stage beside the target so the final rename never crosses drives.
    staging = target.with_name(target.name + '.a2mc-tmp')
    shutil.copyfile(source, staging)
    os.replace(staging, target)


def backup(image_path, backup_dir, reason):
    backup_dir.mkdir(parents=True, exist_ok=True)
    data = image_path.read_bytes()
    stamp, count = time.strftime('%Y%m%d-%H%M%S'), 1
    target = backup_dir / f'{stamp}-{image_path.name}'
    while target.exists():
        count += 1
        target = backup_dir / f'{stamp}-{count}-{image_path.name}'
    target.write_bytes(data)
    index_path = backup_dir / 'index.json'
    index = json.loads(index_path.read_text()) if index_path.exists() else []
    index.append({'backup': str(target), 'image': str(image_path.resolve()), 'sha256': sha256(data), 'reason': reason})
    index_path.write_text(json.dumps(index, indent=2))
    return target


def check_image(path):
    if path.suffix.lower() != '.po':
        raise ValueError('Choose a ProDOS-ordered VSDRIVE image (.po), such as ADTPro\'s disks\\Virtual2.po')
    if not path.is_file():
        raise ValueError(f'VSDRIVE image not found: {path}')
    data = path.read_bytes()
    directory(data)
    return data


def deploy(config, stopped):
    image_path = Path(config['Image'])
    out = Path(config['OutputDir'])
    plan = SETS.get(config['Set'])
    if plan is None:
        raise ValueError('Unknown receiver set')
    original = check_image(image_path)
    files = verified_artifacts(Path(config['BuildDir']), [binary for _, binary, _ in plan])
    tool = AppleCommander(config['Java'], config['Jar'])
    if stopped():
        raise InterruptedError('Stopped before any change; the image is unchanged.')
    work = out / ('work-' + image_path.name)
    work.write_bytes(original)
    present = {name for name, _ in directory(original)}
    for name, binary, address in plan:
        if name in present:
            tool.run('-d', work, name)
        tool.run('-p', work, name, 'bin', address, data=files[binary])
        if tool.run('-g', work, name) != files[binary]:
            raise ValueError(f'{name} did not read back from the work copy; the image is unchanged.')
    first = {name for name, block in directory(work.read_bytes()) if block == 2}
    outside = [name for name, _, _ in plan if name not in first]
    if outside:
        raise ValueError(f'{", ".join(outside)} would not be in the first directory block of /{volume_name(original)}, '
                         'where SpeediBoot looks. Delete unneeded files from the volume or deploy the receiver only. '
                         'The image is unchanged.')
    if stopped():
        raise InterruptedError('Stopped before replacing the image; it is unchanged.')
    if image_path.read_bytes() != original:
        raise ValueError('The image changed while deploying (is ADTPro running?); it was not replaced.')
    saved = backup(image_path, Path(config['BackupDir']), 'before deploy')
    replace_file(work, image_path)
    work.unlink()
    after = image_path.read_bytes()
    report = {'action': 'deploy', 'image': str(image_path), 'volume': volume_name(after), 'backup': str(saved),
              'sha256_before': sha256(original), 'sha256_after': sha256(after),
              'files': [{'name': n, 'from': b, 'load_address': f'${a:04X}', 'bytes': len(files[b]), 'sha256': sha256(files[b])}
                        for n, b, a in plan]}
    (out / 'results.json').write_text(json.dumps(report, indent=2))
    for n, b, a in plan:
        print(f'Deployed {n} ({len(files[b])} bytes, load ${a:04X}) into /{report["volume"]}.', flush=True)
    print(f'Backup of the previous image: {saved}', flush=True)
    return report


def restore(config, stopped):
    image_path = Path(config['Image'])
    out = Path(config['OutputDir'])
    current = check_image(image_path)
    index_path = Path(config['BackupDir']) / 'index.json'
    index = json.loads(index_path.read_text()) if index_path.exists() else []
    target = str(image_path.resolve())
    candidates = [entry for entry in index if entry['image'] == target and entry['reason'] == 'before deploy']
    if not candidates:
        raise ValueError('No deploy backup of this image is recorded for this release.')
    chosen = candidates[-1]
    data = Path(chosen['backup']).read_bytes()
    if sha256(data) != chosen['sha256']:
        raise ValueError('The backup file no longer matches its recorded SHA-256; nothing was restored.')
    directory(data)
    if stopped():
        raise InterruptedError('Stopped before any change; the image is unchanged.')
    saved = backup(image_path, Path(config['BackupDir']), 'before restore')
    replace_file(Path(chosen['backup']), image_path)
    report = {'action': 'restore', 'image': str(image_path), 'restored_from': chosen['backup'],
              'sha256_before': sha256(current), 'sha256_after': sha256(image_path.read_bytes()), 'backup_of_replaced': str(saved)}
    (out / 'results.json').write_text(json.dumps(report, indent=2))
    print(f'Restored {image_path.name} from {chosen["backup"]}. The replaced image was kept as {saved}.', flush=True)
    return report


def main(config):
    out = Path(config['OutputDir'])
    out.mkdir(parents=True, exist_ok=True)
    stopped = lambda: Path(config['StopFile']).exists()
    {'Deploy': deploy, 'Restore': restore}[config['Action']](config, stopped)


if __name__ == '__main__':
    try:
        main(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig')))
    except InterruptedError as error:
        print(error, flush=True)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        # A refusal is a message for the journal, not a traceback.
        print(f'VSDRIVE: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
