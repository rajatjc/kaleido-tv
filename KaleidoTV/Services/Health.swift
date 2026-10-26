import CryptoKit
import Foundation

/// Remembers check results for a few hours. Keys are hashed so no private address is stored in clear.
final class HealthCache: @unchecked Sendable {
    private struct Entry: Codable {
        let s: StreamStatus
        let t: TimeInterval
    }

    static let ttl: TimeInterval = 6 * 3600
    private let lock = NSLock()
    private let path = Paths.cache.appendingPathComponent("health.json")
    private var data: [String: Entry]

    init() {
        data = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: path))) ?? [:]
    }

    private static func key(_ url: String) -> String {
        String(SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    func get(_ url: String) -> StreamStatus? {
        lock.withLock {
            guard let e = data[Self.key(url)], Date().timeIntervalSince1970 - e.t < Self.ttl else { return nil }
            return e.s
        }
    }

    func put(_ url: String, _ status: StreamStatus) {
        lock.withLock { data[Self.key(url)] = Entry(s: status, t: Date().timeIntervalSince1970) }
    }

    func save() {
        let snapshot: [String: Entry] = lock.withLock {
            let now = Date().timeIntervalSince1970
            return data.filter { now - $0.value.t < Self.ttl }
        }
        try? JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
    }

    func apply(_ channels: [Channel]) {
        for ch in channels {
            ch.streams = ch.streams.map { var s = $0; s.status = get(s.url) ?? .unknown; return s }
        }
    }
}

/// Quick "is this channel alive?" check, so dead links are marked before you tap them.
enum Health {
    private static let staleMinutes: TimeInterval = 30
    private static let hlsTypes = ["mpegurl", "video/", "audio/", "octet-stream", "mp2t"]
    private static let programDateTime = try! NSRegularExpression(pattern: #"#EXT-X-PROGRAM-DATE-TIME:\s*(\S+)"#)

    private static func trimmedStart(_ d: Data) -> Data {
        d.drop { [9, 10, 11, 12, 13, 32].contains($0) }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func looksLikeVideo(_ body: Data, contentType: String) -> Bool {
        let t = trimmedStart(body)
        if t.starts(with: Array("#EXTM3U".utf8)) { return true }
        if body.first == 0x47 { return true }      // MPEG-TS sync byte
        return hlsTypes.contains { contentType.contains($0) } && !t.starts(with: [UInt8(ascii: "<")])
    }

    private static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for candidate in [s, s + "Z"] {
            if let d = withFraction.date(from: candidate) ?? plain.date(from: candidate) { return d }
        }
        return nil
    }

    /// A live playlist whose newest timestamp is old has frozen: it answers, but never plays.
    private static func freshMediaPlaylist(_ text: String) -> Bool {
        if !text.contains("#EXTINF") || text.contains("#EXT-X-ENDLIST") { return true }
        let ns = text as NSString
        guard let last = programDateTime.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let newest = parseDate(ns.substring(with: last.range(at: 1))) else { return true }
        return Date().timeIntervalSince(newest) < staleMinutes * 60
    }

    /// Fetch the start of the newest video segment. Geo-blocking is usually enforced here, not on
    /// the playlist, so a playlist that loads can still be unwatchable from your country.
    private static func segmentOK(_ playlistURL: URL, _ text: String, _ headers: [String: String],
                                  _ timeout: TimeInterval) async -> Bool {
        guard let uri = lines(text).last(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              let segment = URL(string: uri, relativeTo: playlistURL)?.absoluteString,
              let peek = try? await Net.peek(segment, limit: 2048, timeout: timeout, headers: headers)
        else { return false }
        return !peek.body.isEmpty && !trimmedStart(peek.body).starts(with: [UInt8(ascii: "<")])
    }

    private static func mediaOK(_ url: URL, _ text: String, _ headers: [String: String],
                                _ timeout: TimeInterval) async -> Bool {
        if !text.contains("#EXTINF") { return true }
        guard freshMediaPlaylist(text) else { return false }
        return await segmentOK(url, text, headers, timeout)
    }

    static func probe(_ url: String, userAgent: String, referrer: String, timeout: TimeInterval = 8) async -> Bool {
        var headers = ["User-Agent": userAgent.isEmpty ? Net.playerUA : userAgent]
        if !referrer.isEmpty { headers["Referer"] = referrer }
        guard let first = try? await Net.peek(url, limit: 65536, timeout: timeout, headers: headers),
              looksLikeVideo(first.body, contentType: first.contentType) else { return false }
        let text = String(decoding: first.body, as: UTF8.self)
        guard text.contains("#EXT-X-STREAM-INF") else {
            return await mediaOK(first.finalURL, text, headers, timeout)
        }
        // A master playlist can be served while every quality behind it is dead; check the first one.
        let all = lines(text)
        guard let i = all.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return true }
        guard let variant = all[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              let variantURL = URL(string: variant, relativeTo: first.finalURL)?.absoluteString,
              let sub = try? await Net.peek(variantURL, limit: 65536, timeout: timeout, headers: headers),
              trimmedStart(sub.body).starts(with: Array("#EXTM3U".utf8)) else { return false }
        return await mediaOK(sub.finalURL, String(decoding: sub.body, as: UTF8.self), headers, timeout)
    }

    /// Probe one stream; for http:// addresses try the https:// version first and keep it if it works.
    static func checkStream(_ stream: StreamInfo) async -> StreamInfo {
        var s = stream
        if s.url.lowercased().hasPrefix("http://") {
            let secure = "https://" + s.url.dropFirst(7)
            if await probe(secure, userAgent: s.userAgent, referrer: s.referrer, timeout: 5) {
                s.url = secure
                s.status = .ok
                return s
            }
        }
        s.status = await probe(s.url, userAgent: s.userAgent, referrer: s.referrer) ? .ok : .dead
        return s
    }

    static func checkChannel(key: String, streams: [StreamInfo], cache: HealthCache) async -> (String, [StreamInfo]) {
        var out = streams
        for i in out.indices {
            if Task.isCancelled { break }
            out[i] = await checkStream(out[i])
            cache.put(out[i].url, out[i].status)
        }
        return (key, out)
    }
}
