# Floppy Blaster

![Floppy Blaster](Packaging/AppIcon.png)

THIS IS UNSUPPORTED. FloppyBlastr’s features are now part of Sampler Food, which is available on the Mac App Store. 

Move samples on and off Akai floppy disk images as used on the Gotek USB floppy emulator.

Floppy Blaster is MPC Blaster's sibling for floppy emulators. It works with the 1.6 MB `.img` files that a Gotek running FlashFloppy loads into an Akai S-series sampler. It's for file transfer and listening only: editing programs and sampler settings is left to [S-Control](https://github.com/Ed-Davis/S-Control).

## What it does

- **Finds your floppy images.** Plug in the Gotek's USB stick and it's found by its `FF.CFG` file, or choose any folder. Disks are listed by folder, as FlashFloppy shows them.
- **Shows what's on a disk:** names, file types, sample rates, lengths, free space and the disk's name on the sampler.
- **Plays samples.** Use the play button, double-click, or Space.
- **Adds audio.** Drop WAV, AIFF, MP3, M4A or FLAC files on a disk. They're converted to 16-bit Akai samples at 44.1 or 22.05 kHz. Stereo becomes a "NAME -L" / "NAME -R" pair (Akai's own convention) or is mixed to mono.
- **Exports** samples as WAV, or any file as a raw Akai file (`.s3`, `.p1`…; hold Option). Raw files can be added back later.
- **Renames and deletes** files, and renames the disk.
- **New Blank Disk** makes a freshly formatted S3000-format disk, numbered `001.img`, `002.img`… in the selected folder.

## Formats

| | S1000 format | S3000 format |
|---|---|---|
| Samplers | S1000, S1100, S01 | S2000, S2800, S3000, S3200 |
| Files per disk | 64 | 512 |
| Space | 1,595 KB | 1,583 KB |

Floppy Blaster detects the format itself. S900/S950 disks use a different format and aren't supported.

## Safe saving

Every change is written straight to the image. The new image goes into a hidden temporary file beside the old one and is flushed to the stick. Only then is it swapped in, so a pulled stick can't leave a half-written disk. A change that won't fit is refused before anything is written.

## How the format works

Each image is 1600 blocks of 1 KB:

```
0x0000  64 directory entries × 24 bytes (S1000)
        or "MULTI FILE" placeholders (S3000)
0x0600  block table, 2 bytes per block
        0 = free, 0x4000 = system, 0xC000 = last block of a file,
        otherwise the next block
0x1280  disk name (12 Akai characters) and settings
0x1400  512 directory entries (S3000 only)
```

A directory entry holds:

- the name (12 characters)
- 4 tag bytes
- the type: `s`/`p`/`x`… (0x73, 0x70, 0x78…), with the top bit set for S3000 files
- the size (3 bytes)
- the first block
- the OS version

A sample is a header followed by 16-bit little-endian mono audio. The header is 150 bytes for S1000 files and 192 bytes for S3000 files.

`Scripts/akaidisk.py` is a small reference implementation of the format. It was checked against disks made by real S1000, S1100, S01, S2000, S2800 and S3000 samplers. It also generates the test fixtures, and the Swift tests require the app to write byte-identical disks.

## Building

- `swift test` runs the tests.
- `./make-dmg.sh` builds `build/Floppy Blaster.app` and a test DMG. It's ad-hoc signed; set `SIGN_IDENTITY` to sign with your Developer ID.
- CI builds, tests and uploads the DMG as **FloppyBlaster-test-dmg** on every push.

```
Sources/FloppyBlasterCore/  Akai disk format, samples, audio import, saving
Sources/FloppyBlaster/      The SwiftUI app
Tests/                      Format and import tests, with generated fixture disks
Scripts/akaidisk.py         Reference implementation and fixture generator
```

© 2026 Ed Davis. Not affiliated with Akai Professional, inMusic, or the makers of FlashFloppy or Gotek.
