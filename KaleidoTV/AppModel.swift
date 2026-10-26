import AVFoundation
import Observation
import SwiftUI
import os

@MainActor @Observable
final class AppModel {
    var settings = AppSettings() {
        didSet {
            settings.save()
            if oldValue.bufferSeconds != settings.bufferSeconds { playback.bufferSeconds = settings.bufferSeconds }
        }
    }

    // Channel lists
    private(set) var channels: [String: Channel] = [:]
    private(set) var sourceInfo: [String: String] = [:]   // source id -> status text
    private(set) var guide = Guide()
    private(set) var loadingFree = false
    private(set) var freeListError: String?
    private(set) var countryNames: [String: (name: String, flag: String)] = [:]
    var statusLine = "Loading channel lists…"
    @ObservationIgnored private var freeChannels: [Channel] = []
    @ObservationIgnored private var paid: [String: [Channel]] = [:]       // source id -> its channels
    @ObservationIgnored private var sourceEPG: [String: [String]] = [:]   // source id -> guide addresses
    @ObservationIgnored private var pendingLoads = 0

    // What the screen shows. Sorted only when asked, so cards don't jump about while a check runs.
    var group = "Home" {
        didSet {
            guard group != oldValue else { return }
            if query.isEmpty { refreshList() } else { query = "" }   // clearing the search also refreshes
        }
    }
    var query = "" { didSet { if query != oldValue { refreshList() } } }
    var country: String? { didSet { if country != oldValue { refreshList() } } }
    private(set) var visible: [Channel] = []                 // the grid: one category, or search results
    private(set) var rails: [String: [Channel]] = [:]        // group -> its channels, for the home rows
    private(set) var recentChannels: [Channel] = []
    private(set) var featured: [Channel] = []                // the banner at the top of Home
    private(set) var groupCounts: [String: Int] = [:]

    // Health check
    private(set) var checking = false
    private(set) var checkDone = 0
    private(set) var checkTotal = 0
    @ObservationIgnored let healthCache = HealthCache()

    // Playback
    let playback = PlaybackController()
    private(set) var current: Channel?
    private(set) var lastChannel: Channel?
    private(set) var playStatus = ""

    /// Sources or Settings, when one is open (the Mac menu bar opens them too).
    var sheet: AppSheet?

    private static let log = Logger(subsystem: "KaleidoTV", category: "app")

    init() {
        settings = AppSettings.load()
        playback.bufferSeconds = settings.bufferSeconds
        playback.onEvent = { [weak self] kind, message, channel, stream in
            self?.playerEvent(kind, message, channel, stream)
        }
        refreshGroups()
        reloadAll()
    }

    /// The tabs across the top: Home, then every group that has channels (My List and All always).
    var categories: [String] {
        ["Home"] + ChannelGroup.all.filter {
            $0 == "Favourites" || $0 == "All channels" || (groupCounts[$0] ?? 0) > 0
        }
    }

    /// The countries that actually have channels, by name.
    var availableCountries: [String] {
        Set(channels.values.map(\.country)).filter { !$0.isEmpty }.sorted { countryName($0) < countryName($1) }
    }

    func countryName(_ code: String) -> String {
        countryNames[code]?.name ?? Countries.name(code)
    }

    /// "🇬🇧 United Kingdom", or just the name when there's no flag.
    func countryLabel(_ code: String) -> String {
        guard !code.isEmpty else { return "" }
        let flag = countryNames[code]?.flag ?? ""
        return flag.isEmpty ? countryName(code) : "\(flag) \(countryName(code))"
    }

    func saveState() {
        settings.save()
        healthCache.save()
    }

    // MARK: - Loading

    func reloadAll(force: Bool = false) {
        statusLine = "Loading channel lists…"
        pendingLoads = 1 + settings.sources.count
        loadingFree = true
        freeListError = nil
        let countries = settings.worldwide ? nil : settings.countries
        let showLogos = settings.showLogos
        Task {
            do {
                let list = try await Sources.loadFreeChannels(countries: countries, force: force)
                async let names = Sources.countryNames(force: force)
                let logos = showLogos ? await Sources.logos(force: force) : [:]
                for c in list {
                    if let logo = logos[String(c.key.dropFirst("free:".count))] { c.logo = logo }
                }
                countryNames = await names
                freeLoaded(list)
            } catch {
                freeFailed(error)
            }
        }
        for src in settings.sources { loadSource(src) }
    }

