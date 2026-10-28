import AVFoundation
import SwiftUI

@main
struct KaleidoTVApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(iOS)
        // Sound plays with the silent switch on, and video can continue in Picture in Picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1320, height: 820)
        #endif
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.sheet = .settings }
                    .keyboardShortcut(",")
            }
            CommandMenu("Sources") {
                Button("Manage Sources…") { model.sheet = .sources }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Refresh All Channel Lists") { model.reloadAll(force: true) }
                    .keyboardShortcut("r")
            }
            CommandMenu("Playback") {
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(model.current == nil)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.saveState() }
        }
    }
}
