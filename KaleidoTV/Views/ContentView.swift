import SwiftUI

enum AppSheet: String, Identifiable {
    case sources, settings
    var id: String { rawValue }
}

/// Browse, then tap a channel to open the player. Going back stops playback (unless it's in Picture in Picture).
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            BrowseView(open: open)
                .navigationTitle("Kaleido TV")
                .toolbar { BrowseToolbar() }
                .searchable(text: $model.query, prompt: "Search channels")
                .navigationDestination(for: String.self) { _ in
                    PlayerScreen(open: open, close: { path.removeAll() })
                }
        }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { model.leavePlayer() }
        }
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .sources: SourcesView()
                case .settings: SettingsView()
                }
            }
            .preferredColorScheme(.dark)
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
    }

    private func open(_ channel: Channel) {
        model.play(channel)
        if path.isEmpty { path = [channel.key] }
    }
}

/// Country filter, channel check, and the Sources / Settings / Refresh menu.
struct BrowseToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @State private var confirmPaidCheck = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            countryMenu
            Button("Check channels", systemImage: "checkmark.circle") {
                if model.checkablePaidCount > 0 { confirmPaidCheck = true } else { model.checkVisible(includePaid: false) }
            }
            .help("Check which channels in this category are working")
            .disabled(model.checking || model.channels.isEmpty)
            .confirmationDialog("Check paid channels?", isPresented: $confirmPaidCheck, titleVisibility: .visible) {
                Button("Check free and paid channels") { model.checkVisible(includePaid: true) }
                Button("Check free channels only") { model.checkVisible(includePaid: false) }
            } message: {
                Text("This list has \(model.checkablePaidCount) channels from your paid service. Many services only "
                     + "allow one or two connections at a time, so Kaleido TV checks them slowly, one at a time.")
            }
            Menu {
                Button("Sources…", systemImage: "antenna.radiowaves.left.and.right") { model.sheet = .sources }
                Button("Settings…", systemImage: "gearshape") { model.sheet = .settings }
                Divider()
                Button("Refresh all channel lists", systemImage: "arrow.clockwise") { model.reloadAll(force: true) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var countryMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Country", selection: $model.country) {
                Text("🌍 All countries").tag(String?.none)
                ForEach(model.availableCountries, id: \.self) { code in
                    Text(model.countryLabel(code)).tag(Optional(code))
                }
            }
        } label: {
            Label(model.country.map(model.countryLabel) ?? "All countries", systemImage: "globe")
        }
        .help("Show one country's channels")
    }
}

extension View {
    /// A small title bar on iPhone and iPad; the Mac has no equivalent setting.
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Sheets on the Mac need a size; on iPhone and iPad they fill the screen.
    func sheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 540, idealWidth: 600, minHeight: 560, idealHeight: 680)
        #else
        self
        #endif
    }

    /// Keyboard and autofill hints for typing a web address (iPhone and iPad only).
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL).textContentType(.URL)
        #else
        self
        #endif
    }
}
