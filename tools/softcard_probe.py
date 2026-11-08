"""A2SC SoftCard probe: monitor bootstrap, report capture and interpretation.

The probe runs only in Apple RAM. This module opens a serial port only from
run_probe(), which the launcher calls for the explicit CardProbe action.
"""
import json
from pathlib import Path
import re
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = 0x6000
MODES = ('00', '01', '04', '05')
REGIONS = (('zero page and stack ($00-$01)', 0x00, 0x02), ('$0200-$1FFF', 0x02, 0x20),
           ('$2000-$9FFF', 0x20, 0xA0), ('$A000-$BFFF', 0xA0, 0xC0))
LOOP_TSTATES = 42                       # src/z80/sc-probe.asm counting loop
FRAME_SECONDS = 17030 / 1020484         # one NTSC IIe video frame
FRAMES = 8


def load_probe(version):
    path = ROOT / 'build' / version / 'A2SC-PROBE.BIN'
    data = bytearray(path.read_bytes())
    if len(data) < 8 or data[0] != 0x4C or f'A2SC PROBE V{version}'.encode() not in data:
        raise ValueError('Probe binary is missing or does not match this release; run build.ps1')
    return data


def patch(data, slot):
    if not 1 <= slot <= 7:
        raise ValueError('SSC slot must be 1-7')
    data = bytearray(data)
    data[3] = slot                      # header ABI: slot, reserved, reserved
    return data


def monitor_lines(data, base=BASE, width=8):
    """Apple monitor deposit commands, eight bytes per line like the Hi-Res bootstrap."""
    return [f'{base + offset:04X}: ' + ' '.join(f'{b:02X}' for b in data[offset:offset + width])
            for offset in range(0, len(data), width)]


def parse_report(raw):
    """Split the probe's report and verify the 16-bit byte sum on its END line."""
    start = raw.find(b'A2SC PROBE V')
    end = raw.find(b'END ', start)
    if start < 0 or end < 0:
        raise ValueError('No complete probe report (banner and END line) was received')
    line_end = raw.find(b'\r', end)
    if line_end < 0:
        raise ValueError('Probe report ended inside its END line')
    expected = int(raw[end + 4:line_end].decode('ascii'), 16)
    if sum(raw[start:end]) & 0xFFFF != expected:
        raise ValueError('Probe report checksum failed; repeat the probe')
    lines = raw[start:end].decode('ascii').split('\r\n')
    report = {'banner': lines[0], 'map': {}, 'poweron': {}}
    for line in lines[1:]:
        if not line:
            continue
        key, _, value = line.partition(' ')
        if re.fullmatch(r'M[0-3][0-3]', key):
            report['map'][key[1:]] = bytes.fromhex(value)
        elif re.fullmatch(r'P[0-3]', key):
            report['poweron'][key[1]] = bytes.fromhex(value)
        else:
            report[key] = value
    for key in ('SLOT', 'ID', 'BASE', 'R1', 'RUN', 'S01', 'REQ', 'MBX', 'ZR', 'V40', 'POST', 'PP'):
        if key not in report:
            raise ValueError(f'Probe report is missing its {key} line')
    if len(report['map']) != 16 or len(report['poweron']) != 4:
        raise ValueError('Probe report is missing window-map lines')
    report['PP'] = bytes.fromhex(report['PP'])
    return report


def relation(tags, first, last):
    """How reader pages relate to the pages whose tags they hold, e.g. 'same' or 'none+xor8000'."""
    kinds = set()
    for page in range(first, last):
        value = tags[page]
        kinds.add('none' if value == 0xFF else 'same' if value == page
                  else 'xor8000' if value == page ^ 0x80 else 'other')
    return '+'.join(sorted(kinds))