    private func loadSource(_ src: SourceRecord) {
        sourceInfo[src.id] = "loading…"
        Task {
            do {
                sourceLoaded(src, try await Sources.loadUserSource(src))
            } catch {
                sourceFailed(src, error)
            }
        }
    }

    private func freeLoaded(_ list: [Channel]) {
        healthCache.apply(list)
        freeChannels = list
        loadingFree = false
        rebuild()
        statusLine = "\(list.count) free channels loaded."
        loadFinished()
        let stale = list.filter { $0.status == .unknown }
        if !stale.isEmpty { startCheck(fast: stale, label: "free channels") }
    }

    private func freeFailed(_ error: Error) {
        loadingFree = false
        freeListError = Net.describe(error)
        statusLine = "Couldn't load the free channel list (\(Net.describe(error))). Check your internet "
            + "connection, then refresh."
        loadFinished()
    }

    private func sourceLoaded(_ src: SourceRecord, _ result: SourceLoad) {
        // The source may have been removed while it was loading.
        guard settings.sources.contains(where: { $0.id == src.id }) else { return loadFinished() }
        healthCache.apply(result.channels)
        paid[src.id] = result.channels
        sourceEPG[src.id] = result.epgURLs
        let lock = result.secure ? "encrypted (https)" : "NOT encrypted – your provider doesn't offer https"
        sourceInfo[src.id] = "\(result.channels.count) channels, connection \(lock)"
        rebuild()
        loadFinished()
    }

    private func sourceFailed(_ src: SourceRecord, _ error: Error) {
        sourceInfo[src.id] = "failed: \(Net.describe(error))"
        statusLine = "Couldn't load “\(src.name)”: \(Net.describe(error))"
        loadFinished()
    }

    private func loadFinished() {
        pendingLoads -= 1
        if pendingLoads <= 0 { loadGuides() }
    }

    private func loadGuides() {
        var jobs = settings.epgURLs.filter { $0.lowercased().hasPrefix("https://") }.map { (url: $0, allowHTTP: false) }
        jobs += settings.epgURLs.filter { $0.lowercased().hasPrefix("http://") }.map { (url: $0, allowHTTP: true) }
        for urls in sourceEPG.values { jobs += urls.map { (url: $0, allowHTTP: true) } }
        let wanted = Set(channels.values.compactMap { $0.epgID.isEmpty ? nil : EPG.normID($0.epgID) })
        guard !jobs.isEmpty, !wanted.isEmpty else { return }
        Task {
            let loaded = await EPG.build(jobs: jobs, wanted: wanted)
            guide = loaded
            if !loaded.progs.isEmpty { statusLine = "Programme guide loaded for \(loaded.progs.count) channels." }
        }
    }

    // MARK: - Channel lists

    private func rebuild() {
        var all: [String: Channel] = [:]
        for c in freeChannels { all[c.key] = c }
        for list in paid.values { for c in list { all[c.key] = c } }
        channels = all
        if let country, !availableCountries.contains(country) { self.country = nil }
        refreshGroups()
        refreshList()
        if featured.count < 3 { refreshFeatured() }
    }

    private func inGroup(_ c: Channel, _ group: String) -> Bool {
        switch group {
        case "All channels": true
        case "Favourites": settings.favourites.contains(c.key)
        default: c.groups.contains(group)
        }
    }

    private func refreshGroups() {
        var counts: [String: Int] = [:]
        for g in ChannelGroup.all { counts[g] = channels.values.reduce(0) { $0 + (inGroup($1, g) ? 1 : 0) } }
        groupCounts = counts
    }

