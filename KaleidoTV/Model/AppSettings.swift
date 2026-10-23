import AVFoundation
import Foundation
import os

enum Paths {
    static let support = make(.applicationSupportDirectory)
    static let cache = make(.cachesDirectory)
    static let playlists: URL = {
        let url = support.appendingPathComponent("Playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var settings: URL { support.appendingPathComponent("settings.json") }

    static func playlist(_ sourceID: String) -> URL {
        playlists.appendingPathComponent(sourceID + ".m3u")
    }

    private static func make(_ directory: FileManager.SearchPathDirectory) -> URL {
        let url = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
            .appendingPathComponent("Kaleido TV", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// iptv-org country codes for the countries chosen at setup.
enum Countries {
    static let order = ["UK", "US", "IN", "PK", "BD", "AU", "AE", "SA", "QA", "KW", "BH", "OM"]
    static let names = [
        "UK": "United Kingdom", "US": "United States", "IN": "India", "PK": "Pakistan",
        "BD": "Bangladesh", "AU": "Australia", "AE": "UAE", "SA": "Saudi Arabia",
        "QA": "Qatar", "KW": "Kuwait", "BH": "Bahrain", "OM": "Oman",
    ]

    static func name(_ code: String) -> String { names[code] ?? code }
}

enum BufferChoice: Double, CaseIterable, Identifiable {
    case short = 8, normal = 15, long = 30

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .short: "Short – less delay behind live"
        case .normal: "Normal – recommended"
        case .long: "Long – for slow or unsteady internet"
        }
    }
}

/// Picture shape, remembered per channel.
enum PictureMode: String, CaseIterable, Identifiable {
    case fit, fill, stretch

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: "Fit (whole picture)"
        case .fill: "Fill screen (crops edges)"
        case .stretch: "Stretch"
        }
    }
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }
}

/// One of the user's own paid services. Its link or login lives in the Keychain, never in here.
struct SourceRecord: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case m3uURL = "m3u_url", m3uFile = "m3u_file", xtream

        var label: String {
            switch self {
            case .m3uURL: "M3U address"
            case .m3uFile: "M3U file"
            case .xtream: "Xtream"
            }
        }
    }

    var id: String
    var name: String
    var kind: Kind
}

struct AppSettings: Codable {
    var countries = Countries.order
    var worldwide = false               // free channels from every country, not just `countries`
    var favourites: [String] = []
    var recent: [String] = []           // channel keys, most recently watched first
    var sources: [SourceRecord] = []
    var epgURLs: [String] = []          // extra programme-guide (XMLTV) addresses
    var aspect: [String: String] = [:]  // channel key -> picture shape chosen for that channel
    var showLogos = true                // fetch channel logos from the addresses the channel lists give
    var bufferSeconds = BufferChoice.normal.rawValue

    private static let log = Logger(subsystem: "KaleidoTV", category: "settings")

    init() {}

    // Missing or unreadable keys fall back to their defaults, so older settings files keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        countries = (try? c.decodeIfPresent([String].self, forKey: .countries)) ?? d.countries
        worldwide = (try? c.decodeIfPresent(Bool.self, forKey: .worldwide)) ?? d.worldwide
        favourites = (try? c.decodeIfPresent([String].self, forKey: .favourites)) ?? d.favourites
        recent = (try? c.decodeIfPresent([String].self, forKey: .recent)) ?? d.recent
        sources = (try? c.decodeIfPresent([SourceRecord].self, forKey: .sources)) ?? d.sources
        epgURLs = (try? c.decodeIfPresent([String].self, forKey: .epgURLs)) ?? d.epgURLs
        aspect = (try? c.decodeIfPresent([String: String].self, forKey: .aspect)) ?? d.aspect
        showLogos = (try? c.decodeIfPresent(Bool.self, forKey: .showLogos)) ?? d.showLogos
        bufferSeconds = (try? c.decodeIfPresent(Double.self, forKey: .bufferSeconds)) ?? d.bufferSeconds
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: Paths.settings) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            log.error("Settings file unreadable; using defaults: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: Paths.settings, options: .atomic)
        } catch {
            Self.log.error("Couldn't save settings: \(error.localizedDescription)")
        }
    }
}
