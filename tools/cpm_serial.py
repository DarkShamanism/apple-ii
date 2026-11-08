"""A2CB: boot Premium SoftCard IIe CP/M 2.26B over the Super Serial Card from disk images on the PC.

The Apple needs no disk drive. serve() deposits the A2CB bootstrap through the Apple
monitor, sends CP/M's track 0 boot image with its Disk II RWTS replaced by a serial
RWTS (src/cpm_rwts.s), then answers every sector read and write from the images until
stopped. It opens the serial port only when the launcher's CP/M boot action runs it.
Protocol: docs/CPM-SERIAL.md.
"""
import hashlib
import json
from pathlib import Path
import shutil
import time

from softcard_probe import monitor_lines

ROOT = Path(__file__).resolve().parents[1]
BASE = 0x6000
REQ, RSP = 0xA5, 0x5A
OP_READ, OP_WRITE, OP_BOOT, OP_HELLO = 1, 2, 3, 4
OK, WRITE_PROTECTED, IO_ERROR, RESEND = 0x00, 0x10, 0x40, 0xFE
BAUDS = {115200: 0x10, 19200: 0x1F}       # 6551 control byte for each fast rate
TRACKS, SECTORS, SECTOR = 35, 16, 256
IMAGE_BYTES = TRACKS * SECTORS * SECTOR
# Physical sector -> 256-byte sector within a track of the image file.
FILE_SECTOR = {'dos': (0, 7, 14, 6, 13, 5, 12, 4, 11, 3, 10, 2, 9, 1, 8, 15),
               'prodos': (0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15)}
ORDER = {'.dsk': 'dos', '.do': 'dos', '.po': 'prodos'}

# Boot image: track 0 sector 0 ($0800), then the 15 sectors the boot sector's table at
# $08C4 names, as loaded to $0A00-$18FF and copied to $D100-$DFFF. Offsets below are
# into that 4 KB image; for $D100-$DFFF the offset is the address minus $D000.
PROFILE_226B = {
    'name': 'Premium SoftCard IIe CP/M 2.26B',
    'checks': (('boot sector', 0x000, 0x0D4, '2b89bf02d82a104e208c17a574bac5532e353189c661f488d1f8af220e48fac8'),
               ('Disk II RWTS $D500', 0x500, 0x69B, '6275bcb0d94ca48280e78e4bef6efb4a0a99b4a13ec16b19a5186aef7d00d4d5'),
               ('disk entry $D6A5', 0x6A5, 0x6D3, '9188cd38ecc0c774341a5b5d2e9b7fecb988bb74394e24a23a1f2f4b91ce9f62'),
               ('format entry $D700', 0x700, 0x70A, '565886e2389a52accdbdb4480eb3089571dd01c340c1eb8160ae3cf0491858ab'),
               ('slot scan end $D9E4', 0x9E4, 0x9FE, '545fac0b13f0199b4a4e5ae8df6b6a79289daf7d03b385c6624bf304a3391176')),
    'rwts': 0x500, 'rwts_end': 0x69B, 'sector_table': 0x68B,
    'patches': ((0x707, bytes((0x4C, 0x03, 0xD5))),      # $D707: format -> serial RWTS $D503
                (0x9FB, bytes((0x4C, 0x06, 0xD5)))),     # $D9FB JMP $D399 -> slot fix $D506
}
# 2.25 has the same IOB/format ABI, but returns from the slot scan to $D37C.
# Fingerprints were read from the user's unmodified 140K Microsoft 2.25 disk.
PROFILE_225 = dict(PROFILE_226B, name='Premium SoftCard IIe CP/M 2.25',
    slot_return=0xD37C,
    checks=tuple((name, start, end, {
        'Disk II RWTS $D500': '2b8c17114075ca60ec41bf0a226a5e867681b387e3c5bcf6c572ca013eafedc8',
        'slot scan end $D9E4': 'bae682cf6907ffc3a1a17bcd97ff98432934573d80d9d54c3ee5a79d1319e369',
    }.get(name, digest)) for name, start, end, digest in PROFILE_226B['checks']))
