import Foundation
import Observation

enum StreamStatus: String, Codable, Sendable {
    case unknown, ok, dead

    var rank: Int {
        switch self {
        case .ok: 0
        case .unknown: 1
        case .dead: 2
        }
    }
}

struct StreamInfo: Hashable, Sendable {
    var url: String
    var userAgent = ""
    var referrer = ""
    var note = ""
    var status: StreamStatus = .unknown
}

@Observable
final class Channel: Identifiable, Hashable {
    let key: String
    let name: String
    let country: String
    let groups: Set<String>
    let source: String
    let free: Bool
    var epgID: String
    var streams: [StreamInfo] = []
    var logo = ""   // https address of the channel's logo, when the source gives one

    var id: String { key }

    init(key: String, name: String, country: String, groups: Set<String>, source: String, free: Bool,
         epgID: String = "") {
        self.key = key
        self.name = name
        self.country = country
        self.groups = groups
        self.source = source
        self.free = free
        self.epgID = epgID
    }

    var status: StreamStatus {
        let states = Set(streams.map(\.status))
        if states.contains(.ok) { return .ok }
        if states == [.dead] { return .dead }
        return .unknown
    }

    /// Working streams first, then unchecked, then dead; otherwise in playlist order.
    func orderedStreams() -> [StreamInfo] {
        streams.enumerated()
            .sorted { ($0.element.status.rank, $0.offset) < ($1.element.status.rank, $1.offset) }
            .map(\.element)
    }

    static func == (a: Channel, b: Channel) -> Bool { a.key == b.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

enum ChannelGroup {
    static let all = ["Favourites", "Football", "Tennis", "Cricket", "News", "Sports", "Entertainment", "Movies",
                      "Kids", "Other", "All channels"]
    static let sports: Set<String> = ["Football", "Tennis", "Cricket"]

    static func symbol(_ group: String) -> String {
        switch group {
        case "Favourites": "star.fill"
        case "Football": "soccerball"
        case "Tennis": "tennis.racket"
        case "Cricket": "cricket.ball"
        case "News": "newspaper"
        case "Sports": "sportscourt"
        case "Entertainment": "theatermasks"
        case "Movies": "film"
        case "Kids": "teddybear.fill"
        case "Other": "square.grid.2x2"
        default: "list.bullet"
        }
    }
}