    func refreshList() {
        let favourites = Set(settings.favourites)
        let pool = channels.values
            .filter { c in country == nil || c.country.isEmpty || c.country == country }
            .sorted { ($0.status.rank, $0.name.lowercased()) < ($1.status.rank, $1.name.lowercased()) }
        var byGroup: [String: [Channel]] = [:]
        for c in pool {
            for g in c.groups { byGroup[g, default: []].append(c) }
            if favourites.contains(c.key) { byGroup["Favourites", default: []].append(c) }
        }
        byGroup["All channels"] = pool
        rails = byGroup
        refreshRecent()

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            visible = pool.filter { $0.name.lowercased().contains(q) }
        } else {
            visible = group == "Home" ? [] : byGroup[group] ?? []
        }
    }

    private func refreshRecent() {
        recentChannels = settings.recent.compactMap { channels[$0] }
            .filter { country == nil || $0.country.isEmpty || $0.country == country }
    }

    /// Up to eight channels for the banner: favourites first, then a mix of working channels with logos
    /// from the more visual groups. Chosen afresh at launch and after each check, not on every change.
    private func refreshFeatured() {
        let showcase: Set<String> = ["Movies", "Entertainment", "Kids", "Football", "Cricket", "Tennis", "Sports"]
        func good(_ c: Channel) -> Bool { c.status != .dead && !c.groups.isDisjoint(with: showcase) }
        let favourites = settings.favourites.compactMap { channels[$0] }.filter { $0.status == .ok }
        var candidates = channels.values.filter { good($0) && $0.status == .ok && !$0.logo.isEmpty }
        if candidates.count < 8 { candidates += channels.values.filter { good($0) && !$0.logo.isEmpty } }
        if candidates.count < 8 { candidates += channels.values.filter(good) }
        var seen = Set<String>()
        featured = (favourites.shuffled().prefix(3) + candidates.shuffled())
            .filter { seen.insert($0.key).inserted }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - Favourites and picture

    func isFavourite(_ c: Channel) -> Bool { settings.favourites.contains(c.key) }

    func toggleFavourite(_ c: Channel) {
        if let i = settings.favourites.firstIndex(of: c.key) {
            settings.favourites.remove(at: i)
        } else {
            settings.favourites.append(c.key)
        }
        refreshGroups()
        refreshList()
    }

    func picture(for c: Channel) -> PictureMode {
        PictureMode(rawValue: settings.aspect[c.key] ?? "") ?? .fit
    }

    func setPicture(_ mode: PictureMode, for c: Channel) {
        settings.aspect[c.key] = mode == .fit ? nil : mode.rawValue
    }

    // MARK: - Playback

    /// Leaving the player stops playback, unless the picture is floating in Picture in Picture.
    func leavePlayer() {
        if !playback.pipActive { stop() }
    }

    func play(_ c: Channel) {
        current = c
        lastChannel = c
        settings.recent.removeAll { $0 == c.key }
        settings.recent.insert(c.key, at: 0)
        if settings.recent.count > 20 { settings.recent.removeLast(settings.recent.count - 20) }
        refreshRecent()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        playback.play(c)
    }

    func stop() {
        guard current != nil else { return }
        playback.stop()
        current = nil
        playStatus = "Stopped."
    }

    private func setStatus(_ c: Channel, url: String, _ status: StreamStatus) {
        if let i = c.streams.firstIndex(where: { $0.url == url }) { c.streams[i].status = status }
        healthCache.put(url, status)
    }

    private func playerEvent(_ kind: PlaybackController.Event, _ message: String, _ channel: Channel?,
                             _ stream: StreamInfo?) {
        switch kind {
        case .streamDead:
            if let channel, let stream { setStatus(channel, url: stream.url, .dead) }
        case .playing:
            if let channel, let stream { setStatus(channel, url: stream.url, .ok) }
        case .failed:
            if let channel { for s in channel.streams { setStatus(channel, url: s.url, .dead) } }
        default:
            break
        }
        if !message.isEmpty { playStatus = message }
        if kind == .failed || kind == .lost { current = nil }
    }

    // MARK: - Health check

    private func startCheck(fast: [Channel], slow: [Channel] = [], label: String) {
        guard !checking else { return }
        let total = fast.count + slow.count
        guard total > 0 else { return }
        checking = true
        checkDone = 0
        checkTotal = total
        statusLine = "Checking \(total) \(label)…"
        let cache = healthCache
        // Free channels are checked 12 at a time; paid ones one at a time, as providers limit connections.
        let batches = [(fast.map { ($0.key, $0.streams) }, 12), (slow.map { ($0.key, $0.streams) }, 1)]
        Task {
            for (jobs, width) in batches where !jobs.isEmpty {
                await withTaskGroup(of: (String, [StreamInfo]).self) { group in
                    var pending = jobs.makeIterator()
                    for _ in 0..<width {
                        guard let (key, streams) = pending.next() else { break }
                        group.addTask { await Health.checkChannel(key: key, streams: streams, cache: cache) }
                    }
                    for await (key, streams) in group {
                        checkProgress(key, streams)
                        if let (key, streams) = pending.next() {
                            group.addTask { await Health.checkChannel(key: key, streams: streams, cache: cache) }
                        }
                    }
                }
            }
            cache.save()
            checkFinished()
        }
    }

    private func checkProgress(_ key: String, _ streams: [StreamInfo]) {
        channels[key]?.streams = streams
        checkDone += 1
        if checkDone % 10 == 0 || checkDone == checkTotal {
            statusLine = "Checking channels… \(checkDone) of \(checkTotal)"
        }
        // Re-sort now and then so live channels rise to the front, unless you are busy watching or searching.
        if checkDone % 60 == 0 && current == nil && query.isEmpty { refreshList() }
    }

    private func checkFinished() {
        checking = false
        let live = channels.values.filter { $0.status == .ok }.count
        let dead = channels.values.filter { $0.status == .dead }.count
        statusLine = "Check finished: \(live) channels live, \(dead) offline."
        refreshList()
        refreshFeatured()
    }

    /// The channels the check button would test: the open category, or the search results.
    private var checkable: [Channel] { group == "Home" && query.isEmpty ? rails["All channels"] ?? [] : visible }

    var checkablePaidCount: Int { checkable.filter { !$0.free }.count }

    func checkVisible(includePaid: Bool) {
        if checking {
            statusLine = "A channel check is already running."
            return
        }
        startCheck(fast: checkable.filter(\.free), slow: includePaid ? checkable.filter { !$0.free } : [],
                   label: "channels")
    }

    // MARK: - Sources

    private func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    private func addSource(_ src: SourceRecord) {
        settings.sources.append(src)
        pendingLoads += 1
        loadSource(src)
        statusLine = "Loading “\(src.name)”…"
    }

    func addM3UURL(name: String, url: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Net.isWebURL(url) else { throw FetchError("The address must start with https:// or http://") }
        let src = SourceRecord(id: newID(), name: name, kind: .m3uURL)
        try Keychain.save(["url": url], for: src.id)
        addSource(src)
    }

    func addXtream(name: String, server: String, username: String, password: String) throws {
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty else {
            throw FetchError("Please fill in every box.")
        }
        let src = SourceRecord(id: newID(), name: name, kind: .xtream)
        try Keychain.save(["server": server, "username": username, "password": password], for: src.id)
        addSource(src)
    }

    /// Copies a playlist the user picked into the app, so it keeps working after they move the original.
    func addM3UFile(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 200 << 20 else { throw FetchError("That file is too large to be a playlist.") }
        let data = try Data(contentsOf: url)
        let src = SourceRecord(id: newID(), name: url.deletingPathExtension().lastPathComponent, kind: .m3uFile)
        try data.write(to: Paths.playlist(src.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        addSource(src)
    }

    func addGuide(_ url: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Net.isWebURL(url) else { throw FetchError("The address must start with https:// or http://") }
        settings.epgURLs.append(url)
        loadGuides()
    }

    func removeSource(_ src: SourceRecord) {
        settings.sources.removeAll { $0.id == src.id }
        paid[src.id] = nil
        sourceEPG[src.id] = nil
        sourceInfo[src.id] = nil
        let prefix = src.id + ":"
        settings.favourites.removeAll { $0.hasPrefix(prefix) }
        settings.recent.removeAll { $0.hasPrefix(prefix) }
        Keychain.delete(src.id)
        try? FileManager.default.removeItem(at: Paths.playlist(src.id))
        if current?.key.hasPrefix(prefix) == true { stop() }
        rebuild()
    }

    func removeGuide(_ url: String) {
        settings.epgURLs.removeAll { $0 == url }
        rebuild()
    }
}
