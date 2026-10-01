import AVFoundation
import FloppyBlasterCore

/// Plays Akai samples for auditioning.
@MainActor
final class SamplePlayer: ObservableObject {
    /// The directory index of the sample playing, on the disk at `playingDisk`.
    @Published private(set) var playing: Int?
    private var playingDisk: URL?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var generation = 0

    init() { engine.attach(node) }

    func isPlaying(_ entry: AkaiDisk.Entry, on disk: URL) -> Bool {
        playing == entry.index && playingDisk == disk
    }

    func toggle(_ entry: AkaiDisk.Entry, in session: DiskSession) -> String? {
        if isPlaying(entry, on: session.url) { stop(); return nil }
        return play(entry, in: session)
    }

    /// Plays a sample. Returns an error message if it couldn't.
    @discardableResult
    func play(_ entry: AkaiDisk.Entry, in session: DiskSession) -> String? {
        stop()
        guard entry.kind == .sample else { return nil }
        do {
            guard let buffer = try session.sample(entry).pcmBuffer() else { return "\(entry.name) is empty." }
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
                    self.playingDisk = nil
                }
            }
            node.play()
            playing = entry.index
            playingDisk = session.url
            return nil
        } catch {
            return "Couldn't play \(entry.name): \(error.localizedDescription)"
        }
    }

    func stop() {
        generation += 1
        if node.isPlaying { node.stop() }
        playing = nil
        playingDisk = nil
    }
}
