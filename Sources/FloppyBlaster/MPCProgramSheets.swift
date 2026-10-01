import SwiftUI
import FloppyBlasterCore

/// Make Program… on an MPC2000XL floppy: chosen sounds, in pad order, into a new .PGM.
struct MPCProgramSheet: View {
    @ObservedObject var session: MPCFloppySession
    let initialSounds: [FATEntry]
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mpcMemoryMB") private var memoryMB = MPCMemory.mb32.rawValue
    @State private var sounds: [FATEntry] = []
    @State private var name = "NEWKIT"

    private var memory: MPCMemory { MPCMemory(rawValue: memoryMB) ?? .mb32 }
    private var used: [FATEntry] { Array(sounds.prefix(MPCProgram.maxSounds)) }
    private var total: Int { used.reduce(0) { $0 + MPCFloppySession.estimatedMemory($1) } }
    private var conversions: Int { used.filter { $0.pathExtension.uppercased() != "SND" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make Program").font(.title2.bold())
            Text("Makes an MPC2000XL program (.PGM) on this floppy. Sounds go on pads A01, A02 … D16 in this order; drag to reorder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Program name", text: $name)
                Picker("MPC memory", selection: $memoryMB) {
                    ForEach(MPCMemory.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            List {
                ForEach(Array(sounds.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text(index < 64 ? MPCProgram.padNames[index] : "—")
                            .font(.body.monospaced())
                            .foregroundStyle(index < 64 ? Color.accentColor : .secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(MPCFloppySession.soundName(item)).font(.body.monospaced())
                        if item.pathExtension.uppercased() != "SND" {
                            Text("→ .SND").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(MPCFloppySession.mb(MPCFloppySession.estimatedMemory(item)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .onMove { sounds.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 240)

            MemoryBar(used: total, available: memory.usableBytes, label: memory.label)

            Group {
                if sounds.count > 64 { Text("Only the first 64 sounds are used (a program has 64 pads).") }
                if conversions > 0 {
                    Text("\(conversions) audio file\(conversions == 1 ? "" : "s") will be converted to .SND beside the original, which needs room on the floppy.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Program") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(used.isEmpty || total > memory.usableBytes || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 620)
        .onAppear {
            sounds = initialSounds.filter(MPCFloppySession.isSound)
            if let first = sounds.first { name = String(MPCFloppySession.soundName(first).prefix(5)) + "KIT" }
        }
    }

    private func make() {
        do {
            let made = try session.makeProgram(named: name, sounds: used, memory: memory)
            library.message = "Created \(made.file): \(made.sounds) sound\(made.sounds == 1 ? "" : "s") on pads A01–\(made.lastPad), \(MPCFloppySession.mb(made.memory)) of sound memory."
                + (made.converted == 0 ? "" : " Converted \(made.converted) file\(made.converted == 1 ? "" : "s") to .SND.")
            dismiss()
        } catch {
            library.alert = "The program wasn't made. \(error.localizedDescription)"
        }
    }
}

/// Make APS… on an MPC2000XL floppy: chosen programs, and the sounds they use, into a new .APS.
struct MPCAPSSheet: View {
    @ObservedObject var session: MPCFloppySession
    let programs: [FATEntry]
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mpcMemoryMB") private var memoryMB = MPCMemory.mb32.rawValue
    @State private var name = "ALLPGMS"
    @State private var plan = MPCFloppySession.APSPlan()

    private var memory: MPCMemory { MPCMemory(rawValue: memoryMB) ?? .mb32 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make APS").font(.title2.bold())
            Text("Makes an “all programs and sounds” file (.APS) on this floppy. Loading it on the MPC loads these programs and every sound they use.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("APS name", text: $name)
                Picker("MPC memory", selection: $memoryMB) {
                    ForEach(MPCMemory.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            List {
                Section("Programs (\(plan.programs.count) of 24 max)") {
                    ForEach(plan.programs, id: \.name) { p in
                        HStack {
                            Text(p.name).font(.body.monospaced())
                            Spacer()
                            Text("\(p.soundNames.count) sounds").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Sounds (\(plan.sounds.count))") {
                    ForEach(plan.sounds, id: \.self) { s in
                        HStack {
                            Text(s).font(.body.monospaced())
                            Spacer()
                            if plan.missing.contains(s) { Text("not in this folder").foregroundStyle(.red) }
                        }
                    }
                }
            }
            .frame(minHeight: 240)

            MemoryBar(used: plan.memory, available: memory.usableBytes, label: memory.label)

            if !plan.missing.isEmpty {
                Text("Every sound a program uses must be a .SND in this folder, or the MPC can't load it.")
                    .font(.callout).foregroundStyle(.red)
            }
            if !plan.unreadable.isEmpty {
                Text("Couldn't read: \(plan.unreadable.joined(separator: ", ")).").font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make APS") { make() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.programs.isEmpty || !plan.missing.isEmpty || !plan.unreadable.isEmpty
                              || plan.programs.count > 24 || plan.memory > memory.usableBytes
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 620)
        .onAppear { plan = session.apsPlan(programs) }
    }

    private func make() {
        do {
            let file = try session.makeAPS(named: name, programs: programs, memory: memory)
            library.message = "Created \(file): \(plan.programs.count) program\(plan.programs.count == 1 ? "" : "s"), \(plan.sounds.count) sounds, \(MPCFloppySession.mb(plan.memory)) of sound memory."
            dismiss()
        } catch {
            library.alert = "The APS wasn't made. \(error.localizedDescription)"
        }
    }
}

/// How much of the MPC's sound memory a program or APS takes.
struct MemoryBar: View {
    let used: Int
    let available: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(min(used, available)), total: Double(max(available, 1)))
                .tint(used > available ? .red : .accentColor)
            Text("\(MPCFloppySession.mb(used)) of about \(MPCFloppySession.mb(available)) sound memory (\(label))."
                 + (used > available ? " Too big." : ""))
                .font(.caption)
                .foregroundStyle(used > available ? .red : .secondary)
        }
    }
}
