import CryptoKit
import Foundation
import os

/// Programme guide (XMLTV): download, keep only what's on around now, answer "now / next".
struct Programme: Sendable {
    let start: Date
    let stop: Date
    let title: String
}

struct Guide: Sendable {
    var progs: [String: [Programme]] = [:]

    mutating func merge(_ parsed: [String: [Programme]]) {
        for (cid, list) in parsed where progs[cid] == nil {   // the first guide that knows a channel wins
            progs[cid] = list
        }
    }

    func nowNext(_ epgID: String) -> (now: Programme?, next: Programme?) {
        guard !epgID.isEmpty, let list = progs[EPG.normID(epgID)] else { return (nil, nil) }
        let now = Date()
        for (i, p) in list.enumerated() {
            if p.start <= now && now < p.stop { return (p, i + 1 < list.count ? list[i + 1] : nil) }
            if p.start > now { return (nil, p) }
        }
        return (nil, nil)
    }
}

enum EPG {
    private static let log = Logger(subsystem: "KaleidoTV", category: "epg")
    static let cacheTTL: TimeInterval = 12 * 3600
    static let maxBytes = 400 << 20

    static func normID(_ id: String) -> String {
        String(id.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// XMLTV time: "20261022193000 +0100" (the offset is optional and means UTC when missing).
    static func parseTime(_ value: String) -> Date? {
        let v = Array(value.trimmingCharacters(in: .whitespaces).utf8)
        guard v.count >= 14 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            var n = 0
            for c in v[a..<b] {
                guard c >= 48 && c <= 57 else { return nil }
                n = n * 10 + Int(c - 48)
            }
            return n
        }
        guard let y = num(0, 4), let mo = num(4, 6), let d = num(6, 8), let h = num(8, 10),
              let mi = num(10, 12), let s = num(12, 14), (1...12).contains(mo) else { return nil }
        var seconds = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
        let tz = String(decoding: v[14...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let tzBytes = Array(tz.utf8)
        if tzBytes.count == 5, tzBytes[0] == UInt8(ascii: "+") || tzBytes[0] == UInt8(ascii: "-"),
           let oh = Int(tz.dropFirst().prefix(2)), let om = Int(tz.suffix(2)) {
            let offset = oh * 3600 + om * 60
            seconds -= tzBytes[0] == UInt8(ascii: "+") ? offset : -offset
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Cached download; the cache file name is a hash, so private addresses aren't written to disk.
    static func download(_ url: String, allowHTTP: Bool) async throws -> URL {
        let hash = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let path = Paths.cache.appendingPathComponent("epg_\(hash).xml")
        if Sources.isFresh(path, ttl: cacheTTL) { return path }
        var last: Error?
        for candidate in allowHTTP ? Net.httpsFirst(url) : [url] {
            do {
                try await Net.download(candidate, to: path, maxBytes: maxBytes, timeout: 120, allowHTTP: allowHTTP)
                return path
            } catch {
                last = error
            }
        }
        if FileManager.default.fileExists(atPath: path.path) { return path }   // an older guide is better than none
        throw FetchError(Net.describe(last))
    }

    /// Read programmes for the wanted channel ids, from 2 hours ago to 36 hours ahead.
    static func parse(_ file: URL, wanted: Set<String>) -> [String: [Programme]] {
        guard let stream = InputStream(url: file) else { return [:] }
        let now = Date()
        let reader = XMLTVReader(wanted: wanted, from: now.addingTimeInterval(-2 * 3600),
                                 to: now.addingTimeInterval(36 * 3600))
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        return reader.out.mapValues { $0.sorted { $0.start < $1.start } }
    }

    static func build(jobs: [(url: String, allowHTTP: Bool)], wanted: Set<String>) async -> Guide {
        var merged = Guide()
        for job in jobs {
            do {
                merged.merge(parse(try await download(job.url, allowHTTP: job.allowHTTP), wanted: wanted))
            } catch {
                log.warning("Programme guide failed: \(Net.describe(error))")
            }
        }
        return merged
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func format(_ p: Programme?) -> String {
        guard let p else { return "" }
        return "\(clock.string(from: p.start))–\(clock.string(from: p.stop))  \(p.title)"
    }
}

private final class XMLTVReader: NSObject, XMLParserDelegate {
    let wanted: Set<String>
    let lo: Date
    let hi: Date
    var out: [String: [Programme]] = [:]
    private var current: (cid: String, start: Date, stop: Date)?
    private var inTitle = false
    private var gotTitle = false
    private var title = ""

    init(wanted: Set<String>, from lo: Date, to hi: Date) {
        self.wanted = wanted
        self.lo = lo
        self.hi = hi
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "programme" {
            current = nil
            gotTitle = false
            title = ""
            let cid = EPG.normID(attributes["channel"] ?? "")
            guard wanted.contains(cid),
                  let start = EPG.parseTime(attributes["start"] ?? ""),
                  let stop = EPG.parseTime(attributes["stop"] ?? ""),
                  stop > lo, start < hi else { return }
            current = (cid, start, stop)
        } else if name == "title", current != nil, !gotTitle {
            inTitle = true
            title = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { title += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "title" && inTitle {
            inTitle = false
            gotTitle = true
        } else if name == "programme", let c = current {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            out[c.cid, default: []].append(Programme(start: c.start, stop: c.stop, title: t.isEmpty ? "(untitled)" : t))
            current = nil
        }
    }
}
