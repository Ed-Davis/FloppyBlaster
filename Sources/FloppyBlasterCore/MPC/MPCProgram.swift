import Foundation

// MPC2000XL program (.PGM) and "all programs and sounds" (.APS) files.
//
// Layouts were worked out from files saved by an MPC2000XL (the Anthology
// CYM1.PGM in the tests) and cross-checked against the open-source VMPC2000XL
// emulator's description of the formats. Bytes whose meaning isn't known are
// written exactly as the MPC writes them for a fresh program; the tests
// rebuild CYM1.PGM byte for byte.
//
// A program has 64 note slots (MIDI notes 35-98), each pointing at a sound,
// and 64 pads, each playing a note. Programs and APS files store sound
// *names*; the MPC loads the matching NAME.SND files from the same folder.

public enum MPCFormatError: LocalizedError, Equatable {
    case notAProgram, notAnAPS, tooManySounds(Int), tooManyPrograms(Int), truncated

    public var errorDescription: String? {
        switch self {
        case .notAProgram: return "This isn't an MPC2000XL program (.PGM) file."
        case .notAnAPS: return "This isn't an MPC2000XL .APS file."
        case .tooManySounds(let n): return "A program can use at most 64 sounds (this has \(n))."
        case .tooManyPrograms(let n): return "An APS file holds at most 24 programs (this has \(n))."
        case .truncated: return "The file is shorter than its contents say."
        }
    }
}

public struct MPCProgram: Equatable {
    static let firstNote = 35
    static let noteCount = 64
    static let noteBytes = 25
    public static let maxSounds = 64

    /// The MPC2000XL's standard pad layout: pad A01, A02 … D16 → MIDI note.
    static let defaultPadNotes: [UInt8] = [
        37, 36, 42, 82, 40, 38, 46, 44, 48, 47, 45, 43, 49, 55, 51, 53,
        54, 69, 81, 80, 65, 66, 76, 77, 56, 62, 63, 64, 73, 74, 71, 39,
        52, 57, 58, 59, 60, 61, 67, 68, 70, 72, 75, 78, 79, 35, 41, 50,
        83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98,
    ]

    /// Pad names in order: A01 … D16.
    public static let padNames: [String] = (0..<64).map { i in
        "\(["A", "B", "C", "D"][i / 16])\(String(format: "%02d", i % 16 + 1))"
    }

    // Constant parts, as an MPC2000XL writes them for a new program.
    static let headerAfterSounds: [UInt8] = [0x1E, 0x00]
    static let defaultSlider: [UInt8] = [0x00, 0x88, 0x78, 0x0C, 0x2D, 0x00, 0x14, 0xCE, 0x32]
    static let afterProgramChange: [UInt8] = [0x23, 0x40, 0x00, 0x19, 0x00]
    /// A note slot's settings after its sound byte (velocity 44-88 range, decay 5, cutoff 100…).
    static let defaultNoteSettings: [UInt8] = [0x00, 0x2C, 0x00, 0x58, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                               0x05, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00]
    static let afterNotes: [UInt8] = [0x06]
    static let defaultPadMixer: [UInt8] = [0x00, 0x64, 0x32, 0x64, 0x00, 0x00]
    static let afterMixers: [UInt8] = [0x00, 0x40, 0x00]
    static let trailer: [UInt8] = hex("""
        02004800d0070000630114081dfc323302323c08050a1414320000020f19000541141e01050000056300f4ff0c000000\
        0000000002004f014f0100424f0100424f01004232006328003c0000d0070000630114081dfc323302323c08050a14\
        14320000020f19000541141e01050000056300f4ff0c0000000000000002004f014f0100424f0100424f010042320063\
        28003c000004000c000000320023003e335a3214000000320023003e335a3214000000320023003e335a321400000032\
        0023003e335a321400
        """)

    public var name: String
    public var soundNames: [String]
    var slider: [UInt8] = MPCProgram.defaultSlider
    var programChange: UInt8 = 0
    /// Per note slot (note 35 + i): the sound byte, then 24 settings bytes.
    var notes: [[UInt8]]
    var padMixers: [[UInt8]]
    var padNotes: [UInt8]
    var trailer: [UInt8] = MPCProgram.trailer

    /// A new program playing `sounds` on pads A01, A02 … in order (up to 64).
    init(name: String, sounds: [String]) throws {
        guard sounds.count <= Self.maxSounds else { throw MPCFormatError.tooManySounds(sounds.count) }
        self.name = name
        soundNames = sounds
        padNotes = Self.defaultPadNotes
        padMixers = Array(repeating: Self.defaultPadMixer, count: 64)
        notes = Array(repeating: [0xFF] + Self.defaultNoteSettings, count: Self.noteCount)
        for (i, _) in sounds.enumerated() {
            notes[Int(padNotes[i]) - Self.firstNote][0] = UInt8(i)
        }
    }

