import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var removal: Removal?
    @State private var error: String?

    enum Removal: Identifiable {
        case source(SourceRecord), guide(String)
        var id: String {
            switch self {
            case .source(let s): "source:" + s.id
            case .guide(let url): "guide:" + url
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Free channels (iptv-org)", systemImage: "checkmark.shield")
                } footer: {
                    Text("Always included, and filtered to legitimate free channels.")
                }

                Section {
                    if model.settings.sources.isEmpty {
                        Text("None yet. Only add a service you actually pay for.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.settings.sources) { src in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(src.name)
                            Text("\(src.kind.label) – \(model.sourceInfo[src.id] ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Remove…", systemImage: "trash", role: .destructive) { removal = .source(src) }
                        }
                    }
                    .onDelete { offsets in
                        if let i = offsets.first { removal = .source(model.settings.sources[i]) }
                    }
                } header: {
                    Text("Your paid services")
                }

                if !model.settings.epgURLs.isEmpty {
                    Section("Programme guides") {
                        ForEach(model.settings.epgURLs, id: \.self) { url in
                            Text(url).font(.footnote).lineLimit(2)
                                .contextMenu {
                                    Button("Remove…", systemImage: "trash", role: .destructive) { removal = .guide(url) }
                                }
                        }
                        .onDelete { offsets in
                            if let i = offsets.first { removal = .guide(model.settings.epgURLs[i]) }
                        }
                    }
                }

                Section {
                    NavigationLink("Paid playlist (M3U web address)") { AddPlaylistForm() }
                    NavigationLink("Paid service (Xtream login)") { AddXtreamForm() }
                    Button("Paid playlist (M3U file)…") { importing = true }
                    NavigationLink("Programme guide (XMLTV address)") { AddGuideForm() }
                } header: {
                    Text("Add")
                } footer: {
                    Text("Your link, username and password are stored in this device's Keychain and are only ever "
                         + "sent to your provider. Kaleido TV tries an encrypted (https) connection first.")
                }

                Section {
                    Button("Refresh all channel lists") {
                        model.reloadAll(force: true)
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sources")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.m3uPlaylist, .plainText, .data]) { result in
                do {
                    try model.addM3UFile(from: try result.get())
                } catch {
                    self.error = Net.describe(error)
                }
            }
            .confirmationDialog("Remove this source from Kaleido TV?",
                                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                                titleVisibility: .visible, presenting: removal) { item in
                Button("Remove", role: .destructive) {
                    switch item {
                    case .source(let src): model.removeSource(src)
                    case .guide(let url): model.removeGuide(url)
                    }
                }
            }
            .alert("Couldn't add the playlist", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
        .sheetSize()
    }
}

/// Shared shape for the "add a source" forms: fields, an explanation, and a Save button.
private struct SourceForm<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let intro: String
    let canSave: Bool
    let save: () throws -> Void
    @ViewBuilder let fields: Fields
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                fields
            } footer: {
                Text(intro)
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try save()
                        dismiss()
                    } catch {
                        self.error = Net.describe(error)
                    }
                }
                .disabled(!canSave)
            }
        }
        .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }
}

private func filled(_ values: String...) -> Bool {
    values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct AddPlaylistForm: View {
    @Environment(AppModel.self) private var model
    @State private var name = "My TV service"
    @State private var url = ""

    var body: some View {
        SourceForm(title: "Paid playlist",
                   intro: "Paste the M3U playlist address your provider gave you (a long link, often ending in "
                       + ".m3u or containing get.php).",
                   canSave: filled(name, url),
                   save: { try model.addM3UURL(name: name.trimmingCharacters(in: .whitespaces), url: url) }) {
            TextField("Name", text: $name)
            TextField("Playlist address", text: $url, axis: .vertical)
                .urlEntry()
        }
    }
}

struct AddXtreamForm: View {
    @Environment(AppModel.self) private var model
    @State private var name = "My TV service"
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        SourceForm(title: "Xtream login",
                   intro: "Enter the server address, username and password from your provider.",
                   canSave: filled(name, server, username, password),
                   save: {
                       try model.addXtream(name: name.trimmingCharacters(in: .whitespaces),
                                           server: server.trimmingCharacters(in: .whitespaces),
                                           username: username.trimmingCharacters(in: .whitespaces),
                                           password: password)
                   }) {
            TextField("Name", text: $name)
            TextField("Server address", text: $server)
                .urlEntry()
            TextField("Username", text: $username)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
        }
    }
}

struct AddGuideForm: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""

    var body: some View {
        SourceForm(title: "Programme guide",
                   intro: "Paste an XMLTV guide address (ending in .xml or .xml.gz). Paid services usually "
                       + "provide their guide automatically, so you only need this for extra guides.",
                   canSave: filled(url),
                   save: { try model.addGuide(url) }) {
            TextField("Guide address", text: $url, axis: .vertical)
                .urlEntry()
        }
    }
}
