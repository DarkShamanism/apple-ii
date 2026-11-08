"""Test-only Apple IIe + Premium SoftCard IIe + Super Serial Card model for the CP/M serial boot.

py65 runs the 6502 and the pinned z80 core runs the Z80. The card follows what
Premium CP/M 2.26B's own code implies (docs/SOFTCARD.md): aux RAM is Z80 RAM,
$C07E bit 2 maps 6502 aux $2000-$9FFF to Z80 address XOR $8000, bit 6 runs the
Z80, and an I register with bit 7 set holds the Z80 until the 6502 writes the run
bit again. The SSC is a 6551 with a receive queue paced at the programmed baud
rate. No slot holds a Disk II: the boot has to come over the serial port.
These are logic models for tests, not cycle-accurate hardware.
"""
from collections import deque
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from z80_deps import BUILD, prepare

WHEEL = BUILD / 'testdeps' / 'py65-1.2.0-py2.py3-none-any.whl'
if WHEEL.exists():
    sys.path.insert(0, str(WHEEL))
from py65.devices.mpu6502 import MPU
try:
    import z80
except ImportError:
    prepare('z80')
    import z80

CLOCK = 1020484
Z80_PER_CYCLE = 6.0 / 1.020484
FRAME, VISIBLE = 17030, 192 * 65
SSC_SIGNATURE = {0x05: 0x38, 0x07: 0x18, 0x0B: 0x01, 0x0C: 0x31}
BAUD = {0x10: 115200, 0x1E: 9600, 0x1F: 19200}   # 6551 control register values the tools use


class Card:
    def __init__(self):
        self.z = z80.Z80Machine()
        self.ram = self.z.memory
        self.reg = 0
        self.waiting = False
        self.credit = 0.0
        self.requests = 0

    def write_reg(self, value):
        if (value & 0x40) and self.waiting:
            self.waiting = False
        self.reg = value
        if not value & 1:
            self.z.pc, self.z.i, self.waiting = 0, 0, False

    def address(self, a):
        return a ^ 0x8000 if self.reg & 4 and 0x2000 <= a < 0xA000 else a

    def running(self):
        return self.reg & 0x41 == 0x41

    def read(self, a):
        if self.running() and a == 0x2000:
            return 0x80 if self.z.i & 0x80 else 0x00
        return self.ram[self.address(a)]

    def write(self, a, v):
        self.ram[self.address(a)] = v

    def clock(self, cycles):
        if not self.running():
            self.credit = 0.0
            return
        self.credit += cycles * Z80_PER_CYCLE
        while self.credit > 0 and not self.waiting:
            before, ticks = self.z.i & 0x80, self.z.frame_tick
            self.z.ticks_to_stop = 1
            self.z.run()
            spent = self.z.frame_tick - ticks
            self.credit -= spent if spent > 0 else 4
            if self.z.i & 0x80 and not before:
                self.waiting = True
                self.requests += 1


class SSC:
    """6551 in slot `slot`. rx holds bytes from the PC; each becomes readable after one byte time."""
    def __init__(self, slot):
        self.slot = slot
        self.rx = deque()
        self.tx = bytearray()
        self.tx_rates = []                          # the 6551 rate each byte was sent at
        self.control = 0x1E
        self.ready_at = 0
        self.overruns = 0

    def rate(self):
        return BAUD.get(self.control, 9600)

    def byte_cycles(self):
        return CLOCK * 10 // self.rate()

    def status(self, now):
        ready = bool(self.rx) and now >= self.ready_at
        return 0x10 | (0x08 if ready else 0)

    def read_data(self, now):
        if self.rx and now >= self.ready_at:
            value = self.rx.popleft()
            self.ready_at = now + self.byte_cycles()
            return value
        return 0

    def feed(self, data, now):
        if not self.rx:
            self.ready_at = max(self.ready_at, now + self.byte_cycles())
        self.rx.extend(data)


