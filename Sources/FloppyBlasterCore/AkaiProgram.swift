import Foundation

/// Akai S1000/S3000 programs: making a "one sample per key" program from
/// samples on a disk, and reading a program's keygroups back.
///
/// A program file is a program header followed by one keygroup header per
/// keygroup, all the same length: 150 bytes for S1000-family programs (type
/// 0x70), 192 for S3000-family ones (0xF0).
///
/// Program header: 0 PRIDENT (1), 1–2 KGRP1@, 3–14 name, 15 PRGNUM,
/// 16 PMCHAN, 42 GROUPS (number of keygroups).
///
/// Keygroup: 0 KGIDENT (2), 1–2 NXTKG@, 3 LONOTE, 4 HINOTE, 5–6 KGTUNO,
/// 34… four velocity zones of 24 bytes (name[12], LOVEL, HIVEL, VTUNO[2],
/// VLOUD, VFREQ, VPANO, ZPLAY, 4 internal bytes), 132–135 CP1–CP4 (1 =
/// "constant pitch": the zone plays at its recorded pitch on every key).
///
/// The `@` fields are addresses in the sampler's memory when the program was
/// saved; samplers rebuild them on loading (factory disks are full of stale
/// ones), so new programs just number them in order the way an S1000 does.
///
/// Everything else comes from programs on Akai's own factory disks, so new
/// programs get the same filter, envelope and output settings: an S1000 drum
/// kit (WS2 DRUMS, Workstation 2 Funk) and an S3000 one (AMB KICK+SN1,
/// SL3007 Ambience Kit).
public enum AkaiProgram {
    /// MIDI note of the first key used: C1 on an Akai (middle C, 60, is C3).
    public static let firstNote = 36
    /// C1 to G8 (MIDI 127): the most one-key-per-sample keygroups that fit.
    public static let maxKeys = 128 - firstNote

    public enum ProgramError: LocalizedError, Equatable {
        case noSamples
        case tooManyKeys(Int)
        case notAProgram

        public var errorDescription: String? {
            switch self {
            case .noSamples: return "Choose some samples first."
            case .tooManyKeys(let n):
                return "That's \(n) keys; a program can use at most \(AkaiProgram.maxKeys) (C1 to G8, one per key)."
            case .notAProgram: return "This isn't an Akai program."
            }
        }
    }

    /// One key of a new program: one sample, or a stereo pair (-L, -R).
    public struct Key: Equatable, Hashable, Identifiable {
        public var samples: [String]
        public init(samples: [String]) { self.samples = samples }
        public var id: String { samples.joined(separator: "|") }
        /// "KICK" for a mono sample, "PAD -L/-R" for a stereo pair.
        public var label: String {
            guard samples.count == 2 else { return samples.first ?? "" }
            return samples[0].dropLast(2).trimmingCharacters(in: .whitespaces) + " -L/-R"
        }
    }

    /// Groups sample names into keys. A "… -L" sample followed by its "… -R"
    /// partner (how stereo files are stored) shares one key, panned left
    /// and right; everything else gets a key of its own.
    public static func keys(for sampleNames: [String]) -> [Key] {
        var out: [Key] = []
        var i = 0
        while i < sampleNames.count {
            let name = sampleNames[i]
            if i + 1 < sampleNames.count, name.hasSuffix("-L"),
               sampleNames[i + 1] == String(name.dropLast(2)) + "-R" {
                out.append(Key(samples: [name, sampleNames[i + 1]]))
                i += 2
            } else {
                out.append(Key(samples: [name]))
                i += 1
            }
        }
        return out
    }

