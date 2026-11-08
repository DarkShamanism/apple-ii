"""Cassette tape import/download for the launcher; standard library only.

Produces a playable file in the tape cache and a result.json describing it.
Never plays audio, opens a serial port or contacts any host except the given URL.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / 'VERSION').read_text().strip()
BUILD = ROOT / 'build' / VERSION
MAX_BYTES = 64 * 1024 * 1024
CHUNK = 64 * 1024
PCM_GUID = bytes.fromhex('0100000000001000800000aa00389b71')


class TapeError(ValueError):
    pass


def sniff(data):
    if data[:4] == b'RIFF' and data[8:12] == b'WAVE':
        return 'WAV'
    if data[:4] == b'FORM' and data[8:12] in (b'AIFF', b'AIFC'):
        return 'AIFF'
    if data[:3] == b'ID3' or (len(data) > 1 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0):
        return 'MP3'
    raise TapeError('Not a WAV, AIFF or MP3 file')


def chunks(data, start, big_endian):
    """Yield (id, body) for each IFF/RIFF chunk; bodies are padded to even length."""
    order = '>I' if big_endian else '<I'
    offset = start
    while offset + 8 <= len(data):
        cid = data[offset:offset + 4]
        size = struct.unpack_from(order, data, offset + 4)[0]
        body = data[offset + 8:offset + 8 + size]
        if len(body) != size:
            raise TapeError(f'Truncated {cid.decode("latin-1")} chunk')
        yield cid, body
        offset += 8 + size + (size & 1)


def check_pcm(channels, rate, bits):
    if not 1 <= channels <= 2:
        raise TapeError('Cassette audio must be mono or stereo')
    if not 4000 <= rate <= 192000:
        raise TapeError(f'Unsupported sample rate {rate}')
    if bits not in (8, 16, 24, 32):
        raise TapeError(f'Unsupported sample size {bits} bits')


def wav_info(data):
    fmt = samples = None
    for cid, body in chunks(data, 12, False):
        if cid == b'fmt ' and len(body) >= 16:
            fmt = body
        elif cid == b'data':
            samples = body
    if fmt is None or samples is None:
        raise TapeError('WAV file has no fmt/data chunk')
    tag, channels, rate, _, align, bits = struct.unpack_from('<HHIIHH', fmt)
    if tag == 0xFFFE and len(fmt) >= 40 and fmt[24:40] == PCM_GUID:
        tag = 1
    if tag != 1:
        raise TapeError('WAV must be uncompressed PCM')
    check_pcm(channels, rate, bits)
    if align != channels * ((bits + 7) // 8):
        raise TapeError('WAV block alignment does not match its format')
    return dict(channels=channels, rate=rate, bits=bits, seconds=round(len(samples) / align / rate, 2))


def extended(raw):
    """Decode an 80-bit IEEE 754 extended float (AIFF sample rate)."""
    exponent = ((raw[0] & 0x7F) << 8) | raw[1]
    mantissa = int.from_bytes(raw[2:10], 'big')
    if exponent == 0 and mantissa == 0:
        return 0.0
    value = mantissa * 2.0 ** (exponent - 16383 - 63)
    return -value if raw[0] & 0x80 else value


def aiff_to_wav(data):
    """Convert uncompressed AIFF/AIFC to WAV without altering sample values."""
    aifc = data[8:12] == b'AIFC'
    comm = ssnd = None
    for cid, body in chunks(data, 12, True):
        if cid == b'COMM':
            comm = body
        elif cid == b'SSND':
            ssnd = body
    if comm is None or ssnd is None or len(comm) < 18 or len(ssnd) < 8:
        raise TapeError('AIFF file has no COMM/SSND chunk')
    channels, frames, bits = struct.unpack_from('>hIh', comm)
    rate = extended(comm[8:18])
    little = False
    if aifc:
        kind = comm[18:22]
        if kind == b'sowt':
            little = True
        elif kind not in (b'NONE', b'twos'):
            raise TapeError('Compressed AIFC audio is not supported')
    if rate != int(rate):
        raise TapeError('AIFF sample rate must be a whole number')
    rate = int(rate)
    check_pcm(channels, rate, bits)
    width = (bits + 7) // 8
    offset = struct.unpack_from('>I', ssnd)[0]
    raw = ssnd[8 + offset:8 + offset + frames * channels * width]
    if len(raw) != frames * channels * width:
        raise TapeError('AIFF sample data is shorter than its frame count')
    if width == 1:
        # AIFF 8-bit is signed; WAV 8-bit is unsigned.
        pcm = bytes((b + 128) & 0xFF for b in raw)
    elif little:
        pcm = raw
    else:
        swapped = bytearray(len(raw))
        for i in range(width):
            swapped[i::width] = raw[width - 1 - i::width]
        pcm = bytes(swapped)
    align = channels * width
    pad = b'\0' if len(pcm) & 1 else b''
    header = b'RIFF' + struct.pack('<I', 36 + len(pcm) + len(pad)) + b'WAVE'
    header += b'fmt ' + struct.pack('<IHHIIHH', 16, 1, channels, rate, rate * align, align, bits)
    wav = header + b'data' + struct.pack('<I', len(pcm)) + pcm + pad
    return wav, dict(channels=channels, rate=rate, bits=bits, seconds=round(frames / rate, 2))


def analyse(data):
    """Return (playable bytes, format, seconds, notes) for raw audio bytes."""
    kind = sniff(data)
    if kind == 'WAV':
        info = wav_info(data)
        return data, 'WAV', info['seconds'], [f"WAV {info['rate']} Hz, {info['bits']}-bit, {info['channels']} ch"]
    if kind == 'AIFF':
        wav, info = aiff_to_wav(data)
        return wav, 'WAV', info['seconds'], [f"AIFF {info['rate']} Hz, {info['bits']}-bit, {info['channels']} ch converted to WAV; samples unchanged"]
    return data, 'MP3', 0.0, ['MP3 is lossy. The c2t author warns compressed audio can fail to load; prefer WAV or AIFF.']


def check_url(url):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != 'https' or not parts.hostname:
        raise TapeError('Use an https:// link to the audio file')
    if parts.username or parts.password:
        raise TapeError('Links containing credentials are not accepted')
    return parts


def download(url, stopped, limit=MAX_BYTES, opener=urllib.request.urlopen):
    check_url(url)
    request = urllib.request.Request(url, headers={'User-Agent': f'A2MC-launcher/{VERSION}'})
    with opener(request, timeout=30) as response:
        check_url(response.geturl())
        declared = response.headers.get('Content-Length')
        if declared and declared.isdigit() and int(declared) > limit:
            raise TapeError(f'File is larger than {limit // (1024 * 1024)} MB')
        data = bytearray()
        while True:
            if stopped():
                raise InterruptedError('Download cancelled; nothing was added to the library')
            part = response.read(CHUNK)
            if not part:
                break
            data.extend(part)
            if len(data) > limit:
                raise TapeError(f'File is larger than {limit // (1024 * 1024)} MB')
    return bytes(data)


def store(play, fmt, cache):
    """Write playable bytes to the cache, named by SHA-256, without overwriting."""
    digest = hashlib.sha256(play).hexdigest()
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / f'{digest}.{fmt.lower()}'
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        temp = path.with_suffix('.tmp')
        temp.write_bytes(play)
        temp.replace(path)
    return path, digest


def title_from(name):
    stem = Path(name).stem.replace('_', ' ').strip()
    clean = ''.join(ch for ch in stem if ch.isprintable())[:80].strip()
    return clean or 'Untitled tape'


def say(text, stream=None):
    # Redirected Windows consoles may not encode every character; logs stay ASCII.
    print(text.encode('ascii', 'replace').decode('ascii'), file=stream or sys.stdout, flush=True)


def main(config):
    action = config['Action']
    out = Path(config['OutputDir']).resolve()
    cache = Path(config['CacheDir']).resolve()
    for folder in (out, cache):
        if not folder.is_relative_to(BUILD.resolve()):
            raise TapeError('Tape output must be in the current release build folder')
    out.mkdir(parents=True, exist_ok=True)
    stopped = lambda: Path(config['StopFile']).exists()
    if action == 'Fetch':
        url = config['Url']
        say(f'Downloading {url}')
        data = download(url, stopped)
        source = url
        name = urllib.parse.unquote(Path(urllib.parse.urlsplit(url).path).name) or 'download'
    elif action == 'Import':
        path = Path(config['File'])
        if not path.is_file():
            raise TapeError('Choose an existing audio file')
        if path.stat().st_size > MAX_BYTES:
            raise TapeError(f'File is larger than {MAX_BYTES // (1024 * 1024)} MB')
        data = path.read_bytes()
        source = str(path.resolve())
        name = path.name
    else:
        raise TapeError('Unknown tape action')
    play, fmt, seconds, notes = analyse(data)
    target, digest = store(play, fmt, cache)
    result = dict(title=title_from(name), file=str(target), sha256=digest, source=source, format=fmt,
                  seconds=seconds, original_sha256=hashlib.sha256(data).hexdigest(), notes=notes)
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    for note in notes:
        say(note)
    say(f'Stored {len(play)} bytes, {seconds:.2f} s: {target}')
    say(f'SHA-256 {digest}')
    say('Review the title and load command, then save it to the library.')


if __name__ == '__main__':
    try:
        main(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig')))
    except InterruptedError as error:
        say(str(error))
    except (TapeError, OSError, KeyError) as error:
        say(f'Tape tool failed: {error}', sys.stderr)
        sys.exit(1)
