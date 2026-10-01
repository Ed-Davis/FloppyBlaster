import SwiftUI
import FloppyBlasterCore

/// Make Program… on an Akai disk: the chosen samples, one per key from C1,
/// into a new program on the same disk.
struct AkaiProgramSheet: View {
    @ObservedObject var session: DiskSession
    let samples: [AkaiDisk.Entry]
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [AkaiProgram.Key] = []
    @State private var name = ""

    private var used: [AkaiProgram.Key] { Array(keys.prefix(AkaiProgram.maxKeys)) }
    private var programKB: Int {
        (AkaiProgram.headerLength(for: session.disk.layout) * (used.count + 1) + 1023) / 1024
    }
    private var fits: Bool { programKB <= session.freeKB && session.entries.count < session.disk.layout.maxFiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make Program").font(.title2.bold())
            Text("Makes a program on this disk that plays each sample on its own key, from C1 up, at the pitch it was recorded (like a drum kit). Stereo pairs (-L and -R) share a key. Drag to reorder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Program name", text: $name)
                LabeledContent("Program number", value: "\(session.nextProgramNumber + 1)")
                    .help("The first number no other program on this disk uses, so loading the whole disk doesn't layer it with another program.")
            }

            List {
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    HStack {
                        Text(index < AkaiProgram.maxKeys ? AkaiProgram.noteName(AkaiProgram.firstNote + index) : "—")
                            .font(.body.monospaced())
                            .foregroundStyle(index < AkaiProgram.maxKeys ? Color.accentColor : .secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(key.label).font(.body.monospaced())
                        Spacer()
                        if key.samples.count == 2 { Text("stereo").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .onMove { keys.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 260)

            Group {
                if keys.count > AkaiProgram.maxKeys {
                    Text("Only the first \(AkaiProgram.maxKeys) are used: C1 to G8 is as high as MIDI goes.")
                }
                Text(fits ? "The program takes \(programKB) KB of the \(session.freeKB) KB free."
                          : "There isn't room on this disk for the program (\(programKB) KB, or one more file).")
                    .foregroundStyle(fits ? Color.secondary : .red)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Program") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(used.isEmpty || !fits)
            }
        }
        .padding(20)
        .frame(width: 480, height: 600)
        .onAppear {
            keys = AkaiProgram.keys(for: samples.map(\.name))
            let first = keys.first.map { String($0.label.prefix(7)).trimmingCharacters(in: .whitespaces) } ?? "NEW"
            name = AkaiCharset.clean(first + " KIT")
        }
    }

    private func make() {
        do {
            let made = try session.makeProgram(named: name, keys: used)
            let last = AkaiProgram.noteName(AkaiProgram.firstNote + made.keys - 1)
            library.message = "Made program \(made.name): \(made.keys) key\(made.keys == 1 ? "" : "s"), C1–\(last), program \(made.programNumber + 1)."
            dismiss()
        } catch {
            library.alert = "The program wasn't made. \(error.localizedDescription)"
        }
    }
}
