import SwiftUI
import AppKit
import FloppyBlasterCore

@main
struct FloppyBlasterApp: App {
    @StateObject private var library = Library()
    @StateObject private var player = SamplePlayer()
    @State private var showAbout = false
    @State private var showHelp = false

    var body: some Scene {
        Window("Floppy Blaster", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .frame(minWidth: 980, minHeight: 600)
                .sheet(isPresented: $showAbout) { AboutView() }
                .sheet(isPresented: $showHelp) { HelpView() }
                .onOpenURL { url in
                    if url.isFileURL { library.open(url) }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Floppy Blaster") { showAbout = true }
            }
            CommandGroup(replacing: .help) {
                Button("Floppy Blaster Help") { showHelp = true }
            }
            CommandGroup(replacing: .newItem) {
                Menu("New Blank Disk") {
                    ForEach(Library.BlankKind.allCases) { kind in
                        Button(kind.menuTitle) { library.createBlankDisk(kind) }
                            .keyboardShortcut(kind == .s3000 ? KeyboardShortcut("n") : nil)
                    }
                }
                .disabled(library.root == nil)
            }
        }
    }
}

enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var full: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty { return "\(short) (\(build))" }
        return short
    }
}

enum AppArtwork {
    static var icon: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") { return NSImage(contentsOf: url) }
        return NSApp.applicationIconImage
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            if let icon = AppArtwork.icon {
                Image(nsImage: icon).resizable().frame(width: 128, height: 128)
            }
            Text("Floppy Blaster").font(.title2.bold())
            Text("Version \(AppVersion.full)").foregroundStyle(.secondary)
            Text("by Ed Davis").foregroundStyle(.secondary)
            Text("© \(String(Calendar.current.component(.year, from: Date()))) Ed Davis. All rights reserved.")
                .font(.caption).foregroundStyle(.tertiary)
            Text("Not affiliated with Akai Professional, inMusic or the makers of FlashFloppy or Gotek.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(28)
        .frame(width: 360)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, [String])] = [
        ("What it does", [
            "Floppy Blaster moves samples on and off floppy disk images for a Gotek floppy emulator running FlashFloppy: Akai S1000 and S3000-format disks (1.6 MB .img files) and MPC2000XL disks (1.44 MB DOS .img files). It plays the samples so you can hear what's on a disk, and makes simple programs from them.",
            "Editing programs, keygroups and sampler settings in detail is left to S-Control.",
        ]),
        ("Getting started", [
            "Plug in the Gotek's USB stick. Floppy Blaster finds it by its FF.CFG file, or click Choose Folder… and pick any folder of disk images.",
            "Pick a disk on the left to see what's on it.",
        ]),
        ("Listening", [
            "Click a sample's play button, double-click it, or select it and press Space. Press again to stop.",
        ]),
        ("Adding samples", [
            "Drop audio files (WAV, AIFF, MP3, M4A, FLAC…) onto the file list, or click Add Files…. They're converted to 16-bit Akai samples at the rate chosen at the bottom of the window.",
            "Stereo files become two samples named “NAME -L” and “NAME -R”, the way Akai samplers store stereo, or can be mixed to mono.",
            "Raw Akai files exported earlier (.s1, .s3, .p1, .p3…) go back on exactly as they were. Samples can move between S1000 and S3000 disks; other files must go on a disk of the same family.",
            "Names are up to 12 characters of A–Z, 0–9, space and # + - . (other characters become spaces).",
            "Nothing is written unless everything fits. A high-density disk holds about 1.5 MB: around 18 seconds of mono audio at 44.1 kHz, or 36 seconds at 22 kHz.",
        ]),
        ("Making an Akai program", [
            "Select samples (or none, for all of them) and click Make Program…. The new program plays each sample on its own key from C1 (MIDI note 36) upwards, at the pitch it was recorded, like a drum kit. Drag to change the order.",
            "A stereo pair (NAME -L and NAME -R next to each other) shares one key, panned left and right.",
            "Up to 92 keys (C1 to G8). The program is saved on the same disk as its samples, with the first program number no other program on the disk uses.",
            "On the sampler, load the whole disk (LOAD ALL / entire volume) to get the program and its samples together: an Akai disk is its own “all programs and sounds” file.",
        ]),
        ("MPC2000XL floppies", [
            "MPC2000XL floppies (1.44 MB DOS disks) open the same way as Akai ones; Floppy Blaster tells them apart by itself. New Blank Disk can make one too.",
            "Audio files dropped on an MPC floppy become MPC .SND sounds (16-bit, 44.1 kHz, mono or stereo). .SND, .PGM, .APS and other MPC files are copied as they are. Names are 8 characters.",
            "Make Program… puts the selected sounds (or all of them) on pads A01, A02 … D16 of a new .PGM, up to 64.",
            "The window shows the exact name each sound will have on the MPC: its file name, 8 characters of A–Z, 0–9, _ and -. ⚠︎ with the original name marks one that's shortened (a long Mac file name is seen by the MPC as its 8-character short name) or numbered because the name is taken. Program and APS names can be 16 characters; under the name you'll see how it shows on the MPC and the file it's saved as.",
            "Make APS… bundles the selected programs (or all of them) into an “all programs and sounds” file, so the MPC loads them and every sound they use in one go. Every sound must be on the floppy, in the same folder.",
            "Both check that the sounds fit in the MPC's sample memory: choose 2 MB (standard), 16 MB or 32 MB to match yours. Sequences have their own memory, so nothing needs to be left for them.",
            "Double-click a folder to open it; Up goes back.",
        ]),
        ("Exporting", [
            "Select files and click Export…. Akai samples are saved as WAV files. Hold Option while clicking Export… to save the raw Akai files instead, which keep loop points and tuning. Files on MPC floppies are exported as they are.",
        ]),
        ("Saving", [
            "Every change is saved straight to the disk image, on Akai and MPC disks alike. Floppy Blaster writes the new image beside the old one first and only then swaps it in, so pulling the stick mid-save can't leave a half-written disk.",
            "Eject the USB stick in Finder before unplugging it.",
        ]),
        ("Disk formats", [
            "S1000 format (S1000, S1100, S01): up to 64 files. S3000 format (S2000, S2800, S3000, S3200): up to 512 files. Floppy Blaster tells them apart by itself.",
            "New Blank Disk (the + button, or File menu) makes an S3000, S1000 or MPC2000XL disk, numbered 001.img, 002.img… in the selected folder.",
            "S900 and S950 disks use a different format and aren't supported.",
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Floppy Blaster Help").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.0) { title, paragraphs in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline)
                            ForEach(paragraphs, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 560, height: 640)
    }
}
