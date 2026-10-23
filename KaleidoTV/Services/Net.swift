import Foundation

/// Small, careful HTTP helpers: system-verified TLS, size limits, no scheme downgrades on redirect.
struct FetchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Net {
    static let appUA = "KaleidoTV/1.1"
    /// The health check identifies itself the way the player does, so servers answer it the same way.
    static let playerUA = "AppleCoreMedia/1.0.0 (iPhone; U; CPU OS 18_0 like Mac OS X; en_us)"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static func isWebURL(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func host(of s: String) -> String {
        (URL(string: s)?.host ?? "").lowercased()
    }

    /// Addresses to try, encrypted first: https://x, then the original http://x.
    static func httpsFirst(_ s: String) -> [String] {
        s.lowercased().hasPrefix("http://") ? ["https://" + s.dropFirst(7), s] : [s]
    }

    static func describe(_ error: Error?) -> String {
        switch error {
        case let e as FetchError: e.message
        case let e as URLError: e.localizedDescription
        case let e?: String(describing: e).prefix(200).description
        case nil: "unknown error"
        }
    }

    // MARK: - Requests

    private static func request(_ s: String, timeout: TimeInterval, allowHTTP: Bool,
                                headers: [String: String]) throws -> URLRequest {
        guard isWebURL(s), let url = URL(string: s) else {
            throw FetchError("Only http(s) addresses are allowed")
        }
        if s.lowercased().hasPrefix("http://") && !allowHTTP {
            throw FetchError("Unencrypted http:// is not allowed for this source")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(appUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private static func check(_ response: URLResponse, _ redirects: RedirectGuard) throws -> HTTPURLResponse {
        if let refused = redirects.refused {
            throw FetchError("Refused a redirect to a \(refused) address")
        }
        guard let http = response as? HTTPURLResponse else { throw FetchError("not a web response") }
        guard (200..<300).contains(http.statusCode) else { throw FetchError("server answered \(http.statusCode)") }
        return http
    }

    /// Download a (size-capped) response to `dest`, replacing it only on success. Gzipped files are unpacked.
    static func download(_ s: String, to dest: URL, maxBytes: Int, timeout: TimeInterval = 60,
                         allowHTTP: Bool = false, headers: [String: String] = [:]) async throws {
        let req = try request(s, timeout: timeout, allowHTTP: allowHTTP, headers: headers)
        let redirects = RedirectGuard(allowHTTP: allowHTTP)
        let tmp: URL
        let response: URLResponse
        do {
            (tmp, response) = try await session.download(for: req, delegate: redirects)
        } catch {
            throw FetchError(describe(error))
        }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tmp) }
        _ = try check(response, redirects)
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw FetchError("Download is larger than allowed") }

        let part = dest.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        do {
            if Gzip.hasMagic(tmp) {
                try Gzip.decompress(tmp, to: part, limit: maxBytes * 8)
            } else {
                try fm.moveItem(at: tmp, to: part)
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: part, to: dest)
        } catch {
            try? fm.removeItem(at: part)
            throw FetchError(describe(error))
        }
    }

    /// Download a whole (size-capped) response into memory.
    static func fetch(_ s: String, maxBytes: Int = 64 << 20, timeout: TimeInterval = 30,
                      allowHTTP: Bool = false, headers: [String: String] = [:]) async throws -> Data {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        try await download(s, to: dest, maxBytes: maxBytes, timeout: timeout, allowHTTP: allowHTTP, headers: headers)
        return try Data(contentsOf: dest)
    }

    struct Peek {
        let finalURL: URL
        let contentType: String
        let body: Data
    }

    /// Read only the first `limit` bytes of a response (used by the health check).
    static func peek(_ s: String, limit: Int, timeout: TimeInterval, headers: [String: String]) async throws -> Peek {
        let req = try request(s, timeout: timeout, allowHTTP: true, headers: headers)
        let redirects = RedirectGuard(allowHTTP: true)
        do {
            let (bytes, response) = try await session.bytes(for: req, delegate: redirects)
            defer { bytes.task.cancel() }
            let http = try check(response, redirects)
            var body = Data()
            body.reserveCapacity(limit)
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { break }
            }
            return Peek(finalURL: http.url ?? req.url!,
                        contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
                        body: body)
        } catch let e as FetchError {
            throw e
        } catch {
            throw FetchError(describe(error))
        }
    }
}

/// Lets a redirect through only to https (or to http when that's allowed for this source).
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowHTTP: Bool
    private(set) var refused: String?

    init(allowHTTP: Bool) { self.allowHTTP = allowHTTP }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let scheme = request.url?.scheme?.lowercased() ?? ""
        if scheme == "https" || (scheme == "http" && allowHTTP) {
            completionHandler(request)
        } else {
            refused = scheme.isEmpty ? "non-web" : scheme
            completionHandler(nil)
        }
    }
}
