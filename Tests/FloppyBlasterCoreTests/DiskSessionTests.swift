import XCTest
import AVFoundation
@testable import FloppyBlasterCore

@MainActor
final class DiskSessionTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FloppyBlasterTests-\(UUID().uuidString)")
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

    /// Writes a sine-wave audio file with AVAudioFile.
    private func audioFile(_ name: String, rate: Double, channels: AVAudioChannelCount, seconds: Double) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
                                       AVLinearPCMIsFloatKey: false,
                                       AVLinearPCMIsBigEndianKey: name.hasSuffix(".aif")]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![c][i] = 0.5 * sinf(Float(i) * 2 * .pi * 440 / Float(rate)) * (c == 0 ? 1 : -1)
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testImportsAudioAsAkaiSamplesAndSavesToTheImage() throws {
        let image = try copyFixture("s3000-fixture")
        let session = try DiskSession(url: image)
        let mono = try audioFile("Kick drum.wav", rate: 48_000, channels: 1, seconds: 0.5)
        let stereo = try audioFile("pad loop.aif", rate: 44_100, channels: 2, seconds: 0.25)

        let result = try session.importFiles([mono, stereo], options: .init(sampleRate: 44_100, channels: .splitLeftRight))
        XCTAssertEqual(result.added, ["KICK DRUM", "PAD LOOP  -L", "PAD LOOP  -R"])
        XCTAssertEqual(result.skipped, [])

        // Saved to the file, not just in memory.
        let reopened = try AkaiDisk(contentsOf: image)
        XCTAssertEqual(reopened.entries.map(\.name), ["SINE 440", "TEST PROGRAM", "LOW 220", "KICK DRUM", "PAD LOOP  -L", "PAD LOOP  -R"])
        let kick = try AkaiSample(file: reopened.contents(of: reopened.entries[3]), type: 0xF3)
        XCTAssertEqual(kick.sampleRate, 44_100)
        XCTAssertEqual(Double(kick.frames.count), 22_050, accuracy: 50, "resampled from 48 kHz")
        XCTAssertGreaterThan(kick.frames.map { abs(Int($0)) }.max() ?? 0, 15_000)
        let left = try AkaiSample(file: reopened.contents(of: reopened.entries[4]), type: 0xF3)
        let right = try AkaiSample(file: reopened.contents(of: reopened.entries[5]), type: 0xF3)
        XCTAssertEqual(left.frames.count, 11_025)
        XCTAssertGreaterThan(abs(Int(left.frames[25])), 1000)
        XCTAssertEqual(Int(left.frames[25]) + Int(right.frames[25]), 0, accuracy: 1, "left and right kept apart")

        // No temporary files left beside the image.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".FloppyBlaster") }
        XCTAssertEqual(leftovers, [])
    }

    func testMixToMonoAndLowerRate() throws {
        let session = try DiskSession(url: try copyFixture("s1000-fixture"))
        let stereo = try audioFile("stereo.wav", rate: 44_100, channels: 2, seconds: 0.2)
        let result = try session.importFiles([stereo], options: .init(sampleRate: 22_050, channels: .mixToMono))
        XCTAssertEqual(result.added, ["STEREO"])
        let entry = try XCTUnwrap(session.entries.last)
        XCTAssertEqual(entry.type, 0x73, "S1000 disk gets S1000 samples")
        let sample = try session.sample(entry)
        XCTAssertEqual(sample.sampleRate, 22_050)
        XCTAssertEqual(sample.frames.count, 4410)
        XCTAssertLessThan(sample.frames.map { abs(Int($0)) }.max() ?? 0, 100, "opposite channels cancel when mixed")
        XCTAssertEqual(session.sampleInfo[entry.index]?.rate, 22_050)
    }

    func testNamesAreMadeUniqueIncludingStereoPairs() throws {
        let session = try DiskSession(url: try copyFixture("s3000-fixture"))
        let a = try audioFile("sine 440.wav", rate: 44_100, channels: 1, seconds: 0.05)
        let b = try audioFile("pair.wav", rate: 44_100, channels: 2, seconds: 0.05)
        _ = try session.importFiles([a, b], options: .init())
        let again = try session.importFiles([b], options: .init())
        XCTAssertEqual(again.added, ["PAIR 2    -L", "PAIR 2    -R"])
        XCTAssertTrue(session.entries.contains { $0.name == "SINE 440 2" })
    }

    func testTooBigForTheDiskChangesNothing() throws {
        let image = try copyFixture("s3000-fixture")
        let before = try Data(contentsOf: image)
        let session = try DiskSession(url: image)
        let long = try audioFile("long.wav", rate: 44_100, channels: 1, seconds: 20)  // ~1.7 MB
        XCTAssertThrowsError(try session.importFiles([long], options: .init()))
        XCTAssertEqual(try Data(contentsOf: image), before)
    }

    func testUnreadableFilesAreSkippedNotFatal() throws {
        let session = try DiskSession(url: try copyFixture("s3000-fixture"))
        let junk = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: junk)
        let result = try session.importFiles([junk], options: .init())
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.skipped.count, 1)
    }

    func testExportWAVAndRawThenReimportRaw() throws {
        let session = try DiskSession(url: try copyFixture("s3000-fixture"))
        let out = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let written = try session.export(session.entries, to: out)
        XCTAssertEqual(written.map(\.lastPathComponent), ["SINE 440.wav", "TEST PROGRAM.p3", "LOW 220.wav"])
        let wav = try AVAudioFile(forReading: written[0])
        XCTAssertEqual(wav.length, 3000)
        XCTAssertEqual(wav.fileFormat.sampleRate, 44_100)

        let raw = try session.export([session.entries[0]], to: out, samplesAsWAV: false)
        XCTAssertEqual(raw.map(\.lastPathComponent), ["SINE 440.s3"])

        // A raw S3000 sample onto an S1000 disk: header converted, audio kept.
        let s1 = try DiskSession(url: try copyFixture("s1000-fixture"))
        let result = try s1.importFiles(raw, options: .init())
        XCTAssertEqual(result.added, ["SINE 440 2"])
        let copied = try s1.sample(try XCTUnwrap(s1.entries.last))
        XCTAssertEqual(copied.frames, try session.sample(session.entries[0]).frames)
        XCTAssertEqual(s1.entries.last?.type, 0x73)
        XCTAssertEqual(copied.name, "SINE 440 2")

        // A raw S3000 program can't go on an S1000 disk.
        let program = try session.export([session.entries[1]], to: out, samplesAsWAV: false)
        let refused = try s1.importFiles(program, options: .init())
        XCTAssertEqual(refused.added, [])
        XCTAssertEqual(refused.skipped.count, 1)
    }

    func testDeleteRenameAndVolumeNameAreSaved() throws {
        let image = try copyFixture("s3000-fixture")
        let session = try DiskSession(url: image)
        try session.delete([session.entries[0], session.entries[2]])
        try session.rename(session.entries[0], to: "Prog 1")
        try session.renameVolume("my drums")
        let reopened = try AkaiDisk(contentsOf: image)
        XCTAssertEqual(reopened.entries.map(\.name), ["PROG 1"])
        XCTAssertEqual(reopened.volumeName, "MY DRUMS")
        XCTAssertEqual(reopened.freeBlocks, 1583 - 1)
    }

    func testNewBlankDisksAreNumbered() throws {
        XCTAssertEqual(DiskSession.nextBlankName(in: folder), "001.img")
        try DiskSession.createBlank(at: folder.appendingPathComponent("001.img"))
        try Data().write(to: folder.appendingPathComponent("002.IMG"))
        XCTAssertEqual(DiskSession.nextBlankName(in: folder), "003.img")
        let blank = try AkaiDisk(contentsOf: folder.appendingPathComponent("001.img"))
        XCTAssertEqual(blank, AkaiDisk.blank(.s3000))
    }

    func testRawExtensions() {
        XCTAssertEqual(DiskSession.rawExtension(for: 0xF3), "s3")
        XCTAssertEqual(DiskSession.rawExtension(for: 0x70), "p1")
        XCTAssertEqual(DiskSession.rawExtension(for: 0x78), "x1")
        XCTAssertEqual(DiskSession.rawType(for: URL(fileURLWithPath: "/a/B.S3")), 0xF3)
        XCTAssertNil(DiskSession.rawType(for: URL(fileURLWithPath: "/a/b.wav")))
        XCTAssertNil(DiskSession.rawType(for: URL(fileURLWithPath: "/a/b.mp3")))
    }
}