    /// The sound each pad plays, A01 … D16 (nil = nothing).
    public var padSounds: [String?] {
        padNotes.map { note in
            let slot = Int(note) - Self.firstNote
            guard notes.indices.contains(slot) else { return nil }
            let s = Int(notes[slot][0])
            return soundNames.indices.contains(s) ? soundNames[s] : nil
        }
    }

    // MARK: Reading and writing

    init(data: Data) throws {
        var r = Reader(data)
        guard try r.bytes(2) == [0x07, 0x04] else { throw MPCFormatError.notAProgram }
        let count = try r.u16()
        soundNames = try (0..<count).map { _ in try r.name() }
        _ = try r.bytes(2)
        name = try r.name()
        slider = try r.bytes(9)
        programChange = try r.u8()
        _ = try r.bytes(5)
        notes = try (0..<Self.noteCount).map { _ in try r.bytes(Self.noteBytes) }
        _ = try r.bytes(1)
        padMixers = try (0..<64).map { _ in try r.bytes(6) }
        _ = try r.bytes(3)
        padNotes = try r.bytes(64)
        trailer = try r.bytes(200)
    }

    var data: Data {
        var b: [UInt8] = [0x07, 0x04] + Self.u16(soundNames.count)
        for s in soundNames { b += Self.name17(s) }
        b += Self.headerAfterSounds + Self.name17(name) + slider + [programChange] + Self.afterProgramChange
        for n in notes { b += n }
        b += Self.afterNotes
        for m in padMixers { b += m }
        b += Self.afterMixers + padNotes + trailer
        return Data(b)
    }

    // MARK: Helpers

    /// Names are 16 characters, space padded, then a zero byte.
    static func name17(_ s: String) -> [UInt8] {
        let ascii = Array(s.unicodeScalars.prefix(16).map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "_") })
        return ascii + [UInt8](repeating: 0x20, count: 16 - ascii.count) + [0]
    }

    static func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }

    static func hex(_ s: String) -> [UInt8] {
        let chars = Array(s.filter { !$0.isWhitespace })
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
    }

    struct Reader {
        let b: [UInt8]
        var o = 0
        init(_ d: Data) { b = [UInt8](d) }
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard o + n <= b.count else { throw MPCFormatError.truncated }
            defer { o += n }
            return Array(b[o..<o + n])
        }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> Int { let x = try bytes(2); return Int(x[0]) | Int(x[1]) << 8 }
        mutating func name() throws -> String {
            String(decoding: try bytes(17).prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        var atEnd: Bool { o >= b.count }
    }
}

/// An "all programs and sounds" file: up to 24 programs sharing one sound list.
enum MPCAllProgramsFile {
    static let maxPrograms = 24

    static let afterSounds: [UInt8] = [0x18, 0x00]
    static let globals: [UInt8] = [0x03, 0x38, 0x00, 0xA1, 0x00, 0x00, 0x00]
    static let afterGlobals: [UInt8] = [0x40]
    static let afterMasterPads: [UInt8] = [0x04, 0x00, 0x88, 0x01, 0x40, 0x00, 0x06]
    static let betweenDrums: [UInt8] = [0x7F, 0x40, 0x00, 0x06]
    static let afterDrums: [UInt8] = [0x7F]
    static let programPrefix: [UInt8] = [0x00, 0x07, 0x04, 0x1E, 0x00]
    static let programAfterProgramChange: [UInt8] = [0x23, 0x40, 0x00, 0x1A, 0x00]
    static let end: [UInt8] = [0xFF]

