import ImageIO
import SwiftUI

/// Downloads channel logos once, keeps them on disk, and shrinks them to card size.
/// Only https addresses are used, and a redirect can't lead to an unencrypted one.
actor LogoLoader {
    static let shared = LogoLoader()

    private let memory = NSCache<NSURL, CGImage>()
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20,
                                   directory: Paths.cache.appendingPathComponent("Logos", isDirectory: true))
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    init() { memory.countLimit = 600 }

    func image(for url: URL) async -> CGImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if failed.contains(url) { return nil }
        if let pending = inFlight[url] { return await pending.value }
        let session = session
        let task = Task { await Self.fetch(url, session: session) }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) } else { failed.insert(url) }
        return image
    }

    private static func fetch(_ url: URL, session: URLSession) async -> CGImage? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Net.appUA, forHTTPHeaderField: "User-Agent")
        let redirects = RedirectGuard(allowHTTP: false)
        guard let (data, response) = try? await session.data(for: request, delegate: redirects),
              redirects.refused == nil, (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 3 << 20,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A channel's picture: its group's gradient, with the logo on a light plate (or big initials when
/// there's no logo). `hero` lays it out for the wide featured banner.
struct ChannelArt: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    var hero = false
    @State private var logo: CGImage?

    private var logoURL: URL? {
        guard model.settings.showLogos, !channel.logo.isEmpty else { return nil }
        return URL(string: channel.logo)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: hero ? .trailing : .center) {
                Theme.gradient(for: Theme.primaryGroup(channel))
                    .hueRotation(.degrees(Theme.hueShift(channel.key)))
                RadialGradient(colors: [.white.opacity(0.28), .clear], center: .topLeading,
                               startRadius: 0, endRadius: max(size.width, size.height))
                if let logo {
                    // Fit the logo in its box, then wrap the plate tightly around it.
                    let box = CGSize(width: size.width * (hero ? 0.28 : 0.52), height: size.height * (hero ? 0.36 : 0.46))
                    let ratio = CGFloat(logo.width) / CGFloat(max(logo.height, 1))
                    let fitted = ratio > box.width / box.height
                        ? CGSize(width: box.width, height: box.width / ratio)
                        : CGSize(width: box.height * ratio, height: box.height)
                    Image(decorative: logo, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .padding(hero ? 24 : max(6, size.height * 0.07))
                        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: hero ? 22 : 10, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: hero ? 20 : 6, y: hero ? 10 : 3)
                        .padding(.trailing, hero ? size.width * 0.1 : 0)
                        .transition(.opacity)
                } else {
                    Text(Theme.initials(channel.name))
                        .font(.system(size: size.height * (hero ? 0.42 : 0.34), weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(hero ? 0.35 : 0.9))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        .padding(.trailing, hero ? size.width * 0.1 : 0)
                }
            }
        }
        .task(id: logoURL) {
            guard let url = logoURL else {
                logo = nil
                return
            }
            let image = await LogoLoader.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.25)) { logo = image }
        }
    }
}
