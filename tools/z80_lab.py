"""CP/M workbench and SoftCard probe backend; serial is only opened by explicit serial actions."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import time
from collections import deque
sys.path.insert(0, str(Path(__file__).resolve().parent))
from z80_deps import BUILD, ROOT, prepare
from z80_build import build


def packet(command, data=b''):
    if len(data) > 34:
        raise ValueError('Packet too large')
    body = bytes([command, len(data)]) + data
    check = 0
    for byte in body:
        check ^= byte
    return b':' + (body + bytes([check])).hex().upper().encode() + b'\r'


def parse_packet(line):
    if not line.startswith(b':'):
        raise ValueError('Missing packet marker')
    try:
        data = bytes.fromhex(line[1:].decode('ascii').strip())
    except (ValueError, UnicodeError) as error:
        raise ValueError('Invalid packet hex') from error
    if len(data) < 3 or len(data) != data[1] + 3 or data[1] > 34:
        raise ValueError('Invalid packet length')
    check = 0
    for byte in data:
        check ^= byte
    if check:
        raise ValueError('Packet checksum failed; restart A2Z R after a damaged transfer')
    return data[0], data[2:-1]


class Client:
    def __init__(self, port, stopped=lambda: False):
        self.port, self.stopped = port, stopped

    def command(self, command, data=b''):
        if self.stopped():
            raise InterruptedError('Stopped')
        self.port.write(packet(ord(command), data))
        deadline = time.monotonic() + 8
        line = bytearray()
        while time.monotonic() < deadline:
            if self.stopped():
                raise InterruptedError('Stopped; helper may need restarting on the Apple')
            chunk = self.port.read(1)
            if not chunk:
                continue
            if chunk == b':':
                line = bytearray(b':')
            elif line:
                line.extend(chunk)
                if chunk == b'\r':
                    status, payload = parse_packet(bytes(line))
                    if status != 6:
                        raise ValueError('A2Z rejected the command (length, checksum, bounds or uncommitted module)')
                    return payload
                if len(line) > 80:
                    raise ValueError('Oversized helper reply')
        raise TimeoutError('No A2Z reply. Check A2Z R, RDR:/PUN: driver routing, cable and matching baud. Restart A2Z R after an incomplete packet.')

    def hello(self):
        if self.command('H') != b'A2Z1':
            raise ValueError('Incompatible helper version')

    def upload(self, data):
        if not 1 <= len(data) <= 4096:
            raise ValueError('Modules must contain 1..4096 bytes')
        for offset in range(0, len(data), 32):
            part = data[offset:offset + 32]
            self.command('W', struct.pack('<H', offset) + part)
            actual = self.command('R', struct.pack('<HB', offset, len(part)))
            if actual != part:
                raise ValueError('Module read-back differs; module was not committed')
        self.command('C', struct.pack('<HH', len(data), sum(data) & 65535))


class EmulatedCPM:
    """Real Z80 execution with a small BDOS test shim; not an Apple II emulator."""
    def __init__(self, remote=True):
        prepare('z80')
        from z80 import Z80Machine
        self.cpu = m = Z80Machine()
        m.set_memory_block(0x100, (BUILD / 'A2Z.COM').read_bytes())
        m.set_memory_block(5, bytes([0xc3, 0, 0xe0]))
        m.set_memory_block(0x80, b'\x02 R\r' if remote else b'\x00\r')
        m.pc = 0x100
        m.sp = 0xd000
        m.set_breakpoint(0)
        m.set_breakpoint(5)
        self.rx, self.tx = deque(), deque()
        self.console = bytearray()
        self.exited = False
        self.bdos_calls = 0
        self.pump()

    def pump(self):
        m = self.cpu
        deadline = time.monotonic() + 3
        for _ in range(200000):
            if time.monotonic() > deadline:
                raise TimeoutError('Emulated program exceeded the three-second execution limit')
            if m.pc == 0:
                self.exited = True
                return
            if m.pc == 5:
                if m.c == 3 and not self.rx:
                    return
                self.bdos_calls += 1
                if m.c == 3:
                    m.a = self.rx.popleft()
                elif m.c == 4:
                    self.tx.append(m.e)
                elif m.c == 12:
                    m.hl = 0x22
                elif m.c == 9:
                    address = m.de
                    while m.memory[address] != 36:
                        self.console.append(m.memory[address])
                        address = (address + 1) & 65535
                        if address == m.de:
                            raise ValueError('Unterminated BDOS string')
                else:
                    raise ValueError(f'Unsupported emulated BDOS call {m.c}')
                m.pc = m.memory[m.sp] | (m.memory[m.sp + 1] << 8)
                m.sp += 2
            m.ticks_to_stop = 10000
            m.run()
        raise TimeoutError('Emulated program did not return within execution limit')

    def write(self, data):
        self.rx.extend(data)
        self.pump()

    def read(self, count):
        return bytes(self.tx.popleft() for _ in range(min(count, len(self.tx))))


def verified_binary(path, target):
    path = Path(path)
    metadata = json.loads((path.parent / 'result.json').read_text())
    data = path.read_bytes()
    if metadata['target'] != target or metadata['sha256'] != hashlib.sha256(data).hexdigest():
        raise ValueError('Build type/hash mismatch; assemble this program again')
    if metadata['origin'] != (0x4000 if target == 'Module' else 0x100):
        raise ValueError('Incorrect program origin')
    return data


def validate_hex(path):
    lines = Path(path).read_text(encoding='ascii').splitlines()
    eof = False
    for line in lines:
        if eof or not line.startswith(':'):
            raise ValueError('Malformed Intel HEX')
        body = bytes.fromhex(line[1:])
        if len(body) < 5 or len(body) != body[0] + 5 or sum(body) & 255:
            raise ValueError('Intel HEX checksum or length error')
        if body[3] not in (0, 1):
            raise ValueError('Only 16-bit data/EOF records are supported by CP/M LOAD')
        if body[3] == 1:
            if body != bytes.fromhex('00000001FF'):
                raise ValueError('Invalid EOF record')
            eof = True
    if not eof:
        raise ValueError('Missing Intel HEX EOF')
    return lines


def main(config):
    action = config['Action']
    out = Path(config['OutputDir']).resolve()
    if not out.is_relative_to(BUILD.resolve()):
        raise ValueError('Output must be in the current release build folder')
    out.mkdir(parents=True, exist_ok=True)
    stopped = lambda: Path(config['StopFile']).exists()
    if action == 'Build':
        build(config['Source'], config['Target'], out)
        return
    if action == 'Emulate':
        data = verified_binary(config['Binary'], 'Module')
        machine = EmulatedCPM()
        client = Client(machine, stopped)
        client.hello()
        print('Emulated diagnostics:', client.command('T').hex().upper(), flush=True)
        client.upload(data)
        result = int.from_bytes(client.command('G'), 'little')
        client.command('Q')
        report = dict(result_hl=result, result_hex=f'{result:04X}', bdos_calls=machine.bdos_calls,
                      hardware=False, scope='Z80 CPU and simulated BDOS; no Apple II bus, SSC or firmware')
        (out / 'results.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
        return
    if action == 'Prepare':
        disk = Path(config['Disk'])
        if not disk.is_file():
            raise ValueError('Select an existing CP/M boot disk image')
        report = dict(path=str(disk), bytes=disk.stat().st_size, sha256=hashlib.sha256(disk.read_bytes()).hexdigest(),
                      cpm=config['CpmVersion'], command=config['Command'], notes=config['Notes'], verified_bootable=False)
        (out / 'boot-plan.json').write_text(json.dumps(report, indent=2))
        print('Boot plan saved. Image recorded, not modified or proven bootable.\n'
              '1. Use a matching Premium SoftCard IIe CP/M system disk.\n'
              '2. Transfer a compatible image using ADTPro or your existing disk workflow.\n'
              '3. Boot it on the Apple; configure SSC using that CP/M disk\'s CONFIGIO.\n'
              '4. Match serial format/baud, then close ADTPro before connecting.\n' + json.dumps(report, indent=2), flush=True)
        return
    if action == 'CardProbe':
        # Diskless: the probe is deposited through the Apple monitor, not CP/M.
        from softcard_probe import load_probe, patch, run_probe
        patch(load_probe(BUILD.name), int(config['Slot']))
        prepare('pyserial')
        import serial
        run_probe(dict(config, Version=BUILD.name, OutputDir=str(out)), stopped, serial)
        return
    if action == 'CpmBoot':
        # Diskless: the A2CB bootstrap goes in through the Apple monitor, then CP/M runs from the images.
        from cpm_serial import serve
        prepare('pyserial')
        import serial
        serve(dict(config, Version=BUILD.name, OutputDir=str(out), Baud=config['BootBaud'], DiskA=config['Disk']),
              stopped, serial)
        return
    if action not in ('Terminal', 'Probe', 'Upload', 'Inspect', 'Run', 'Quit', 'SendHex'):
        raise ValueError('Unknown action')
    # Fail before port access when the requested input is missing or invalid.
    data = verified_binary(config['Binary'], 'Module') if action == 'Upload' else None
    lines = validate_hex(config['HexFile']) if action == 'SendHex' else None
    offset, count = int(config['Offset']), int(config['Count'])
    if not 0 <= offset <= 4095 or not 1 <= count <= 32 or offset + count > 4096:
        raise ValueError('Inspect range must stay inside the 4096-byte module area')
    prepare('pyserial')
    import serial
    port = serial.Serial(port=None, baudrate=int(config['Baud']), timeout=.1, write_timeout=2,
                         bytesize=8, parity='N', stopbits=1, xonxoff=False,
                         rtscts=config['Handshake'] == 'RtsCts')
    port.port = config['Port']
    port.dtr = False
    port.rts = config['Handshake'] == 'RtsCts'
    try:
        port.open()
        print(f'{action}: opened {port.port} / {port.baudrate} / 8N1. Hardware results follow only if received.', flush=True)
        if action == 'Terminal':
            inbox = out / 'terminal-send.json'
            print('Plain text terminal connected. Configure CP/M CON: for serial to use the command prompt here.', flush=True)
            while not stopped():
                if inbox.exists():
                    message = json.loads(inbox.read_text(encoding='utf-8-sig'))['text']
                    if not isinstance(message, str) or len(message) > 2048:
                        raise ValueError('Invalid terminal message')
                    port.write(message.encode('ascii', errors='strict'))
                    inbox.unlink()
                chunk = port.read(max(1, min(port.in_waiting, 4096)))
                if chunk:
                    print(chunk.decode('ascii', errors='backslashreplace'), end='', flush=True)
        elif action == 'SendHex':
            print('Sending to an already waiting PIP NAME.HEX=RDR: command; no CP/M commands are sent automatically.', flush=True)
            for line in lines:
                for byte in (line + '\r\n').encode('ascii'):
                    if stopped():
                        raise InterruptedError('Transfer stopped; erase the partial HEX file on CP/M')
                    port.write(bytes([byte]))
                    time.sleep(.003)
                time.sleep(.05)
            port.write(b'\x1a')
            port.flush()
            print('HEX transmission complete; CP/M receipt is unacknowledged. Run LOAD NAME and check its result.', flush=True)
        else:
            client = Client(port, stopped)
            client.hello()
            report = {'action': action, 'hardware': True}
            if action == 'Probe':
                reply = client.command('T')
                if len(reply) != 5 or reply[4] != 1:
                    raise ValueError('Invalid diagnostic response')
                report.update(cpm_version=f'{reply[0] >> 4}.{reply[0] & 15}', iobyte=reply[1],
                              bdos_entry=f'{int.from_bytes(reply[2:4], "little"):04X}', scratch_ram_bytes=256,
                              scope='Z80 execution, private scratch RAM and BDOS round trip; not a full card/bank/clock test')
            elif action == 'Upload':
                client.upload(data)
                report.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), readback_verified=True)
            elif action == 'Inspect':
                reply = client.command('R', struct.pack('<HB', offset, count))
                if len(reply) != count:
                    raise ValueError('Short memory response')
                report.update(address=f'{0x4000 + offset:04X}', hex=reply.hex(' ').upper())
            elif action == 'Run':
                start = time.monotonic()
                reply = client.command('G')
                if len(reply) != 2:
                    raise ValueError('Invalid result response')
                report.update(result_hl=int.from_bytes(reply, 'little'), roundtrip_ms=round((time.monotonic()-start)*1000, 2),
                              timing_scope='Serial plus helper plus module, not Z80 CPU time')
            else:
                client.command('Q')
            (out / 'results.json').write_text(json.dumps(report, indent=2))
            print(json.dumps(report, indent=2), flush=True)
    finally:
        port.close()
        print('\nPort closed. A2Z R remains active unless Quit succeeded; reset/restart it after partial transfers.', flush=True)


if __name__ == '__main__':
    try:
        main(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig')))
    except InterruptedError as error:
        print(error, flush=True)
