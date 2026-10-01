import XCTest
@testable import FloppyBlasterCore

@MainActor
final class AkaiProgramTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AkaiProgramTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func copyFixture(_ name: String) throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "img", subdirectory: "Fixtures"))
        let destination = folder.appendingPathComponent("\(name).img")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func testTemplatesAreWholeHeaders() {
        XCTAssertEqual(AkaiProgram.s1000Header.count, 150)
        XCTAssertEqual(AkaiProgram.s1000Keygroup.count, 150)
        XCTAssertEqual(AkaiProgram.s3000Header.count, 192)
        XCTAssertEqual(AkaiProgram.s3000Keygroup.count, 192)
        XCTAssertEqual(AkaiProgram.s1000Header[0], 1)
        XCTAssertEqual(AkaiProgram.s3000Keygroup[0], 2)
        XCTAssertEqual(AkaiProgram.s1000Keygroup[132], 1, "factory drum keygroups use constant pitch")
    }

    func testNoteNames() {
        XCTAssertEqual(AkaiProgram.noteName(36), "C1")
        XCTAssertEqual(AkaiProgram.noteName(37), "C#1")
        XCTAssertEqual(AkaiProgram.noteName(60), "C3")
        XCTAssertEqual(AkaiProgram.noteName(127), "G8")
        XCTAssertEqual(AkaiProgram.maxKeys, 92)
    }

    func testStereoPairsShareAKey() {
        let keys = AkaiProgram.keys(for: ["KICK", "PAD LOOP  -L", "PAD LOOP  -R", "HAT-L", "SNARE"])
        XCTAssertEqual(keys.map(\.samples), [["KICK"], ["PAD LOOP  -L", "PAD LOOP  -R"], ["HAT-L"], ["SNARE"]])
        XCTAssertEqual(keys[1].label, "PAD LOOP -L/-R")
    }

    func testS3000ProgramLayout() throws {
        let keys = AkaiProgram.keys(for: ["KICK", "SNARE", "PAD-L", "PAD-R"])
        let data = try AkaiProgram.fileData(name: "my kit", programNumber: 3, keys: keys, layout: .s3000)
        let b = [UInt8](data)
        XCTAssertEqual(b.count, 192 * 4)
        XCTAssertEqual(b[42], 3)
        XCTAssertEqual(b[15], 3)
        // Untouched template bytes stay as Akai wrote them.
        XCTAssertEqual(Array(b[43..<192]), Array(AkaiProgram.s3000Header[43..<192]))

        let pad = Array(b[192 * 3..<192 * 4])
        XCTAssertEqual(pad[3], 38)
        XCTAssertEqual(pad[4], 38)
        XCTAssertEqual(pad[34 + 18], UInt8(bitPattern: -50), "left panned left")
        XCTAssertEqual(pad[58 + 18], 50, "right panned right")
        XCTAssertEqual(Array(pad[132..<136]), [1, 1, 0, 0])
        XCTAssertEqual(Array(pad[82..<106]), AkaiProgram.emptyZone)

        let contents = try AkaiProgram.contents(of: data, type: 0xF0)
        XCTAssertEqual(contents.name, "MY KIT")
        XCTAssertEqual(contents.programNumber, 3)
        XCTAssertEqual(contents.keygroups.map(\.lowNote), [36, 37, 38])
        XCTAssertEqual(contents.keygroups.map(\.highNote), [36, 37, 38])
        XCTAssertEqual(contents.keygroups.map(\.samples), [["KICK"], ["SNARE"], ["PAD-L", "PAD-R"]])
        XCTAssertEqual(contents.keygroups.map(\.constantPitch), [[true], [true], [true, true]])
    }

    func testS1000ProgramClearsTheTemplatesOtherZones() throws {
        let data = try AkaiProgram.fileData(name: "KIT", programNumber: 0,
                                            keys: AkaiProgram.keys(for: ["ONE"]), layout: .s1000)
        let contents = try AkaiProgram.contents(of: data, type: 0x70)
        XCTAssertEqual(data.count, 300)
        XCTAssertEqual(contents.keygroups, [.init(lowNote: 36, highNote: 36, samples: ["ONE"], constantPitch: [true])])
        XCTAssertEqual(data[1], 150, "first keygroup address, numbered as an S1000 does")
        XCTAssertEqual(data[151], 0x2C, "next keygroup at 300")
    }

    func testLimits() {
        XCTAssertThrowsError(try AkaiProgram.fileData(name: "X", programNumber: 0, keys: [], layout: .s3000))
        let many = (0..<93).map { AkaiProgram.Key(samples: ["S\($0)"]) }
        XCTAssertThrowsError(try AkaiProgram.fileData(name: "X", programNumber: 0, keys: many, layout: .s3000))
        XCTAssertNoThrow(try AkaiProgram.fileData(name: "X", programNumber: 0, keys: Array(many.prefix(92)), layout: .s3000))
    }

    func testMakeProgramOnADisk() throws {
        for (fixture, type) in [("s3000-fixture", UInt8(0xF0)), ("s1000-fixture", UInt8(0x70))] {
            let image = try copyFixture(fixture)
            let session = try DiskSession(url: image)
            XCTAssertEqual(session.nextProgramNumber, 0, "the fixture's program uses number 15")
            let samples = session.entries.filter { $0.kind == .sample }.map(\.name)
            let made = try session.makeProgram(named: "two tones", keys: AkaiProgram.keys(for: samples))
            XCTAssertEqual(made, .init(name: "TWO TONES", keys: 2, programNumber: 0))

            let reopened = try AkaiDisk(contentsOf: image)
            let entry = try XCTUnwrap(reopened.entries.last)
            XCTAssertEqual(entry.name, "TWO TONES")
            XCTAssertEqual(entry.type, type)
            let contents = try AkaiProgram.contents(of: reopened.contents(of: entry), type: type)
            XCTAssertEqual(contents.keygroups.map(\.samples), [["SINE 440"], ["LOW 220"]])

            // A second one gets its own name and program number.
            let again = try session.makeProgram(named: "two tones", keys: AkaiProgram.keys(for: samples))
            XCTAssertEqual(again.name, "TWO TONES 2")
            XCTAssertEqual(again.programNumber, 1)
        }
    }
}