PROFILES = [PROFILE_226B, PROFILE_225]


def sum16(data):
    return sum(data) & 0xFFFF


def check_byte(*fields):
    value = REQ
    for field in fields:
        value ^= field
    return value


def load_binary(version, name, banner=None):
    path = ROOT / 'build' / version / name
    if not path.is_file():
        raise ValueError(f'{name} is missing; run build.ps1')
    data = bytearray(path.read_bytes())
    if data[0] != 0x4C or (banner and banner.encode() not in data):
        raise ValueError(f'{name} does not match this release; run build.ps1')
    return data


class DiskImage:
    """A 140K Apple II disk image. Writes go straight to the file."""
    def __init__(self, path, writable):
        self.path = Path(path)
        self.order = ORDER.get(self.path.suffix.lower())
        if self.order is None:
            raise ValueError(f'{self.path.name}: use a .dsk, .do or .po disk image')
        if not self.path.is_file():
            raise ValueError(f'Disk image not found: {self.path}')
        self.data = bytearray(self.path.read_bytes())
        if len(self.data) != IMAGE_BYTES:
            raise ValueError(f'{self.path.name} is {len(self.data)} bytes; a 140K disk image is {IMAGE_BYTES}')
        self.writable = writable
        self.reads = self.writes = 0
        self.sha256_before = hashlib.sha256(self.data).hexdigest()

    def offset(self, track, physical):
        if not (0 <= track < TRACKS and 0 <= physical < SECTORS):
            raise ValueError(f'track {track} sector {physical} is outside a 140K disk')
        return track * SECTORS * SECTOR + FILE_SECTOR[self.order][physical] * SECTOR

    def read(self, track, physical):
        at = self.offset(track, physical)
        self.reads += 1
        return bytes(self.data[at:at + SECTOR])

    def write(self, track, physical, data):
        at = self.offset(track, physical)
        self.data[at:at + SECTOR] = data
        with open(self.path, 'r+b') as handle:
            handle.seek(at)
            handle.write(data)
            handle.flush()
        self.writes += 1


def boot_image(disk, rwts, slot, ctrl):
    """Track 0 boot image with the serial RWTS in place, its RWTS sector table and profile."""
    first = disk.read(0, 0)
    table = first[0xC4:0xD4]
    if first[0] != 1 or sorted(table) != list(range(16)) or table[0] != 0:
        raise ValueError(f'{disk.path.name} has no Premium SoftCard boot sector on track 0')
    image = bytearray(first)
    for i in range(1, 16):
        image += disk.read(0, table[i])
    for profile in PROFILES:
        differs = [name for name, start, end, digest in profile['checks']
                   if hashlib.sha256(image[start:end]).hexdigest() != digest]
        if not differs:
            break
    else:
        supported = ', '.join(p['name'] for p in PROFILES)
        raise ValueError(f'{disk.path.name} does not match any supported boot profile ({supported}). '
                         'Its boot code differs. Nothing was sent.')
    sectors = list(image[profile['sector_table']:profile['sector_table'] + 16])
    if sorted(sectors) != list(range(16)):
        raise ValueError('The RWTS sector table is damaged')
    if len(rwts) > profile['rwts_end'] - profile['rwts'] or rwts[0:7:3] != b'\x4c\x4c\x4c':
        raise ValueError('A2CB-RWTS.BIN does not fit the 2.26B RWTS area; run build.ps1')
    rwts = bytearray(rwts)
    # The assembled slotfix ends in JMP $D399. Relocate only this checked,
    # unique instruction for 2.25; never change the user's disk bytes.
    slotfix = int.from_bytes(rwts[7:9], 'little') - 0xD500
    jump = rwts.find(b'\x4c\x99\xd3', slotfix)
    if not 0 <= slotfix < len(rwts) or jump < 0 or rwts.count(b'\x4c\x99\xd3') != 1:
        raise ValueError('A2CB-RWTS.BIN has an unknown slot-scan continuation; rebuild this release')
    rwts[jump + 1:jump + 3] = profile.get('slot_return', 0xD399).to_bytes(2, 'little')
    rwts[9], rwts[10], rwts[11] = slot << 4, ctrl, slot    # cfg_slotx, cfg_ctrl, cfg_slot
    image[profile['rwts']:profile['rwts'] + len(rwts)] = rwts
    for at, data in profile['patches']:
        image[at:at + len(data)] = data
    return bytes(image), sectors, profile


