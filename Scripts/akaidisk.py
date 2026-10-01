#!/usr/bin/env python3
"""Reference implementation of the Akai S1000/S3000 floppy format, used to
build the test fixtures. The Swift code in FloppyBlasterCore follows the same
rules, and the tests check that both produce byte-identical disks.

Layout of a 1,638,400-byte (1600 x 1 KB block) high-density Akai floppy:
  0x0000  64 x 24-byte directory entries (S1000) / placeholder entries (S3000)
  0x0600  block table: 1600 x 2 bytes. 0 = free, 0x4000 = system,
          0xC000 = last block of a file, otherwise the next block number.
  0x1280  volume label (12 Akai characters) and volume parameters
  0x1400  512 x 24-byte directory entries (S3000 layout only)
Files start at block 5 (S1000) or 17 (S3000).

Directory entry: name[12], tags[4], type, size[3] LE, start block[2] LE, os[2].
"""
import struct, sys

CHARS = "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ#+-."
BLOCK = 1024
BLOCKS = 1600
SIZE = BLOCK * BLOCKS

def encode_name(s):
    s = s.upper()
    out = [CHARS.index(c) if c in CHARS else 10 for c in s[:12]]
    return bytes(out + [10] * (12 - len(out)))

def decode_name(b):
    return ''.join(CHARS[c] if c < len(CHARS) else '?' for c in b).rstrip()

MULTI_FILE = encode_name("MULTI FILE")

def blank_s3000():
    img = bytearray(SIZE)
    for i in range(64):
        img[i*24:i*24+24] = MULTI_FILE + bytes([0, 0, 4, 0x0a, 0xff if i == 0 else 0, 0, 0, 4, 0, 0, 0, 0x11])
    for i in range(17):
        img[0x600+2*i:0x602+2*i] = b'\x00\x40'
    img[0x1280:0x1280+26] = encode_name("NOT NAMED") + bytes([0, 0, 0, 0x11, 0, 0, 1, 0, 0, 0, 0x32, 0x09, 0x0c, 0])
    return img

def blank_s1000():
    """S1000 layout, as an S1000 (OS 9.30) formats it."""
    img = bytearray(SIZE)
    for i in range(64):
        img[i*24:i*24+24] = empty_entry(False, bytes([0x1e, 0x09]))
    for i in range(5):
        img[0x600+2*i:0x602+2*i] = b'\x00\x40'
    img[0x1280:0x1280+16] = encode_name("NOT NAMED") + bytes([0, 0, 0x1e, 0x09])
    return img

def empty_entry(s3000, os):
    if s3000:
        return bytes(24)
    return bytes([10] * 12 + [0x20] * 4 + [0] * 6) + os

class Disk:
    def __init__(self, img):
        self.img = bytearray(img)
        fat = self.fat()
        self.reserved = sum(1 for x in fat if x == 0x4000)
        self.s3000 = self.reserved == 17
        self.base, self.capacity = (0x1400, 512) if self.s3000 else (0, 64)

    def fat(self):
        return [struct.unpack_from('<H', self.img, 0x600 + 2*i)[0] for i in range(BLOCKS)]

    def set_fat(self, i, v):
        struct.pack_into('<H', self.img, 0x600 + 2*i, v)

    @property
    def os(self):
        return bytes(self.img[0x128e:0x1290])

    def entries(self):
        out = []
        for i in range(self.capacity):
            e = self.img[self.base+i*24:self.base+i*24+24]
            if e[16] == 0:
                break
            out.append(dict(name=decode_name(e[:12]), type=e[16],
                            size=e[17] | e[18] << 8 | e[19] << 16,
                            start=e[20] | e[21] << 8))
        return out

    def read(self, f):
        fat = self.fat()
        out, blk = bytearray(), f['start']
        while len(out) < f['size']:
            out += self.img[blk*BLOCK:(blk+1)*BLOCK]
            nxt = fat[blk]
            if nxt == 0xC000:
                break
            blk = nxt
        return bytes(out[:f['size']])

    def add(self, name, ftype, data):
        count = len(self.entries())
        assert count < self.capacity, "directory full"
        fat = self.fat()
        need = max(1, -(-len(data) // BLOCK))
        free = [b for b in range(BLOCKS) if fat[b] == 0][:need]
        assert len(free) == need, "disk full"
        for i, b in enumerate(free):
            chunk = data[i*BLOCK:(i+1)*BLOCK]
            self.img[b*BLOCK:(b+1)*BLOCK] = chunk + bytes(BLOCK - len(chunk))
            self.set_fat(b, free[i+1] if i + 1 < need else 0xC000)
        tags = bytes([0, 0, 4, 0x0a]) if self.s3000 else bytes([0x20] * 4)
        entry = encode_name(name) + tags + bytes([ftype]) + struct.pack('<I', len(data))[:3] + struct.pack('<H', free[0]) + self.os
        self.img[self.base+count*24:self.base+count*24+24] = entry

    def add_sample(self, name, pcm, rate):
        n = len(pcm)
        hl = 192 if self.s3000 else 150
        h = bytearray(hl)
        h[0] = 3; h[1] = 1 if rate == 44100 else 0; h[2] = 60
        h[3:15] = encode_name(name); h[15] = 0x80; h[19] = 2
        struct.pack_into('<I', h, 26, n)
        struct.pack_into('<I', h, 34, max(n - 1, 0))
        h[136] = 0xff; h[137] = 0xff
        struct.pack_into('<H', h, 138, rate)
        self.add(name, 0xF3 if self.s3000 else 0x73, bytes(h) + struct.pack('<%dh' % n, *pcm))

    def delete(self, index):
        es = self.entries()
        f = es[index]
        fat = self.fat()
        blk = f['start']
        while True:
            nxt = fat[blk]
            self.set_fat(blk, 0)
            if nxt == 0xC000 or nxt == 0:
                break
            blk = nxt
        count = len(es)
        b = self.base
        self.img[b+index*24:b+(count-1)*24] = self.img[b+(index+1)*24:b+count*24]
        self.img[b+(count-1)*24:b+count*24] = empty_entry(self.s3000, self.os)

def sine(n, freq, rate, amp=12000):
    import math
    return [int(round(amp * math.sin(2 * math.pi * freq * i / rate))) for i in range(n)]

def make_fixtures(folder):
    import os
    s3 = Disk(blank_s3000())
    open(os.path.join(folder, 'blank-s3000.img'), 'wb').write(s3.img)
    s3.add_sample("SINE 440", sine(3000, 440, 44100), 44100)
    s3.add("TEST PROGRAM", 0xF0, bytes(range(256)) * 3)
    s3.add_sample("LOW 220", sine(1500, 220, 22050), 22050)
    open(os.path.join(folder, 's3000-fixture.img'), 'wb').write(s3.img)

    s1 = Disk(blank_s1000())
    s1.add_sample("SINE 440", sine(3000, 440, 44100), 44100)
    s1.add("TEST PROGRAM", 0x70, bytes(range(256)) * 3)
    s1.add_sample("LOW 220", sine(1500, 220, 22050), 22050)
    s1.add_sample("DELETE ME", sine(100, 1000, 44100), 44100)
    s1.delete(3)
    open(os.path.join(folder, 's1000-fixture.img'), 'wb').write(s1.img)

if __name__ == '__main__':
    make_fixtures(sys.argv[1] if len(sys.argv) > 1 else '.')
