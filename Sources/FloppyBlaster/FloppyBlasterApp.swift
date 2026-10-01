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
            "Floppy Blaster moves samples on and off Akai S1000 and S3000-format floppy disk images, the 1.6 MB .img files a Gotek floppy emulator running FlashFloppy loads into your sampler. It also plays the samples so you can hear what's on a disk.",
            "Editing programs, keygroups and sampler settings is left to S-Control.",
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
        ("Exporting", [
            "Select files and click Export…. Samples are saved as WAV files. Hold Option while clicking Export… to save the raw Akai files instead, which keep loop points and tuning.",
        ]),
        ("Saving", [
            "Every change is saved straight to the disk image. Floppy Blaster writes the new image beside the old one first and only then swaps it in, so pulling the stick mid-save can't leave a half-written disk.",
            "Eject the USB stick in Finder before unplugging it.",
        ]),
        ("Disk formats", [
            "S1000 format (S1000, S1100, S01): up to 64 files. S3000 format (S2000, S2800, S3000, S3200): up to 512 files. Floppy Blaster tells them apart by itself.",
            "New Blank Disk makes an S3000-format disk, numbered 001.img, 002.img… in the selected folder.",
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
        .frame(width: 520, height: 560)
    }
}
