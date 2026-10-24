import Foundation
import os

/// Channel sources: the curated free list (iptv-org, strictly filtered) and the user's own paid playlists.
///
/// Nothing in a playlist is ever executed. We read names, a few known attributes and http(s) stream
/// addresses; every other line (including player options that could write files) is ignored.
struct SourceLoad {
    let channels: [Channel]
    let epgURLs: [String]
    let secure: Bool
}

// MARK: - Grouping

enum Classifier {
    static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    static func found(_ rx: NSRegularExpression, in s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static let football = rx(#"football|soccer|f[uú]tbol|fifa|golazo|\bbein\b|la ?liga|premier league|\bepl\b|"#
        + #"uefa|serie a|bundesliga|ligue 1|\bmls\b|\bmutv\b|\blfc\b|talksport|\bgoal"#)
    static let tennis = rx(#"tennis|\batp\b|\bwta\b|wimbledon|roland.?garros|\bus open\b"#)
    static let cricket = rx(#"cricket|willow|\bipl\b|\bpsl\b|\bbpl\b|\bicc\b|\bashes\b|\bt20\b"#)
    static let news = rx(#"\bnews\b|\bcnn\b|al ?jazeera|al arabiya|\bndtv\b|\bwion\b|aaj tak|samachar|khabar|"#
        + #"bloomberg|\bcnbc\b|c-?span|france ?24|euronews|\bdw\b"#)
    static let sport = rx(#"sport|\bespn\b|\bnfl\b|\bnba\b|\bnhl\b|\bmlb\b|golf|racing|\bf1\b|motor|boxing|"#
        + #"\bufc\b|\bmma\b|\bwwe\b|\bdazn\b|\btnt\b|\bpga\b|rugby|kabaddi"#)
    static let movies = rx(#"\bmovies?\b|\bcinema\b|\bfilms?\b|\bflix\b|\bcine\b|bollywood|\bkino\b"#)
    static let entertainment = rx(#"entertainment|\bdrama\b|comedy|\bseries\b|\breality\b|\bsitcoms?\b|\bgec\b|"#
        + #"novelas?"#)
    static let kids = rx(#"\bkids?\b|cartoon|\btoons?\b|\bjunior\b|\bjr\b|anime|animation|\bbaby\b|\bnick\b|"#
        + #"nickelodeon|disney|\bpogo\b|cbeebies|\bcbbc\b|boomerang|\bkika\b"#)
    static let specific: [(String, NSRegularExpression)] = [("Football", football), ("Tennis", tennis),
                                                             ("Cricket", cricket)]

    /// iptv-org categories that put a free channel under Entertainment or Kids.
    static let entertainmentCategories: Set<String> = ["entertainment", "series", "comedy"]
    static let kidsCategories: Set<String> = ["kids", "animation"]

    /// National sports channels that carry cricket without saying so in their name.
    static let extraGroups: [String: Set<String>] = [
        "DDSports.in": ["Cricket"], "PTVSports.pk": ["Cricket"], "TSports.bd": ["Cricket", "Football"],
    ]

    /// Kids, Movies or Entertainment, judged from a channel's name and playlist group.
    static func screenGroups(_ text: String) -> Set<String> {
        var groups: Set<String> = found(kids, in: text) ? ["Kids"] : []
        if found(movies, in: text) {
            groups.insert("Movies")
        } else if found(entertainment, in: text) {
            groups.insert("Entertainment")
        }
        return groups
    }

    /// `screen` is the set of Kids / Movies / Entertainment groups when the source already says which;
    /// nil means judge them from the channel's name and playlist group.
    static func classify(_ text: String, news isNews: Bool = false, sports isSports: Bool = false,
                         screen: Set<String>? = nil) -> Set<String> {
        var groups = Set<String>()
        if isNews || found(news, in: text) { groups.insert("News") }
        for (name, rx) in specific where found(rx, in: text) { groups.insert(name) }
        if (isSports || found(sport, in: text)) && groups.isDisjoint(with: ChannelGroup.sports) {
            groups.insert("Sports")
        }
        groups.formUnion(screen ?? screenGroups(text))
        return groups.isEmpty ? ["Other"] : groups
    }
}

// MARK: - Legitimacy filter for the free list
//
// iptv-org lists any publicly reachable stream, and its sports, entertainment and movie sections mix
// official free channels with obvious pirate restreams of pay channels. Its own blocklist only covers
// takedown notices. So for the free list we additionally:
//   1. require https and a real host name (no bare IP addresses, which are almost always restreams);
//   2. drop hosts known for restreaming or for running third-party relays;
//   3. for sports, entertainment and movies, accept only streams served from the commercial video
//      platforms that free ad-supported (FAST) channels and broadcasters themselves use;
//   4. drop pay-TV sports, entertainment and movie brands entirely, because they are never
//      legitimately free.
// This is a careful filter, not a legal guarantee; see the README.

enum FreeFilter {
    enum Kind { case news, sports, screen }   // screen = entertainment, movies and kids
    static let blockedHosts = [
        "jmp2.uk", "mjh.nz", "githubusercontent.com", "github.io", "onrender.com", "herokuapp.com",
        "workers.dev", "pages.dev", "glitch.me", "dpdns.org", "ngrok.io", "aynascope.net", "aynaott.com",
        "bozztv.com", "stmify.com", "rezofoot.tv", "mcquack.net", "iptvperu.tv", "boldmss.com",
        "nellaiiptv.com", "cc.cd", "playstop.me", "siauliairsavlt.pw", "rabta.stream", "thelegitpro.in",
        "livelegitpro.in", "jswk.online", "gpcdn.net",
    ]
    /// Hosts that relay whole bouquets of unrelated pay entertainment channels (Star, Colors, Zee...). Only
    /// applied to entertainment and movie channels: some of them also carry free-to-air news.
    static let screenBlockedHosts = [
        "tangotv.in", "pishow.tv", "smartplaytv.in", "da86m1sqpm3o0.cloudfront.net",
        "d1rc86nwwc9fag.cloudfront.net", "d1g8wgjurz8via.cloudfront.net", "yuppnimrestreammum.akamaized.net",
        "yuppnimresmum.akamaized.net",
    ]
    static let trustedSportsHosts = [
        "amagi.tv", "wurl.com", "wurl.tv", "tubi.video", "tubi.io", "cbsivideo.com", "dai.google.com",
        "nbcuni.com", "brightcove.com", "akamaized.net", "akamaihd.net", "cloudfront.net", "mangomolo.com",
        "mgmlcdn.com", "frequency.stream", "getpublica.com", "klowdtv.com", "sofast.tv", "amazonaws.com",
        "zype.com", "transmit.live", "uplynk.com", "streamlock.net", "wowza.com", "cdn77.org",
        "vgcdn.net", "itworkscdn.net", "streamhoster.com",
    ]
    static let payTV = Classifier.rx(
        #"\bsky sports\b|\bbein sports(?! xtra)\b|star sports|sony (sports|ten|six)|\bten (sports|cricket)\b|"#
        + #"\bespn(?!8)|fox sports [12]\b|\bfs1\b|nfl network|nba tv|\bmsg\b|usa network|wwe network|setanta|"#
        + #"dsports|tnt sports|\bbt sport|eurosport|\bdazn(?! combat)|^willow( hd)?$|\bmutv\b|supersport|"#
        + #"sportsnet|\btsn\b|fox deportes|golf channel|premier sports|viaplay|unite8|^m sports$|one golf|"#
        + #"^pk sports$|^t sports$|ptv sports|ad sports|abu dhabi sports|\bssc\b|kayo|optus sport|tyc sports|"#
        + #"tigo sports|^s sport( \d)?$|movistar|^sport tv ?\d?$|arena sport|canal\+ ?sport|eleven sports|"#
        + #"\bsky sport\b"#)
    /// Pay-TV entertainment, movie and kids brands. Their owners' own free channels (Zee Dil Se, Zee One, Cine Sony,
    /// Stories by AMC and the like) have different names and stay.
    static let payTVScreen = Classifier.rx(
        #"\bhbo\b|cinemax|showtime|\bstarz\b|\bsky (cinema|atlantic|one|max|showcase|witness|comedy|crime|arts)\b|"#
        + #"\bstar ?(plus|bharat|gold|jalsha|maa|vijay|pravah|utsav|suvarna|movies|world|life)\b|\bcolors\b|"#
        + #"\bsony (sab|max|pal|aath|marathi|yay|wah|entertainment)\b|\bsab tv\b|\bset india\b|"#
        + #"\bzee (tv|cinema|bangla|marathi|tamil|telugu|kannada|keralam|anmol|action|classic|bollywood|zest|"#
        + #"punjabi|ganga|sarthak|biskope|yuva|talkies|picchar|thirai|cinemalu)\b|"#
        + #"\bsun (tv|surya|music|life|bangla|marathi)\b|\bgemini (tv|movies)\b|\budaya (tv|movies)\b|^ktv( hd)?$|"#
        + #"\basianet\b(?!.*\bnews\b)|mazhavil manorama|flowers tv|(^|\s)&\s?(tv|pictures|flix|prive|xplor)\b|"#
        + #"^mtv( india| hd)?$|\btcm\b|turner classic|\bmgm\b|paramount network|\bfxx?\b|\btbs\b|warner tv|"#
        + #"\baxn\b|^amc( europe| uk| asia)?$|movies now|romedy now|\bosn\b|"#
        + #"disney|nickelodeon|\bnick jr|cartoon network|\bpogo\b|hungama|boomerang|baby ?tv|"#
        + #"canal ?\+|canal plus|\bocs\b|cin[eé] ?\+|sky (italia|uno|serie|investigation)|premium (cinema|series)|"#
        + #"showmax"#)

    static func hostMatches(_ host: String, _ suffixes: [String]) -> Bool {
        suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isIP(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1
    }

    static func allowed(name: String, kind: Kind, url: String) -> Bool {
        guard url.lowercased().hasPrefix("https://") else { return false }
        let host = Net.host(of: url)
        if host.isEmpty || isIP(host) || hostMatches(host, blockedHosts) { return false }
        if Classifier.found(payTV, in: name) { return false }
        if kind == .screen && (Classifier.found(payTVScreen, in: name) || hostMatches(host, screenBlockedHosts)) {
            return false
        }
        if kind != .news && !hostMatches(host, trustedSportsHosts) { return false }
        return true
    }
}

// MARK: - Loading

enum Sources {
    private static let log = Logger(subsystem: "KaleidoTV", category: "sources")
    private static let iptvOrgAPI = "https://iptv-org.github.io/api/"
    private static let freeCacheTTL: TimeInterval = 24 * 3600
    /// iptv-org categories taken from the free list.
    private static let freeCategories = Classifier.entertainmentCategories.union(Classifier.kidsCategories)
        .union(["news", "sports", "movies"])

    // MARK: Free list (iptv-org public API)

    private struct OrgChannel: Decodable {
        let id: String
        let name: String?
        let altNames: [String]?
        let country: String?
        let categories: [String]?
        let isNsfw: Bool?
        let closed: Present?
    }

    private struct OrgStream: Decodable {
        let channel: String?
        let url: String?
        let userAgent: String?
        let referrer: String?
        let labels: [String]?
    }

    private struct OrgBlock: Decodable {
        let channel: String?
    }

    private struct OrgCountry: Decodable {
        let code: String
        let name: String?
        let flag: String?
    }

    private struct OrgLogo: Decodable {
        let channel: String?
        let feed: String?
        let width: Double?
        let format: String?
        let url: String?
    }

    /// Decodes any non-null JSON value; we only care whether the field is set.
    private struct Present: Decodable {
        init(from decoder: Decoder) throws {}
    }

    static func isFresh(_ url: URL, ttl: TimeInterval) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(modified) < ttl
    }

    private static func iptvOrg<T: Decodable>(_ name: String, force: Bool) async throws -> T {
        let path = Paths.cache.appendingPathComponent("iptvorg_\(name).json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func cached() -> T? {
            guard let data = try? Data(contentsOf: path) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
        if !force, isFresh(path, ttl: freeCacheTTL), let obj = cached() { return obj }
        do {
            let data = try await Net.fetch(iptvOrgAPI + name + ".json", maxBytes: 80 << 20)
            guard let obj = try? decoder.decode(T.self, from: data) else {
                throw FetchError("the \(name) list was unreadable")
            }
            try? data.write(to: path, options: .atomic)
            return obj
        } catch {
            if let obj = cached() {
                log.warning("Using older cached copy of iptv-org \(name)")
                return obj
            }
            throw error
        }
    }

    /// iptv-org country code -> name and flag, for every country. Empty if the list can't be loaded.
    static func countryNames(force: Bool) async -> [String: (name: String, flag: String)] {
        guard let list: [OrgCountry] = try? await iptvOrg("countries", force: force) else { return [:] }
        var out: [String: (name: String, flag: String)] = [:]
        for c in list { out[c.code] = (c.name ?? c.code, c.flag ?? "") }
        return out
    }

    /// Channel id -> logo address. Prefers the main feed's logo, in a bitmap format both platforms can show.
    static func logos(force: Bool) async -> [String: String] {
        guard let list: [OrgLogo] = try? await iptvOrg("logos", force: force) else { return [:] }
        var best: [String: (score: Double, url: String)] = [:]
        for logo in list {
            guard let cid = logo.channel, let url = logo.url, url.lowercased().hasPrefix("https://"),
                  ["PNG", "JPEG", "WEBP", "GIF"].contains((logo.format ?? "").uppercased()) else { continue }
            let score = (logo.feed == nil ? 10_000 : 0) + min(logo.width ?? 0, 600)
            if score > best[cid]?.score ?? -1 { best[cid] = (score, url) }
        }
        return best.mapValues(\.url)
    }

    /// `countries`: iptv-org country codes, or nil for every country.
    static func loadFreeChannels(countries: [String]?, force: Bool) async throws -> [Channel] {
        let orgChannels: [OrgChannel] = try await iptvOrg("channels", force: force)
        let orgStreams: [OrgStream] = try await iptvOrg("streams", force: force)
        let blocklist: [OrgBlock] = try await iptvOrg("blocklist", force: force)
        let blocked = Set(blocklist.compactMap(\.channel))
        let wanted = countries.map(Set.init)

        var byID: [String: OrgChannel] = [:]
        for c in orgChannels where (wanted?.contains(c.country ?? "") ?? true) && c.isNsfw != true && c.closed == nil
            && !blocked.contains(c.id) && !Set(c.categories ?? []).isDisjoint(with: freeCategories) {
            byID[c.id] = c
        }

        var result: [String: Channel] = [:]
        var order: [String] = []
        for s in orgStreams {
            guard let cid = s.channel, let c = byID[cid] else { continue }
            let url = (s.url ?? "").trimmingCharacters(in: .whitespaces)
            guard Net.isWebURL(url) else { continue }
            let cats = Set(c.categories ?? [])
            let name = c.name ?? c.id
            let kind: FreeFilter.Kind = cats.contains("sports") ? .sports : cats.contains("news") ? .news : .screen
            guard FreeFilter.allowed(name: name, kind: kind, url: url) else { continue }
            let ch: Channel
            if let existing = result[cid] {
                ch = existing
            } else {
                let text = ([name] + (c.altNames ?? [])).joined(separator: " ")
                var screen: Set<String> = cats.isDisjoint(with: Classifier.kidsCategories) ? [] : ["Kids"]
                if cats.contains("movies") {
                    screen.insert("Movies")
                } else if !cats.isDisjoint(with: Classifier.entertainmentCategories) {
                    screen.insert("Entertainment")
                }
                var groups = Classifier.classify(text, news: cats.contains("news"), sports: cats.contains("sports"),
                                                 screen: screen)
                groups.formUnion(Classifier.extraGroups[cid] ?? [])
                if !groups.isDisjoint(with: ChannelGroup.sports) { groups.remove("Sports") }
                groups.remove("Other")
                ch = Channel(key: "free:" + cid, name: name, country: c.country ?? "", groups: groups,
                             source: "Free (iptv-org)", free: true, epgID: cid)
                result[cid] = ch
                order.append(cid)
            }
            if ch.streams.contains(where: { $0.url == url }) { continue }
            ch.streams.append(StreamInfo(url: url, userAgent: s.userAgent ?? "", referrer: s.referrer ?? "",
                                         note: (s.labels ?? []).joined(separator: ", ")))
        }
        let channels = order.compactMap { result[$0] }
        for ch in channels {   // streams the list already flags as geo-blocked go last
            ch.streams = ch.streams.enumerated()
                .sorted { ($0.element.note.contains("Geo-blocked") ? 1 : 0, $0.offset)
                    < ($1.element.note.contains("Geo-blocked") ? 1 : 0, $1.offset) }
                .map(\.element)
        }
        return channels
    }

    // MARK: The user's own playlists

    private static let attr = try! NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)
    private static let noise = Classifier.rx(
        #"\(.*?\)|\[.*?\]|\b(f?hd|uhd|sd|4k|hevc|h\.?26[45]|\d{3,4}p|\d+fps|backup|alt|vip|raw)\b"#)
    private static let vodPath = Classifier.rx(#"/(movie|series)/"#)
    private static let allowedVLCOpts = ["http-user-agent": "user_agent", "http-referrer": "referrer",
                                         "http-referer": "referrer"]

    private static func attributes(_ s: String) -> [(String, String)] {
        let ns = s as NSString
        return attr.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    /// Channel names reduced to their core, so "BBC One HD" and "BBC One (backup)" become one channel.
    static func norm(_ name: String) -> String {
        let lower = name.lowercased()
        var s = noise.stringByReplacingMatches(in: lower, range: NSRange(lower.startIndex..., in: lower),
                                               withTemplate: " ")
        s = s.replacingOccurrences(of: #"[^\w]+"#, with: " ", options: .regularExpression)
        let out = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return out.isEmpty ? lower : out
    }

    private static func splitExtinf(_ line: String) -> (String, String) {
        let body = line.dropFirst("#EXTINF:".count)
        var quoted = false
        for i in body.indices {
            if body[i] == "\"" {
                quoted.toggle()
            } else if body[i] == "," && !quoted {
                return (String(body[..<i]),
                        String(body[body.index(after: i)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (String(body), "")
    }

    private final class Collector {
        var channels: [String: Channel] = [:]
        var order: [String] = []

        func add(key: String, name: String, country: String, groups: Set<String>, source: String,
                 epgID: String, logo: String, stream: StreamInfo) {
            let ch: Channel
            if let existing = channels[key] {
                ch = existing
            } else {
                ch = Channel(key: key, name: name, country: country, groups: groups, source: source,
                             free: false, epgID: epgID)
                channels[key] = ch
                order.append(key)
            }
            if ch.epgID.isEmpty && !epgID.isEmpty { ch.epgID = epgID }
            if ch.logo.isEmpty && logo.lowercased().hasPrefix("https://") { ch.logo = logo }
            if !ch.streams.contains(where: { $0.url == stream.url }) { ch.streams.append(stream) }
        }

        var list: [Channel] { order.compactMap { channels[$0] } }
    }

    /// Returns (channels, programme-guide addresses named in the playlist header).
    static func parseM3U(_ text: String, sourceID: String, sourceName: String) -> ([Channel], [String]) {
        let out = Collector()
        var epgURLs: [String] = []
        var pending: (name: String, attrs: [String: String])?
        var opts: [String: String] = [:]
        var extgrp = ""

        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") {
                for (k, v) in attributes(line) where ["x-tvg-url", "url-tvg"].contains(k.lowercased()) {
                    epgURLs += v.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter(Net.isWebURL)
                }
            } else if line.hasPrefix("#EXTINF") {
                let (head, name) = splitExtinf(line)
                var attrs: [String: String] = [:]
                for (k, v) in attributes(head) { attrs[k.lowercased()] = v }
                let display = [name, attrs["tvg-name"] ?? ""].first { !$0.isEmpty } ?? "Unnamed"
                pending = (display, attrs)
                opts = [:]
                extgrp = ""
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst("#EXTVLCOPT:".count)
                let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                if let field = allowedVLCOpts[key], parts.count == 2 {   // every other player option is ignored on purpose
                    opts[field] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("#EXTGRP:") {
                extgrp = line.dropFirst("#EXTGRP:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                continue
            } else {
                guard let entry = pending else { continue }
                pending = nil
                if !Net.isWebURL(line) || Classifier.found(vodPath, in: line) { continue }
                let groupTitle = [entry.attrs["group-title"] ?? "", extgrp].first { !$0.isEmpty } ?? ""
                let country = String((entry.attrs["tvg-country"] ?? "").prefix(2)).uppercased()
                out.add(key: "\(sourceID):\(norm(entry.name))", name: entry.name, country: country,
                        groups: Classifier.classify("\(entry.name) \(groupTitle)"), source: sourceName,
                        epgID: (entry.attrs["tvg-id"] ?? "").trimmingCharacters(in: .whitespaces),
                        logo: (entry.attrs["tvg-logo"] ?? "").trimmingCharacters(in: .whitespaces),
                        stream: StreamInfo(url: line, userAgent: opts["user_agent"] ?? "",
                                           referrer: opts["referrer"] ?? ""))
            }
        }
        return (out.list, epgURLs)
    }

    private static func loadM3UURL(_ src: SourceRecord, _ secret: [String: String]) async throws -> SourceLoad {
        var last: Error?
        for url in Net.httpsFirst(secret["url"] ?? "") {
            do {
                let data = try await Net.fetch(url, maxBytes: 200 << 20, timeout: 60, allowHTTP: true)
                let (channels, epg) = parseM3U(String(decoding: data, as: UTF8.self),
                                               sourceID: src.id, sourceName: src.name)
                return SourceLoad(channels: channels, epgURLs: epg, secure: url.lowercased().hasPrefix("https://"))
            } catch {
                last = error
            }
        }
        throw FetchError("Could not download the playlist: \(Net.describe(last))")
    }

    private static func loadM3UFile(_ src: SourceRecord) throws -> SourceLoad {
        let data = try Data(contentsOf: Paths.playlist(src.id))
        let (channels, epg) = parseM3U(String(decoding: data, as: UTF8.self), sourceID: src.id, sourceName: src.name)
        return SourceLoad(channels: channels, epgURLs: epg, secure: true)
    }

    // MARK: Xtream

    /// Percent-encodes everything except unreserved characters (so "+" in a password survives).
    private static func encode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func xtreamBase(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "http://" + s }
        let sep = s.range(of: "://")!
        let scheme = s[..<sep.lowerBound].lowercased()
        let netloc = s[sep.upperBound...].prefix { !"/?#".contains($0) }
        return "\(scheme)://\(netloc)"
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    private static func loadXtream(_ src: SourceRecord, _ secret: [String: String]) async throws -> SourceLoad {
        let user = secret["username"] ?? "", pw = secret["password"] ?? ""
        let qs = "username=\(encode(user))&password=\(encode(pw))"
        var last: Error?
        var base: String?
        for candidate in Net.httpsFirst(xtreamBase(secret["server"] ?? "")) {
            do {
                let data = try await Net.fetch("\(candidate)/player_api.php?\(qs)", allowHTTP: true)
                let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard text((info?["user_info"] as? [String: Any])?["auth"]) == "1" else {
                    throw FetchError("the provider rejected the username or password")
                }
                base = candidate
                break
            } catch {
                last = error
            }
        }
        guard let base else { throw FetchError("Could not log in to the Xtream service: \(Net.describe(last))") }

        func api(_ action: String) async throws -> [[String: Any]] {
            let data = try await Net.fetch("\(base)/player_api.php?\(qs)&action=\(action)",
                                           maxBytes: 200 << 20, timeout: 60, allowHTTP: true)
            return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        }

        var categories: [String: String] = [:]
        for c in try await api("get_live_categories") {
            categories[text(c["category_id"])] = text(c["category_name"])
        }
        let out = Collector()
        for item in try await api("get_live_streams") {
            let sid = text(item["stream_id"])
            let name = text(item["name"]).trimmingCharacters(in: .whitespaces)
            guard !sid.isEmpty, sid.allSatisfy(\.isASCII), sid.allSatisfy(\.isNumber), !name.isEmpty else { continue }
            let groupTitle = categories[text(item["category_id"])] ?? ""
            // Only the HLS (.m3u8) form: iOS's player can't play the raw MPEG-TS (.ts) alternative.
            out.add(key: "\(src.id):\(norm(name))", name: name, country: "",
                    groups: Classifier.classify("\(name) \(groupTitle)"), source: src.name,
                    epgID: text(item["epg_channel_id"]),
                    logo: text(item["stream_icon"]).trimmingCharacters(in: .whitespaces),
                    stream: StreamInfo(url: "\(base)/live/\(encode(user))/\(encode(pw))/\(sid).m3u8"))
        }
        return SourceLoad(channels: out.list, epgURLs: ["\(base)/xmltv.php?\(qs)"],
                          secure: base.hasPrefix("https://"))
    }

    static func loadUserSource(_ src: SourceRecord) async throws -> SourceLoad {
        switch src.kind {
        case .m3uFile: return try loadM3UFile(src)
        case .m3uURL: return try await loadM3UURL(src, try Keychain.load(src.id))
        case .xtream: return try await loadXtream(src, try Keychain.load(src.id))
        }
    }
}