class Service:
    """Answers A2CB requests. port needs read(n), write(data), flush() and a baudrate attribute."""
    def __init__(self, port, disks, boot, sectors, fast, stopped, log=print):
        self.port, self.disks, self.boot, self.sectors = port, disks, boot, sectors
        self.fast, self.stopped, self.log = fast, stopped, log
        self.booted = False
        self.errors = []
        self.events = 0
        self.last_report = time.monotonic()

    def read_exact(self, count, seconds=1.0):
        data = bytearray()
        deadline = time.monotonic() + seconds
        while len(data) < count:
            chunk = self.port.read(count - len(data))
            if chunk:
                data += chunk
            elif time.monotonic() > deadline:
                return None
        return bytes(data)

    def reply(self, status, seq, payload=b''):
        frame = bytes((RSP, status, seq)) + payload
        if payload:
            total = sum16(payload)
            frame += bytes((total & 0xFF, total >> 8))
        self.port.write(frame)
        self.port.flush()

    def next_request(self):
        """The next well-formed request header, or None when stopped."""
        while not self.stopped():
            first = self.port.read(1)
            if not first or first[0] != REQ:
                continue
            body = self.read_exact(6)
            if body is None:
                continue
            op, unit, track, sector, seq, check = body
            if check != check_byte(op, unit, track, sector, seq):
                self.errors.append(f'damaged request header {body.hex()}')
                self.reply(RESEND, seq)
                continue
            return op, unit, track, sector, seq
        return None

    def disk_for(self, unit):
        slot, drive = unit >> 4, unit & 0x0F
        if slot == 6 and drive in (1, 2):
            return self.disks[drive - 1]
        return None

    def handshake(self, seconds=60):
        """Wait for the bootstrap's hello at 9600, answer it, then change to the fast rate."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.stopped():
                raise InterruptedError('Stopped before the Apple answered; nothing was sent.')
            first = self.port.read(1)
            if not first or first[0] != REQ:
                continue
            body = self.read_exact(6)
            if body is None or body[0] != OP_HELLO or body[5] != check_byte(*body[:5]):
                continue
            if body[3] != BAUDS[self.fast]:
                raise ValueError('The bootstrap asked for a different rate; run build.ps1 and try again')
            self.reply(OK, body[4])
            time.sleep(.05)
            self.port.baudrate = self.fast
            self.log(f'A2CB bootstrap answered; serving at {self.fast} baud.')
            return
        raise TimeoutError('No answer from the A2CB bootstrap. Check IN#slot and Ctrl-A 14B, the slot and the cable.')

    def handle(self, op, unit, track, sector, seq):
        self.events += 1
        if op == OP_HELLO:                              # the bootstrap again, still at its slow rate
            self.errors.append('hello received while serving: rerun the boot from the launcher')
            return
        if op == OP_BOOT:
            self.reply(OK, seq, self.boot)
            self.log('Sent the track 0 boot image (4096 bytes). CP/M is starting on the Apple.')
            return
        if op == OP_WRITE:                              # take the data first, so framing holds
            body = self.read_exact(SECTOR + 2)
            if body is None or sum16(body[:SECTOR]) != body[SECTOR] | body[SECTOR + 1] << 8:
                self.errors.append(f'damaged write T{track} S{sector}')
                self.reply(RESEND, seq)
                return
        disk = self.disk_for(unit)
        if op not in (OP_READ, OP_WRITE) or not 0 <= sector < SECTORS or track >= TRACKS:
            self.errors.append(f'bad request op {op} unit {unit:02X} T{track} S{sector}')
            self.reply(IO_ERROR, seq)
            return
        if disk is None:
            self.reply(IO_ERROR, seq)
            return
        physical = self.sectors[sector]
        if op == OP_READ:
            if not self.booted:
                self.booted = True
                self.log(f'CP/M is reading drive {"AB"[(unit & 15) - 1]}: from the PC.')
            self.reply(OK, seq, disk.read(track, physical))
        elif not disk.writable:
            self.reply(WRITE_PROTECTED, seq)
        else:
            disk.write(track, physical, body[:SECTOR])
            self.reply(OK, seq)

    def report(self, force=False):
        if force or time.monotonic() - self.last_report > 10:
            self.last_report = time.monotonic()
            parts = [f'{"AB"[i]}: {d.reads} reads, {d.writes} writes' for i, d in enumerate(self.disks) if d]
            self.log('Serving. ' + '; '.join(parts) + (f'; {len(self.errors)} errors' if self.errors else ''))

    def run(self):
        while True:
            request = self.next_request()
            if request is None:
                return
            self.handle(*request)
            self.report()


def backup(image, backup_dir):
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp, count = time.strftime('%Y%m%d-%H%M%S'), 1
    target = backup_dir / f'{stamp}-{image.path.name}'
    while target.exists():
        count += 1
        target = backup_dir / f'{stamp}-{count}-{image.path.name}'
    shutil.copyfile(image.path, target)
    return target


def serve(config, stopped, serial):
    """The launcher's CP/M boot action. Images and binaries are checked before the port opens."""
    out = Path(config['OutputDir'])
    version, slot, fast = config['Version'], int(config['Slot']), int(config['Baud'])
    if not 1 <= slot <= 7 or fast not in BAUDS:
        raise ValueError('Choose SSC slot 1-7 and 115200 or 19200 baud')
    writable = config['Writes'] == 'Save'
    a = DiskImage(config['DiskA'], writable)
    b = DiskImage(config['DiskB'], writable) if config.get('DiskB') else None
    if b and b.path.resolve() == a.path.resolve():
        raise ValueError('Choose different images for A: and B:')
    rwts = load_binary(version, 'A2CB-RWTS.BIN')
    boot, sectors, profile = boot_image(a, rwts, slot, BAUDS[fast])
    a.reads = 0                                         # count only what CP/M asks for
    loader = load_binary(version, 'A2CB-BOOT.BIN', f'A2CB BOOT V{version}')
    loader[3], loader[4] = slot, BAUDS[fast]
    backups = [str(backup(d, Path(config['BackupDir']))) for d in (a, b) if d and writable]
    port = serial.Serial(port=None, baudrate=9600, timeout=.1, write_timeout=3, bytesize=8,
                         parity='N', stopbits=1, xonxoff=False, rtscts=False)
    port.port = config['Port']
    port.dtr = True
    port.rts = True
    service = Service(port, [a, b], boot, sectors, fast, stopped, lambda text: print(text, flush=True))
    try:
        port.open()
        print(f'CP/M boot: opened {port.port} at 9600 8N1. Depositing the {len(loader)}-byte A2CB bootstrap at $6000.', flush=True)
        port.write(b'CALL -151\r')
        time.sleep(.2)
        for line in monitor_lines(loader):
            if stopped():
                raise InterruptedError('Stopped during the upload; the bootstrap was not started.')
            port.write(line.encode('ascii') + b'\r')
            time.sleep(.1)
        port.reset_input_buffer()
        port.write(b'6000G\r')
        port.flush()
        service.handshake()
        service.run()
    finally:
        port.close()
        service.report(force=True)
        result = {'action': 'CpmBoot', 'profile': profile['name'], 'baud': fast, 'slot': slot,
                  'writes': 'saved to the images' if writable else 'refused (read only)', 'backups': backups,
                  'booted': service.booted, 'requests': service.events, 'errors': service.errors[-50:],
                  'disks': [{'drive': 'AB'[i], 'image': str(d.path), 'reads': d.reads, 'writes': d.writes,
                             'sha256_before': d.sha256_before, 'sha256_after': hashlib.sha256(d.data).hexdigest()}
                            for i, d in enumerate((a, b)) if d]}
        (out / 'results.json').write_text(json.dumps(result, indent=2))
    print('CP/M boot service stopped. The Apple reports disk errors until it is restarted.', flush=True)
    return result