class IIe:
    def __init__(self, card, ssc):
        self.card, self.ssc = card, ssc
        self.main = bytearray(0x10000)
        self.lc = {(s, b): bytearray(0x1000) for s in 'ma' for b in (1, 2)}
        self.hi = {s: bytearray(0x2000) for s in 'ma'}
        self.s = dict(store80=0, ramrd=0, ramwrt=0, altzp=0, page2=0)
        self.lc_read, self.lc_write, self.bank, self.pre = 0, 0, 2, 0
        self.keys = deque()
        self.cycles = 0
        self.disk_ii = []

    def aux(self, a, write):
        s = self.s
        if a < 0x200:
            return s['altzp']
        if s['store80'] and 0x400 <= a < 0x800:
            return s['page2']
        return s['ramwrt'] if write else s['ramrd']

    def io(self, a, write, v):
        low = a & 0xFF
        if write and low < 0x0A:
            key = ('store80', 'store80', 'ramrd', 'ramrd', 'ramwrt', 'ramwrt', None, None, 'altzp', 'altzp')[low]
            if key:
                self.s[key] = low & 1
        if low in (0x54, 0x55):
            self.s['page2'] = low & 1
        if 0x80 <= low <= 0x8F:
            n = low & 0xF
            self.bank = 1 if n & 8 else 2
            self.lc_read = 1 if n & 3 in (0, 3) else 0
            if n & 1:
                if not write and self.pre:
                    self.lc_write = 1
                self.pre = 0 if write else 1
            else:
                self.lc_write = self.pre = 0
        base = 0x80 + self.ssc.slot * 0x10
        if base + 8 <= low <= base + 11:
            reg = low - base - 8
            if reg == 0:
                if write:
                    self.ssc.tx.append(v)
                    self.ssc.tx_rates.append(self.ssc.rate())
                    return 0
                return self.ssc.read_data(self.cycles)
            if reg == 1:
                return self.ssc.status(self.cycles)
            if reg == 3 and write:
                self.ssc.control = v
            return 0
        if 0xE0 <= low <= 0xEF:
            self.disk_ii.append(a)
        if low == 0x7E:
            if write:
                self.card.write_reg(v)
            return 0
        if low == 0x00 and not write:
            return (self.keys[0] | 0x80) if self.keys else 0
        if low == 0x10 and self.keys:
            self.keys.popleft()
        if low == 0x19:
            return 0x80 if self.cycles % FRAME < VISIBLE else 0x00
        return 0

    def lc_slot(self, a):
        side = 'a' if self.s['altzp'] else 'm'
        if a < 0xE000:
            return self.lc[(side, self.bank)], a - 0xD000
        return self.hi[side], a - 0xE000

    def read(self, a):
        if 0xC000 <= a < 0xC100:
            return self.io(a, False, 0)
        if 0xC100 <= a < 0xC800:
            # Only the SSC has firmware; an empty slot reads as a floating bus.
            if a >> 8 == 0xC0 + self.ssc.slot:
                return SSC_SIGNATURE.get(a & 0xFF, 0)
            return (self.cycles * 7 + a) & 0xFF
        if a >= 0xD000:
            if self.lc_read:
                memory, i = self.lc_slot(a)
                return memory[i]
            return 0x60                                 # ROM: entry points are stepped over as RTS
        return self.card.read(a) if self.aux(a, False) else self.main[a]

    def write(self, a, v):
        if 0xC000 <= a < 0xC100:
            self.io(a, True, v)
        elif 0xC100 <= a < 0xD000:
            pass
        elif a >= 0xD000:
            if self.lc_write:
                memory, i = self.lc_slot(a)
                memory[i] = v
        elif self.aux(a, True):
            self.card.write(a, v)
        else:
            self.main[a] = v

    def screen(self):
        """The 80-column text screen: even columns from aux (Z80) RAM, odd from main."""
        rows = []
        for r in range(24):
            base = 0x400 + (r & 7) * 0x80 + (r >> 3) * 0x28
            line = ''
            for c in range(40):
                for b in (self.card.ram[base + c], self.main[base + c]):
                    b &= 0x7F
                    line += chr(b + 0x40 if b < 0x20 else b) if b != 0x7F else ' '
            rows.append(line.rstrip())
        return rows


class Memory:
    def __init__(self, bus):
        self.bus = bus

    def __getitem__(self, a):
        if isinstance(a, slice):
            return [self.bus.read(i & 0xFFFF) for i in range(*a.indices(0x10000))]
        return self.bus.read(a & 0xFFFF)

    def __setitem__(self, a, v):
        self.bus.write(a & 0xFFFF, v)

    def __len__(self):
        return 0x10000


class Machine:
    """A IIe at the monitor prompt with the card in the aux slot and an SSC in `slot`."""
    def __init__(self, slot=2):
        self.card = Card()
        self.ssc = SSC(slot)
        self.bus = IIe(self.card, self.ssc)
        self.cpu = MPU(memory=Memory(self.bus), pc=0xFF69)
        self.hooks = {}

    def rts(self):
        cpu = self.cpu
        lo = self.bus.read(0x100 + ((cpu.sp + 1) & 0xFF))
        hi = self.bus.read(0x100 + ((cpu.sp + 2) & 0xFF))
        cpu.sp = (cpu.sp + 2) & 0xFF
        cpu.pc = ((hi << 8) | lo) + 1

    def step(self):
        cpu, bus = self.cpu, self.bus
        pc = cpu.pc
        hook = self.hooks.get(pc)
        if hook and hook(self):
            return
        rom = pc >= 0xD000 and not bus.lc_read
        if rom or 0xC100 <= pc < 0xD000:
            if pc == 0xFF4A:                             # monitor SAVE, used by the 6502 runtime
                for i, v in enumerate((cpu.a, cpu.x, cpu.y, cpu.p, cpu.sp)):
                    bus.write(0x45 + i, v)
            self.rts()
            bus.cycles += 6
            return
        before = cpu.processorCycles
        cpu.step()
        spent = cpu.processorCycles - before
        bus.cycles += spent
        self.card.clock(spent)

    def run(self, steps, until=None):
        for _ in range(steps):
            self.step()
            if until is not None and until(self):
                return True
        return False

    def type(self, text):
        self.bus.keys.extend(text.encode('ascii'))