    /// Builds an APS from programs. Their sounds are merged into one list
    /// (by name), and each program's notes are pointed at that list.
    static func data(name: String, programs: [MPCProgram]) throws -> Data {
        guard programs.count <= maxPrograms else { throw MPCFormatError.tooManyPrograms(programs.count) }
        var sounds: [String] = []
        for p in programs {
            for s in p.soundNames where !sounds.contains(where: { $0.uppercased() == s.uppercased() }) { sounds.append(s) }
        }
        var b: [UInt8] = [0x0A, 0x05] + MPCProgram.u16(sounds.count)
        for s in sounds { b += MPCProgram.name17(s) }
        b += afterSounds + MPCProgram.name17(name) + globals + afterGlobals
        b += (0..<64).map { UInt8(MPCProgram.firstNote + $0) }   // master pad → note map
        b += afterMasterPads
        for drum in 0..<4 {
            for _ in 0..<64 { b += MPCProgram.defaultPadMixer }
            // receive program change / MIDI volume on, program 1, duplicates on
            b += [0x00, 0x00, 0x01, 0x01, 0x7F, 0x00, 0x01, 0x01]
            b += drum < 3 ? betweenDrums : afterDrums
        }
        for (index, p) in programs.enumerated() {
            b += [UInt8(index)] + programPrefix + MPCProgram.name17(p.name) + p.slider + [p.programChange]
            b += programAfterProgramChange
            for note in p.notes {
                let local = Int(note[0])
                let global: Int
                if p.soundNames.indices.contains(local) {
                    let soundName = p.soundNames[local].uppercased()
                    global = sounds.firstIndex { $0.uppercased() == soundName } ?? 0xFFFF
                } else {
                    global = 0xFFFF
                }
                b += MPCProgram.u16(global) + note.dropFirst()
            }
            b += MPCProgram.afterNotes
            for m in p.padMixers { b += m }
            b += MPCProgram.afterMixers + p.padNotes + p.trailer
        }
        b += end
        return Data(b)
    }

    /// The program and sound names in an APS (for checks and tests).
    static func contents(of data: Data) throws -> (name: String, sounds: [String], programs: [String]) {
        var r = MPCProgram.Reader(data)
        guard try r.bytes(2) == [0x0A, 0x05] else { throw MPCFormatError.notAnAPS }
        let count = try r.u16()
        let sounds = try (0..<count).map { _ in try r.name() }
        _ = try r.bytes(2)
        let name = try r.name()
        _ = try r.bytes(7 + 1 + 64 + 7)
        for drum in 0..<4 { _ = try r.bytes(64 * 6 + 8 + (drum < 3 ? 4 : 1)) }
        var programs: [String] = []
        while !r.atEnd {
            let index = try r.u8()
            if index > 23 { break }
            _ = try r.bytes(5)
            programs.append(try r.name())
            _ = try r.bytes(9 + 1 + 5 + 64 * 26 + 1 + 64 * 6 + 3 + 64 + 200)
        }
        return (name, sounds, programs)
    }
}

// MARK: - Writing .SND files

extension MPCSound {
    /// An MPC2000XL .SND file: 42-byte header then 16-bit PCM (for stereo,
    /// the whole left channel then the whole right).
    static func fileData(name: String, channels: [[Int16]], sampleRate: Int = 44_100) -> Data {
        let frames = channels.first?.count ?? 0
        var h = [UInt8](repeating: 0, count: headerSize)
        h[0] = 0x01
        h[1] = 0x04
        let n = Array(MPCProgram.name17(name).prefix(16))
        h.replaceSubrange(2..<18, with: n)
        h[19] = 100                                 // level
        h[21] = channels.count > 1 ? 1 : 0          // stereo
        func put32(_ o: Int, _ v: Int) { for i in 0..<4 { h[o + i] = UInt8(v >> (8 * i) & 0xFF) } }
        put32(22, 0)                                // start
        put32(26, frames)                           // loop end
        put32(30, frames)                           // end
        put32(34, 0)                                // loop length
        h[38] = 0                                   // loop off
        h[39] = 4                                   // beats
        h[40] = UInt8(sampleRate & 0xFF)
        h[41] = UInt8(sampleRate >> 8 & 0xFF)
        var out = Data(h)
        out.reserveCapacity(headerSize + frames * 2 * channels.count)
        for channel in channels.prefix(2) {
            for v in channel {
                let u = UInt16(bitPattern: v)
                out.append(UInt8(u & 0xFF))
                out.append(UInt8(u >> 8))
            }
        }
        return out
    }

    /// Sound memory a .SND takes on the MPC (its audio, not the header).
    static func memoryBytes(fileSize: Int) -> Int { max(0, fileSize - headerSize) }
}

/// The MPC2000XL's sample memory options.
public enum MPCMemory: Int, CaseIterable, Identifiable {
    case standard = 2, mb16 = 16, mb32 = 32
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .standard: return "2 MB (standard)"
        case .mb16: return "16 MB"
        case .mb32: return "32 MB (maximum)"
        }
    }
    /// Usable sound memory: the installed size less about 3% for the
    /// MPC's own use. Sequences have their own memory, so nothing is set
    /// aside for them.
    public var usableBytes: Int { rawValue * 1_048_576 * 97 / 100 }
}
