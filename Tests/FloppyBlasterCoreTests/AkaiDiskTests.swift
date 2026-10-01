import XCTest
@testable import FloppyBlasterCore

/// The fixtures are made by Scripts/akaidisk.py, whose layout was checked
/// against real disks from an Akai S2800 Gotek setup (S1000, S1100, S01,
/// S2000 and S3000 libraries). These tests hold the Swift code to the same
/// bytes.
final class AkaiDiskTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "img", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Reading

    func testBlankS3000MatchesARealFormattedDisk() throws {
        XCTAssertEqual(AkaiDisk.blank(.s3000).data, try fixture("blank-s3000"))
        let disk = try AkaiDisk(data: fixture("blank-s3000"))
        XCTAssertEqual(disk.layout, .s3000)
        XCTAssertEqual(disk.entries, [])
        XCTAssertEqual(disk.freeBlocks, 1583)
        XCTAssertEqual(disk.volumeName, "NOT NAMED")
    }

    func testReadsS3000Disk() throws {
        let disk = try AkaiDisk(data: fixture("s3000-fixture"))
        XCTAssertEqual(disk.layout, .s3000)
        XCTAssertEqual(disk.entries.map(\.name), ["SINE 440", "TEST PROGRAM", "LOW 220"])
        XCTAssertEqual(disk.entries.map(\.type), [0xF3, 0xF0, 0xF3])
        XCTAssertEqual(disk.entries.map(\.kind), [.sample, .program, .sample])
        XCTAssertEqual(disk.entries.map(\.startBlock), [17, 24, 25])

        let sine = try AkaiSample(file: disk.contents(of: disk.entries[0]), type: 0xF3)
        XCTAssertEqual(sine.name, "SINE 440")
        XCTAssertEqual(sine.sampleRate, 44_100)
        XCTAssertEqual(sine.frames.count, 3000)
        XCTAssertEqual(sine.frames[0], 0)
        XCTAssertGreaterThan(sine.frames.map { abs(Int($0)) }.max() ?? 0, 11_000)

        let low = try AkaiSample(file: disk.contents(of: disk.entries[2]), type: 0xF3)
        XCTAssertEqual(low.sampleRate, 22_050)
        XCTAssertEqual(low.frames.count, 1500)

        XCTAssertEqual(try disk.contents(of: disk.entries[1]), Data([UInt8](0...255) + [UInt8](0...255) + [UInt8](0...255)))
    }

    func testReadsS1000Disk() throws {
        let disk = try AkaiDisk(data: fixture("s1000-fixture"))
        XCTAssertEqual(disk.layout, .s1000)
        XCTAssertEqual(disk.entries.map(\.name), ["SINE 440", "TEST PROGRAM", "LOW 220"])
        XCTAssertEqual(disk.entries.map(\.type), [0x73, 0x70, 0x73])
        XCTAssertEqual(disk.entries.first?.startBlock, 5)
        let sine = try AkaiSample(file: disk.contents(of: disk.entries[0]), type: 0x73)
        XCTAssertEqual(sine.frames.count, 3000)
        XCTAssertEqual(disk.freeBlocks, 1600 - 5 - 12)
    }

    func testRejectsWhatIsntAnAkaiFloppy() {
        XCTAssertThrowsError(try AkaiDisk(data: Data(count: 1000))) {
            XCTAssertEqual($0 as? AkaiDisk.DiskError, .wrongSize(1000))
        }
        XCTAssertThrowsError(try AkaiDisk(data: Data(count: AkaiDisk.imageSize))) {
            XCTAssertEqual($0 as? AkaiDisk.DiskError, .notAkai)
        }
    }

    // MARK: Writing (byte-identical to the reference)

    func testWritingMatchesTheReferenceS3000() throws {
        let reference = try AkaiDisk(data: fixture("s3000-fixture"))
        let files = try reference.entries.map { ($0, try reference.contents(of: $0)) }

        var disk = AkaiDisk.blank(.s3000)
        for (entry, contents) in files {
            if entry.kind == .sample {
                // Rebuild samples from their audio, to test the header writer too.
                let sample = try AkaiSample(file: contents, type: entry.type)
                try disk.addFile(name: sample.name, type: AkaiSample.fileType(for: .s3000), contents: sample.fileData(for: .s3000))
            } else {
                try disk.addFile(name: entry.name, type: entry.type, contents: contents)
            }
        }
        XCTAssertEqual(disk.data, reference.data)
    }

    func testWritingAndDeletingMatchesTheReferenceS1000() throws {
        let reference = try AkaiDisk(data: fixture("s1000-fixture"))
        let s3 = try AkaiDisk(data: fixture("s3000-fixture"))
        var disk = AkaiDisk.blank(.s1000)
        for entry in s3.entries {
            let contents = try s3.contents(of: entry)
            if entry.kind == .sample {
                let sample = try AkaiSample(file: contents, type: entry.type)
                try disk.addFile(name: sample.name, type: 0x73, contents: sample.fileData(for: .s1000))
            } else {
                try disk.addFile(name: entry.name, type: 0x70, contents: contents)
            }
        }
        // The reference also added then deleted a fourth sample.
        let extra = AkaiSample(name: "DELETE ME", sampleRate: 44_100, frames: [Int16](repeating: 1, count: 100))
        let added = try disk.addFile(name: extra.name, type: 0x73, contents: extra.fileData(for: .s1000))
        try disk.delete(added)
        XCTAssertEqual(disk.entries.map(\.name), reference.entries.map(\.name))
        XCTAssertEqual(disk.freeBlocks, reference.freeBlocks)
        // The deleted sample's blocks hold leftover audio on both; compare the
        // directory and block table exactly, and every file's contents.
        XCTAssertEqual(Array(disk.bytes[0..<0x1400]), Array(reference.bytes[0..<0x1400]))
        for (a, b) in zip(disk.entries, reference.entries) {
            XCTAssertEqual(try disk.contents(of: a), try reference.contents(of: b))
        }
    }

    func testDeleteClosesTheGapAndFreesBlocks() throws {
        var disk = try AkaiDisk(data: fixture("s3000-fixture"))
        let free = disk.freeBlocks
        try disk.delete(disk.entries[0])
        XCTAssertEqual(disk.entries.map(\.name), ["TEST PROGRAM", "LOW 220"])
        XCTAssertEqual(disk.entries.map(\.index), [0, 1])
        XCTAssertEqual(disk.freeBlocks, free + 7)
        // The freed space is reused by the next file.
        let reused = try disk.addFile(name: "NEW", type: 0xF0, contents: Data(count: 2000))
        XCTAssertEqual(reused.startBlock, 17)
        XCTAssertEqual(try disk.contents(of: disk.entries[1]).count, 3192, "other files untouched")
    }

    func testRenameUpdatesDirectoryAndSampleHeader() throws {
        var disk = try AkaiDisk(data: fixture("s3000-fixture"))
        try disk.rename(disk.entries[0], to: "kick_one")
        XCTAssertEqual(disk.entries[0].name, "KICK-ONE")
        let sample = try AkaiSample(file: disk.contents(of: disk.entries[0]), type: 0xF3)
        XCTAssertEqual(sample.name, "KICK-ONE")
        XCTAssertThrowsError(try disk.rename(disk.entries[0], to: "LOW 220"))
    }

    func testFullDiskAndDirectoryAreRefusedWithoutChanges() throws {
        var disk = AkaiDisk.blank(.s3000)
        let before = disk
        XCTAssertThrowsError(try disk.addFile(name: "HUGE", type: 0xF3, contents: Data(count: 1584 * 1024))) {
            XCTAssertEqual($0 as? AkaiDisk.DiskError, .diskFull(neededKB: 1584, freeKB: 1583))
        }
        XCTAssertEqual(disk, before)

        var small = AkaiDisk.blank(.s1000)
        for i in 0..<64 { try small.addFile(name: "F\(i)", type: 0x70, contents: Data(count: 10)) }
        XCTAssertThrowsError(try small.addFile(name: "ONE MORE", type: 0x70, contents: Data(count: 10))) {
            XCTAssertEqual($0 as? AkaiDisk.DiskError, .directoryFull(64))
        }
        XCTAssertThrowsError(try small.addFile(name: "F1", type: 0x70, contents: Data(count: 10)))
    }

    func testUniqueNames() throws {
        let disk = try AkaiDisk(data: fixture("s3000-fixture"))
        XCTAssertEqual(disk.uniqueName("snare"), "SNARE")
        XCTAssertEqual(disk.uniqueName("sine 440"), "SINE 440 2")
        XCTAssertEqual(disk.uniqueName("test program"), "TEST PROGR 2")
    }

    func testCharset() {
        XCTAssertEqual(AkaiCharset.clean("Kick_01 (hard)!"), "KICK-01  HAR")
        XCTAssertEqual(AkaiCharset.encode("A").count, 12)
        XCTAssertEqual(AkaiCharset.decode([11, 10, 37, 38, 39, 40]), "A #+-.")
    }

    // MARK: Samples

    func testSampleHeaderRoundTripAndWAV() throws {
        let frames: [Int16] = [0, 1000, -1000, 32767, -32768]
        let sample = AkaiSample(name: "TEST", sampleRate: 22_050, frames: frames)
        for layout in [AkaiDisk.Layout.s1000, .s3000] {
            let data = sample.fileData(for: layout)
            XCTAssertEqual(data.count, (layout == .s3000 ? 192 : 150) + 10)
            let back = try AkaiSample(file: data, type: AkaiSample.fileType(for: layout))
            XCTAssertEqual(back, sample)
        }
        let wav = sample.wavData()
        XCTAssertEqual(wav.count, 44 + 10)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(wav[24], 0x22)   // 22050 = 0x5622
        XCTAssertEqual(wav[25], 0x56)
        XCTAssertNotNil(sample.pcmBuffer())
    }
}
