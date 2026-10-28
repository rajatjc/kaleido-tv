import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var listSettingsAtOpen: [String] = []

    /// The settings that change which channels load; the lists reload when Settings closes if any changed.
    private var listSettings: [String] {
        model.settings.countries + ["\(model.settings.worldwide)", "\(model.settings.showLogos)"]
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Buffer", selection: $model.settings.bufferSeconds) {
                        ForEach(BufferChoice.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("A longer buffer rides out unsteady internet, but the picture sits further behind live.")
                }

                Section {
                    Toggle("Every country (worldwide)", isOn: $model.settings.worldwide)
                    ForEach(Countries.order, id: \.self) { code in
                        Toggle(model.countryLabel(code), isOn: countryBinding(code))
                    }
                    .disabled(model.settings.worldwide)
                } header: {
                    Text("Free channels from")
                } footer: {
                    Text("Worldwide adds about 600 channels from over 100 more countries, and the first check of "
                         + "which ones work takes a few minutes. The lists reload when you close Settings.")
                }

                Section {
                    Toggle("Show channel logos", isOn: $model.settings.showLogos)
                } header: {
                    Text("Look")
                } footer: {
                    Text("Logos are downloaded from the addresses the channel lists give (mostly Wikimedia and "
                         + "Imgur) and kept on this device. Turn this off and cards show the channel's initials.")
                }

                Section {
                    NavigationLink("About and safety") { AboutView() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheetSize()
        .onAppear { listSettingsAtOpen = listSettings }
        .onDisappear {
            if listSettings != listSettingsAtOpen { model.reloadAll() }
        }
    }

    private func countryBinding(_ code: String) -> Binding<Bool> {
        Binding {
            model.settings.countries.contains(code)
        } set: { on in
            var chosen = Set(model.settings.countries)
            if on { chosen.insert(code) } else { chosen.remove(code) }
            model.settings.countries = Countries.order.filter(chosen.contains)
            if let country = model.country, !chosen.contains(country) { model.country = nil }
        }
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        List {
            Section {
                Text("Kaleido TV \(version) plays legitimate free TV channels, grouped into Football, Tennis, "
                     + "Cricket, News, Sports, Entertainment, Movies and Kids, plus any paid IPTV service you add. "
                     + "Video plays through Apple's own player (AVFoundation).")
            }
            Section("How Kaleido TV keeps you safe") {
                bullet("No ads, no tracking, no accounts, no telemetry. It only contacts the iptv-org channel list "
                       + "(github.io), the TV streams you play or check, any paid service or guide you add, and, "
                       + "while \"Show channel logos\" is on, the sites the logos are stored on.")
                bullet("It never downloads or runs programs. Playlists are read as plain text: only channel names, "
                       + "a few labels and http(s) video addresses are used. Hidden player commands inside "
                       + "playlists are ignored.")
                bullet("The free list is filtered beyond iptv-org's own blocklist: pay-TV sports brands, bare IP "
                       + "addresses, unencrypted links and known restream hosts are removed, and sports channels "
                       + "must come from the video platforms that official free channels use. This is a careful "
                       + "filter, not a legal guarantee.")
                bullet("https everywhere it's possible, with full certificate checks. Downloads can't be "
                       + "redirected to an insecure address, and every download has a size limit.")
                bullet("Your paid-service details are kept in this device's Keychain: not synced, not in backups.")
            }
            Section("What's realistically free") {
                Text("Free, legal live news is excellent. Free, legal live top-level football, tennis and cricket "
                     + "is thin, because the big competitions sell their rights to pay services. Avoid \"free sports "
                     + "IPTV\" playlists and \"lifetime\" subscriptions: those are pirated feeds.")
            }
        }
        .navigationTitle("About and safety")
    }

    private func bullet(_ text: String) -> some View {
        Text(text).font(.callout)
    }
}