    /// "C1", "C#1" … in Akai's numbering (MIDI 36 = C1, 60 = C3).
    public static func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((midi % 12) + 12) % 12] + String(midi / 12 - 2)
    }

    public static func fileType(for layout: AkaiDisk.Layout) -> UInt8 { layout == .s3000 ? 0xF0 : 0x70 }

    public static func headerLength(for layout: AkaiDisk.Layout) -> Int { layout == .s3000 ? 192 : 150 }

    /// A program playing each key's sample(s) on its own note, from C1 up,
    /// at the pitch it was recorded.
    public static func fileData(name: String, programNumber: Int, keys: [Key], layout: AkaiDisk.Layout) throws -> Data {
        guard !keys.isEmpty else { throw ProgramError.noSamples }
        guard keys.count <= maxKeys else { throw ProgramError.tooManyKeys(keys.count) }
        let size = headerLength(for: layout)
        let base = layout == .s3000 ? 0x600C : 150
        let step = layout == .s3000 ? 12 : 150
        func pointer(_ k: Int) -> [UInt8] {
            let v = base + step * k
            return [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]
        }

        var header = layout == .s3000 ? s3000Header : s1000Header
        header.replaceSubrange(1...2, with: pointer(0))
        header.replaceSubrange(3..<15, with: AkaiCharset.encode(name))
        header[15] = UInt8(clamping: programNumber)
        header[16] = 0        // MIDI channel 1
        header[42] = UInt8(keys.count)

        var out = header
        let template = layout == .s3000 ? s3000Keygroup : s1000Keygroup
        let internalBytes = Array(template[54..<58])
        for (k, key) in keys.enumerated() {
            var kg = template
            let note = UInt8(firstNote + k)
            kg.replaceSubrange(1...2, with: pointer(k + 1))
            kg[3] = note
            kg[4] = note
            kg[5] = 0
            kg[6] = 0
            for z in 0..<4 {
                let o = 34 + 24 * z
                if z < key.samples.count {
                    let pan: Int8 = key.samples.count == 2 ? (z == 0 ? -50 : 50) : 0
                    kg.replaceSubrange(o..<o + 12, with: AkaiCharset.encode(key.samples[z]))
                    kg.replaceSubrange(o + 12..<o + 24,
                                       with: [0, 127, 0, 0, 0, 0, UInt8(bitPattern: pan), 0] + internalBytes)
                    kg[132 + z] = 1
                } else {
                    kg.replaceSubrange(o..<o + 24, with: emptyZone)
                    kg[132 + z] = 0
                }
            }
            precondition(kg.count == size)
            out += kg
        }
        return Data(out)
    }

    // MARK: Reading

    public struct Keygroup: Equatable {
        public var lowNote: Int
        public var highNote: Int
        public var samples: [String]
        public var constantPitch: [Bool]
    }

    public struct Contents: Equatable {
        public var name: String
        public var programNumber: Int
        public var keygroups: [Keygroup]
    }

    /// Reads a program file. `type` is its directory type byte (0x70 or 0xF0).
    public static func contents(of data: Data, type: UInt8) throws -> Contents {
        let b = [UInt8](data)
        let size = type & 0x80 != 0 ? 192 : 150
        guard b.count >= size, b[0] == 1 else { throw ProgramError.notAProgram }
        let groups = Int(b[42])
        var keygroups: [Keygroup] = []
        for k in 0..<groups {
            let o = size * (k + 1)
            guard o + size <= b.count, b[o] == 2 else { break }
            var names: [String] = []
            var constant: [Bool] = []
            for z in 0..<4 {
                let zone = o + 34 + 24 * z
                let name = AkaiCharset.decode(b[zone..<zone + 12])
                if !name.isEmpty {
                    names.append(name)
                    constant.append(b[o + 132 + z] != 0)
                }
            }
            keygroups.append(Keygroup(lowNote: Int(b[o + 3]), highNote: Int(b[o + 4]),
                                      samples: names, constantPitch: constant))
        }
        return Contents(name: AkaiCharset.decode(b[3..<15]), programNumber: Int(b[15]), keygroups: keygroups)
    }

    // MARK: Templates (from Akai factory disks)

    static let emptyZone: [UInt8] = [UInt8](repeating: 10, count: 12) + [0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]

    static let s1000Header = bytes("""
        019600211d020a0e1c1f171d0a0a0a00000f01187f000463005a140000320032004100321e00000700000400000000000000\
        00000000000000000000000000000000000000000100000000000000000000020000187f00006300000000001e633c000000\
        001e321e3c0000000000000104ffff1d13180f0a0a0a0a0a0a0a0a007f000000000000ffff00001d1b1f0b1c0f0a0a0a0a0a
        """)

    static let s1000Keygroup = bytes("""
        022c012424000063000000000041003c000000000032003c0000000000000104ffff101f18150a15130d150a0a0a007f9aff\
        0a000000fffff8431d1b1f0b1c0f0a0a0a0a0a0a0100000000000000ffffffff1d0b211e19191e120a0a0a0a010000000000\
        0000ffffffff1a1f161d0f0a0a0a0a0a0a0a0100000000000000ffffffff0000010000000000000000000000000000000017
        """)

    static let s3000Header = bytes("""
        010c900b170c0a15130d15261d1801000f1f01187f00ff5f005a1400001000320041003209000007000003000000000000\
        000000000000000000010000000a0a020000000000000000070000060801060306060605030a0a0500190000000000000000\
        13180f0a0a0a0a0a0a0a0a007f000000000000ffff00001d1b1f0b1c0f0a0a0a0a0a0a0100000000000000ffff00001d0b21\
        1e000000000000000000000000000000000000000000000000000000000000000000000000000000000000
        """)

    static let s3000Keygroup = bytes("""
        021890232400005c001e003200630046000f00000040003c0a00000032000104ffff1712260b1715130d15010a0a007f0000\
        00000000ffff38940a0a0a0a0a0a0a0a0a0a0a0a0000000000000000ffffffff0a0a0a0a0a0a0a0a0a0a0a0a000000000000\
        0000ffffffff0a0a0a0a0a0a0a0a0a0a0a0a0000000000000000ffffffff000001000000000000000000000000000000000032\
        1e00320000630063000000000000000000000000000000000000000000000000000000000000000000
        """)

    private static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.filter(\.isHexDigit))
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
    }
}
