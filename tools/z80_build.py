"""Build CP/M programs, A2Z modules or the SoftCard probe stub, with listings, HEX and provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from z80_deps import BUILD, ROOT, prepare


def ihex(data, origin):
    lines = []
    for offset in range(0, len(data), 16):
        chunk = data[offset:offset + 16]
        address = origin + offset
        record = bytes([len(chunk), address >> 8, address & 255, 0]) + chunk
        lines.append(':' + (record + bytes([-sum(record) & 255])).hex().upper())
    return '\r\n'.join(lines + [':00000001FF', ''])


def build(source, target, output):
    source, output = Path(source).resolve(), Path(output).resolve()
    if not output.is_relative_to(BUILD.resolve()):
        raise ValueError('Generated files must stay under this release build directory')
    # Probe: the A2SC Z80 stub, which must end before its result area at E380h.
    origin = {'COM': 0x100, 'Module': 0x4000, 'Probe': 0xE300}[target]
    text = source.read_text(encoding='utf-8-sig')
    # Ensure the first emitted byte belongs at the chosen runtime address.
    lines = [line.split(';', 1)[0].strip() for line in text.splitlines()]
    first = next((line for line in lines if line), '')
    match = re.fullmatch(r'org\s+(0x[0-9a-f]+|[0-9]+)', first.lower())
    if not match or int(match[1], 16 if match[1].startswith('0x') else 10) != origin:
        raise ValueError(f'First statement must be ORG 0x{origin:04X} for {target}')
    output.mkdir(parents=True, exist_ok=True)
    name = {'COM': 'PROGRAM', 'Module': 'MODULE', 'Probe': 'PROBE'}[target]
    binary = output / (name + ('.COM' if target == 'COM' else '.BIN'))
    # Delete stale success metadata before running the assembler.
    for stale in (output / 'result.json', binary):
        stale.unlink(missing_ok=True)
    assembler = prepare('pyz80') / 'pyz80' / 'pyz80.py'
    result = subprocess.run([sys.executable, str(assembler), '--obj=' + str(binary),
                             '--mapfile=' + str(output / 'symbols.txt'),
                             '--lstfile=' + str(output / 'listing.txt'), str(source)],
                            cwd=output, text=True, capture_output=True, timeout=60)
    print(result.stdout, end='')
    if result.returncode:
        raise ValueError(result.stderr or 'Assembly failed')
    data = binary.read_bytes()
    maximum = {'COM': 0x3e00, 'Module': 4096, 'Probe': 0x80}[target]
    if not 0 < len(data) <= maximum:
        binary.unlink()
        raise ValueError(f'{target} output must contain 1..{maximum} bytes')
    (output / (name + '.HEX')).write_bytes(ihex(data, origin).encode('ascii'))
    metadata = dict(source=str(source), target=target, origin=origin, size=len(data), binary=str(binary),
                    sha256=hashlib.sha256(data).hexdigest(), source_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
    (output / 'result.json').write_text(json.dumps(metadata, indent=2))
    print(f'Built {binary}: {len(data)} bytes at {origin:04X}h; SHA256 {metadata["sha256"]}')
    return binary


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--source')
    p.add_argument('--target', choices=['COM', 'Module'], default='Module')
    p.add_argument('--output')
    p.add_argument('--release', action='store_true')
    args = p.parse_args()
    if args.release:
        for dependency in ('pyz80', 'z80', 'pyserial'):
            prepare(dependency)
        helper = build(ROOT / 'src/z80/a2z.asm', 'COM', BUILD / 'z80/helper')
        (BUILD / 'A2Z.COM').write_bytes(helper.read_bytes())
        (BUILD / 'A2Z.HEX').write_bytes((helper.parent / 'PROGRAM.HEX').read_bytes())
        build(ROOT / 'src/z80/example-module.asm', 'Module', BUILD / 'z80/example')
        build(ROOT / 'src/z80/hello-cpm.asm', 'COM', BUILD / 'z80/hello')
        probe = build(ROOT / 'src/z80/sc-probe.asm', 'Probe', BUILD / 'z80/probe')
        (BUILD / 'SC-PROBE-Z80.BIN').write_bytes(probe.read_bytes())
    else:
        build(args.source, args.target, args.output)
