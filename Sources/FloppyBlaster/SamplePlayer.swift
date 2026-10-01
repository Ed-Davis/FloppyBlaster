import AVFoundation
import FloppyBlasterCore

/// Plays samples for auditioning: Akai samples, and MPC .SND / WAV sounds.
@MainActor
final class SamplePlayer: ObservableObject {
    /// What's playing: the disk image path plus the file's id on that disk.
    @Published private(set) var playing: String?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var generation = 0

    init() { engine.attach(node) }

    static func key(_ entry: AkaiDisk.Entry, on disk: URL) -> String { "\(disk.path)#\(entry.index)" }
    static func key(_ item: FATEntry, on disk: URL) -> String { "\(disk.path)#\(item.id)" }

    // MARK: Akai disks

    func isPlaying(_ entry: AkaiDisk.Entry, on disk: URL) -> Bool { playing == Self.key(entry, on: disk) }

    func toggle(_ entry: AkaiDisk.Entry, in session: DiskSession) -> String? {
        if isPlaying(entry, on: session.url) { stop(); return nil }
        guard entry.kind == .sample else { return nil }
        return play(key: Self.key(entry, on: session.url), name: entry.name) {
            try session.sample(entry).pcmBuffer()
        }
    }

    // MARK: MPC floppies

    func isPlaying(_ item: FATEntry, on disk: URL) -> Bool { playing == Self.key(item, on: disk) }

    func toggle(_ item: FATEntry, in session: MPCFloppySession) -> String? {
        if isPlaying(item, on: session.url) { stop(); return nil }
        guard MPCFloppySession.isSound(item) else { return nil }
        return play(key: Self.key(item, on: session.url), name: item.name) {
            try session.audioBuffer(for: item)
        }
    }

    // MARK: Playing

    /// Plays a buffer. Returns an error message if it couldn't.
    private func play(key: String, name: String, load: () throws -> AVAudioPCMBuffer?) -> String? {
        stop()
        do {
            guard let buffer = try load(), buffer.frameLength > 0 else { return "\(name) is empty." }
            if connectedFormat != buffer.format {
                if engine.isRunning { engine.stop() }
                engine.disconnectNodeOutput(node)
                engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
                connectedFormat = buffer.format
            }
            if !engine.isRunning { try engine.start() }
            generation += 1
            let current = generation
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.playing = nil
                }
            }
            node.play()
            playing = key
            return nil
        } catch {
            return "Couldn't play \(name): \(error.localizedDescription)"
        }
    }

    func stop() {
        generation += 1
        if node.isPlaying { node.stop() }
        playing = nil
    }
}
