import XCTest
@testable import FloppyBlasterCore

@MainActor
final class MPCFloppyTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MPCFloppyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/MPC"))
    }

    private func blankFloppy(_ label: String = "") throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString.prefix(6)).img")
        try MPCFloppySession.createBlank(at: url, label: label)
        return url
    }

    private func wav(_ name: String, frames: Int, channels: UInt16 = 1) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let pcm = Data((0..<frames * Int(channels) * 2).map { UInt8($0 & 0x7F) })
        try AudioPrep.wavFile(pcm: pcm, channels: channels, sampleRate: 44_100).write(to: url)
        return url
    }

    // MARK: Formats

    func testBlankFloppyIsAStandardDOSDisk() async throws {
        let url = try blankFloppy("drums")
        XCTAssertEqual(try Data(contentsOf: url).count, 1_474_560)
        let session = try MPCFloppySession(url: url)
        XCTAssertEqual(session.formatName, "FAT12")
        XCTAssertEqual(session.label, "DRUMS")
        XCTAssertEqual(session.totalBytes, 2847 * 512)
        XCTAssertEqual(session.freeBytes, session.totalBytes)
        XCTAssertEqual(session.items, [])
        let problems = try await Shell.fsck(url)
        XCTAssertEqual(problems, [])
    }

    func testAkaiImagesAreNotMistakenForDOSOnes() throws {
        let akai = folder.appendingPathComponent("akai.img")
        try AkaiDisk.blank(.s3000).data.write(to: akai)
        XCTAssertThrowsError(try MPCFloppySession(url: akai))
        XCTAssertThrowsError(try AkaiDisk(contentsOf: try blankFloppy()))
    }

    /// CYM1.PGM was saved by an MPC2000XL.
    func testProgramsRoundTripByteForByte() throws {
        let real = try Data(contentsOf: fixture("CYM1.PGM"))
        let program = try MPCProgram(data: real)
        XCTAssertEqual(program.name, "CYM1")
        XCTAssertEqual(program.data, real)
        var fresh = try MPCProgram(name: "CYM1", sounds: program.soundNames)
        fresh.notes = program.notes
        XCTAssertEqual(fresh.data, real)
    }

    // MARK: On a floppy

    func testAddAuditionMakeProgramAndAPS() async throws {
        let url = try blankFloppy()
        let session = try MPCFloppySession(url: url)
        let added = try session.importFiles([fixture("KIK001.SND"), fixture("SN001.SND"),
                                             wav("Hand Clap.wav", frames: 4000, channels: 2)])
        XCTAssertEqual(added.added, ["KIK001.SND", "SN001.SND", "HAND_CLA.SND"])
        XCTAssertEqual(added.skipped, [])

        let clap = try XCTUnwrap(session.items.first { $0.shortName == "HAND_CLA.SND" })
        XCTAssertEqual(session.soundInfo[clap.id]?.stereo, true)
        XCTAssertEqual(try MPCSound(data: session.contents(of: clap)).frameCount, 4000, "audio became a stereo .SND")
        XCTAssertEqual(try session.audioBuffer(for: clap).frameLength, 4000)

        let order = ["KIK001.SND", "SN001.SND", "HAND_CLA.SND"].compactMap { n in session.items.first { $0.shortName == n } }
        let made = try session.makeProgram(named: "Break kit", sounds: order, memory: .standard)
        XCTAssertEqual(made.file, "BREAK_KI.PGM")
        XCTAssertEqual(made.lastPad, "A03")
        XCTAssertEqual(made.converted, 0)

        let pgm = try XCTUnwrap(session.items.first { $0.shortName == "BREAK_KI.PGM" })
        let program = try MPCProgram(data: session.contents(of: pgm))
        XCTAssertEqual(program.name, "Break kit")
        XCTAssertEqual(Array(program.padSounds.prefix(4)), ["KIK001", "SN001", "HAND_CLA", nil])

        let aps = try session.makeAPS(named: "Set one", programs: [pgm], memory: .standard)
        XCTAssertEqual(aps, "SET_ONE.APS")
        let apsItem = try XCTUnwrap(session.items.first { $0.shortName == aps })
        let contents = try MPCAllProgramsFile.contents(of: session.contents(of: apsItem))
        XCTAssertEqual(contents.programs, ["Break kit"])
        XCTAssertEqual(contents.sounds, ["KIK001", "SN001", "HAND_CLA"])

        // Saved to the file, and macOS's FAT checker is happy with it.
        let reopened = try MPCFloppySession(url: url)
        XCTAssertEqual(Set(reopened.items.map(\.shortName)),
                       ["KIK001.SND", "SN001.SND", "HAND_CLA.SND", "BREAK_KI.PGM", "SET_ONE.APS"])
        let problems = try await Shell.fsck(url)
        XCTAssertEqual(problems, [])
    }

    func testWAVsOnTheDiskAreConvertedForPrograms() throws {
        let session = try MPCFloppySession(url: try blankFloppy())
        // A WAV copied on by something else (Finder, MPC Blaster).
        let wavData = try Data(contentsOf: wav("RIM.WAV", frames: 2000))
        try session.change { _ = try $0.createFile(in: .root, name: "RIM.WAV", contents: wavData) }
        let rim = try XCTUnwrap(session.items.first { $0.shortName == "RIM.WAV" })
        let made = try session.makeProgram(named: "RIMS", sounds: [rim], memory: .mb32)
        XCTAssertEqual(made.converted, 1)
        let snd = try XCTUnwrap(session.items.first { $0.shortName == "RIM.SND" })
        XCTAssertEqual(try MPCSound(data: session.contents(of: snd)).frameCount, 2000)
    }

    func testMissingSoundsAndFailedChangesWriteNothing() throws {
        let url = try blankFloppy()
        let session = try MPCFloppySession(url: url)
        try session.importFiles([fixture("CYM1.PGM")])
        let before = try Data(contentsOf: url)

        let cym = try XCTUnwrap(session.items.first { $0.shortName == "CYM1.PGM" })
        XCTAssertEqual(session.apsPlan([cym]).missing.count, 16)
        XCTAssertThrowsError(try session.makeAPS(named: "BAD", programs: [cym], memory: .mb32))

        // Too big for the floppy: nothing at all is added.
        let big = try wav("long.wav", frames: 800_000)
        XCTAssertThrowsError(try session.importFiles([try fixture("KIK001.SND"), big]))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(session.items.map(\.shortName), ["CYM1.PGM"])
    }

    func testRenameKeepsExtensionAndDeleteFolders() throws {
        let session = try MPCFloppySession(url: try blankFloppy())
        try session.importFiles([fixture("KIK001.SND")])
        let kick = try XCTUnwrap(session.items.first)
        XCTAssertThrowsError(try session.rename(kick, to: "KICK.WAV"))
        XCTAssertEqual(try session.rename(kick, to: "big kick"), "BIG_KICK.SND")

        try session.newFolder(named: "loops")
        let loops = try XCTUnwrap(session.items.first { $0.isDirectory })
        session.open(loops)
        try session.importFiles([fixture("HH001.SND")])
        XCTAssertEqual(session.items.map(\.shortName), ["HH001.SND"])
        session.goUp()
        let free = session.freeBytes
        try session.delete([loops])
        XCTAssertGreaterThan(session.freeBytes, free)
        XCTAssertEqual(session.items.map(\.shortName), ["BIG_KICK.SND"])
    }
}