def analyse(report):
    ident = bytes.fromhex(report['ID'].replace(' ', ''))
    run = report['RUN'].split()
    count1, count2, flags = int(run[0], 16), int(run[1], 16), int(run[2], 16)
    first, polls = (int(x, 16) for x in report['REQ'].split())
    zr = bytes.fromhex(report['ZR'])
    mbx = bytes.fromhex(report['MBX'])
    v40 = bytes.fromhex(report['V40'].replace(' ', ''))
    result = {
        'banner': report['banner'], 'ssc_slot': int(report['SLOT'], 16),
        'machine': {'FBB3': ident[0], 'FBC0': ident[1],
                    'model': 'IIe enhanced' if ident[1] == 0xE0 else 'IIe' if ident[1] == 0xEA else 'unknown'},
        'c07e_read_at_start': ident[2], 'c07e_read_after_05': int(report['R1'], 16),
        'aux_baseline_mask': int(report['BASE'], 16), 'aux_after_restore_mask': int(report['POST'], 16),
        'map': {f'{MODES[int(rk[0])]}<-{MODES[int(rk[1])]}': {name: relation(tags, a, b) for name, a, b in REGIONS}
                for rk, tags in sorted(report['map'].items())},
        'poweron_seen_in_mode': {MODES[int(r)]: {name: relation(tags, a, b) for name, a, b in REGIONS}
                                 for r, tags in sorted(report['poweron'].items())},
        'after_restore': {name: relation(report['PP'], a, b) for name, a, b in REGIONS},
        'z80': {'count_at_hold': count1, 'count_after_two_held_frames': count2,
                'vbl_timeout': bool(flags & 2), 'request_seen': bool(flags & 4), 'request_cleared': bool(flags & 8),
                'status_before_request': first, 'polls_before_request': polls,
                'mailbox_44_4B': mbx.hex(' ').upper(), 'results_E380': zr.hex(' ').upper(),
                'aux_2000_mode01_after_65_write': int(report['S01'], 16),
                'aux_0400_0401_mode01': v40.hex(' ').upper()},
        'serial_dead': bool(flags & 1),
    }
    findings = []
    if count1 == 0:
        findings.append('The Z80 did not run: its counter stayed at 0. No Premium SoftCard answered, '
                        'or it needs a start sequence other than the 2.26B one.')
    else:
        seconds = FRAMES * FRAME_SECONDS
        mhz = count1 * LOOP_TSTATES / seconds / 1e6
        result['z80']['effective_mhz'] = round(mhz, 3)
        findings.append(f'The Z80 ran from reset at 0000h: {count1} loops in {FRAMES} frames, about {mhz:.2f} MHz '
                        'effective (includes any wait states).' + (' VBL timing failed, so the speed is unreliable.'
                                                                  if flags & 2 else ''))
        findings.append('Writing $01 held the Z80.' if count1 == count2
                        else f'Writing $01 did not hold the Z80 (count moved to {count2}).')
        findings.append('Z80 0045h is 6502 aux $0045 (ALTZP) in mode 01.' if zr[2] == 0x5A
                        else f'Z80 0045h did not show the mailbox byte (read {zr[2]:02X}h).')
    if flags & 4:
        findings.append('The Z80 request (I = 80h) appeared as bit 7 of aux $2000 with $C07E = 41h.')
        if not flags & 8:
            findings.append('The request flag did not clear after the Z80 was resumed.')
        if zr[7] != 1:
            findings.append('The Z80 did not finish after its request was serviced.')
        else:
            findings.append('Mailbox reply path works (Z80 read A7h at 0045h after service).' if zr[3] == 0xA7
                            else f'Mailbox reply did not reach the Z80 (it read {zr[3]:02X}h at 0045h).')
            findings.append('Z80 2000h is 6502 aux $2000 in mode 01.' if zr[6] == 0x65
                            else f'Z80 2000h is not aux $2000 in mode 01 (read {zr[6]:02X}h).')
            findings.append('Z80 0400h is aux $0400, so the 80-column text page is inside Z80 memory.' if zr[4] == 0xC3
                            else f'Z80 0400h is not aux $0400 in mode 01 (read {zr[4]:02X}h): the text page is elsewhere.')
            findings.append('A 6502 aux write made with the run bit set reached Z80 RAM.' if zr[5] == 0xD4
                            else 'A 6502 aux write made with the run bit set did not reach Z80 0401h.')
    elif count1:
        findings.append('No Z80 request was seen in about 2.6 s.')
    layout = result['poweron_seen_in_mode']
    for mode, regions in layout.items():
        changed = [f'{name} {kind}' for name, kind in regions.items() if kind != 'same']
        findings.append(f'Mode {mode}: ' + ('aux RAM laid out as at power-on.' if not changed
                                            else 'differs from power-on: ' + '; '.join(changed) + '.'))
    window = layout['05']['$2000-$9FFF']
    others = {kind for name, kind in layout['05'].items() if name != '$2000-$9FFF'}
    if 'xor8000' in window and set(window.split('+')) <= {'xor8000', 'none'} and others == {'same'}:
        findings.append('Mode 05 moves only aux $2000-$9FFF, to the power-on address XOR $8000, as 2.26B assumes.')
    findings.append('After $C07E = 00 the power-on aux layout is back.' if set(result['after_restore'].values()) == {'same'}
                    else 'After $C07E = 00 aux RAM is not laid out as at power-on: power-cycle before streaming.')
    result['findings'] = findings
    return result


def run_probe(config, stopped, serial):
    """Upload through the Apple monitor (IN#n, Ctrl-A 14B already typed), run, capture."""
    out = Path(config['OutputDir'])
    data = patch(load_probe(config['Version']), int(config['Slot']))
    lines = monitor_lines(data)
    port = serial.Serial(port=None, baudrate=9600, timeout=.1, write_timeout=3, bytesize=8,
                         parity='N', stopbits=1, xonxoff=False, rtscts=False)
    port.port = config['Port']
    port.dtr = True
    port.rts = True
    raw = bytearray()
    try:
        port.open()
        print(f'Probe: opened {port.port} at 9600 8N1. Depositing {len(data)} bytes at $6000 through the monitor.', flush=True)
        port.write(b'CALL -151\r')
        time.sleep(.2)
        for number, line in enumerate(lines, 1):
            if stopped():
                raise InterruptedError('Upload stopped; the probe was not started. Reset the Apple.')
            port.write(line.encode('ascii') + b'\r')
            time.sleep(.1)
            port.reset_input_buffer()
            if number % 50 == 0:
                print(f'{number}/{len(lines)} monitor lines sent', flush=True)
        port.write(b'6000G\r')
        port.flush()
        print('Probe started. Waiting for its report (about 15 s).', flush=True)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if stopped():
                raise InterruptedError('Stopped while the probe was reporting; power-cycle the Apple.')
            raw += port.read(max(1, port.in_waiting))
            end = raw.find(b'END ', raw.find(b'A2SC PROBE V'))
            if end >= 0 and raw.find(b'\r', end) >= 0:
                break
    finally:
        port.close()
        (out / 'probe-report.txt').write_bytes(bytes(raw))
    if not raw:
        raise TimeoutError('No probe output. Check IN#slot and Ctrl-A 14B on the Apple, the slot, and the cable.')
    result = analyse(parse_report(bytes(raw)))
    (out / 'results.json').write_text(json.dumps(result, indent=2))
    for finding in result['findings']:
        print('- ' + finding, flush=True)
    print('Probe finished. Power-cycle the Apple before streaming or booting.', flush=True)
    return result
