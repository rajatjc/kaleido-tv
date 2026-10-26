import AVFoundation
import Observation

/// Playback on top of AVPlayer, with buffering, automatic reconnect and automatic switch to backup streams.
@MainActor @Observable
final class PlaybackController {
    enum Event { case opening, playing, reconnecting, switching, streamDead, failed, lost }
    typealias Handler = (Event, String, Channel?, StreamInfo?) -> Void

    static let retryDelays: [TimeInterval] = [2, 5, 10]   // waits before reconnecting a stream that was playing and dropped
    static let startRetryDelays: [TimeInterval] = [2]     // a stream that never started gets one quick retry, then the backup
    static let keepTryingSeconds: TimeInterval = 180      // once a channel has played, keep reconnecting through an outage this long
    static let stallSeconds: TimeInterval = 15            // playing but the clock hasn't moved for this long = dropped
    static let openTimeout: TimeInterval = 25             // still opening/buffering after this long = failed
    static let stableSeconds: TimeInterval = 30           // after this much smooth playback, the retry budget resets

    let player = AVPlayer()
    var pipActive = false

    @ObservationIgnored var onEvent: Handler = { _, _, _, _ in }
    @ObservationIgnored var bufferSeconds: TimeInterval = 15 {
        didSet { player.currentItem?.preferredForwardBufferDuration = bufferSeconds }
    }

    @ObservationIgnored private(set) var channel: Channel?
    @ObservationIgnored private var streams: [StreamInfo] = []
    @ObservationIgnored private var idx = 0
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var retryAt: TimeInterval?
    @ObservationIgnored private var openedAt: TimeInterval = 0
    @ObservationIgnored private var lastProgress: TimeInterval = 0
    @ObservationIgnored private var lastMarker: Double?
    @ObservationIgnored private var advanced = false            // the playback clock has moved since this stream opened
    @ObservationIgnored private var playingReported = false
    @ObservationIgnored private var playedThisSession = false   // any stream of this channel played since you pressed play
    @ObservationIgnored private var streamPlayed = false        // the current stream played
    @ObservationIgnored private var troubleSince: TimeInterval?
    @ObservationIgnored private var itemEnded = false
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func label() -> String {
        streams.count > 1 ? " (stream \(idx + 1) of \(streams.count))" : ""
    }

    private func resetState() {
        idx = 0
        retries = 0
        retryAt = nil
        openedAt = 0
        lastProgress = 0
        lastMarker = nil
        advanced = false
        playingReported = false
        playedThisSession = false
        streamPlayed = false
        troubleSince = nil
    }

    // MARK: - Public

    func play(_ channel: Channel) {
        stop()
        self.channel = channel
        streams = channel.orderedStreams()
        resetState()
        if streams.isEmpty {
            onEvent(.failed, "This channel has no streams.", channel, nil)
            self.channel = nil
            return
        }
        open()
    }

    func stop() {
        channel = nil
        retryAt = nil
        halt()
    }

    // MARK: - Internals

    private func halt() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
    }

    private func open() {
        let s = streams[idx]
        halt()
        guard let url = URL(string: s.url) else {
            fail("the address isn't valid")
            return
        }
        var options: [String: Any] = [:]
        if !s.userAgent.isEmpty { options[AVURLAssetHTTPUserAgentKey] = s.userAgent }
        if !s.referrer.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = ["Referer": s.referrer] }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = bufferSeconds
        itemEnded = false
        for name in [AVPlayerItem.failedToPlayToEndTimeNotification, AVPlayerItem.didPlayToEndTimeNotification] {
            itemObservers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.itemEnded = true }
            })
        }
        player.replaceCurrentItem(with: item)
        player.play()
        let t = now
        openedAt = t
        lastProgress = t
        lastMarker = nil
        advanced = false
        playingReported = false
        onEvent(.opening, "Connecting\(label())…", channel, s)
    }

    /// Called once a second.
    private func tick() {
        guard channel != nil else { return }
        let t = now
        if let at = retryAt {
            if t >= at {
                retryAt = nil
                open()
            }
            return
        }
        guard let item = player.currentItem else { return }
        if item.status == .failed || itemEnded {
            fail(item.status == .failed ? "the stream stopped" : "the stream ended")
            return
        }
        let seconds = player.currentTime().seconds
        let marker: Double? = seconds.isFinite ? seconds : nil
        if marker != lastMarker {
            if lastMarker != nil { advanced = true }
            lastMarker = marker
            lastProgress = t
        }
        switch player.timeControlStatus {
        case .playing:
            if advanced && !playingReported {
                playingReported = true
                streamPlayed = true
                playedThisSession = true
                troubleSince = nil
                onEvent(.playing, "Playing\(label())", channel, streams[idx])
            }
            if streamPlayed && t - openedAt > Self.stableSeconds { retries = 0 }
            if t - lastProgress > Self.stallSeconds { fail("the picture froze") }
        case .paused:
            lastProgress = t   // paused by the viewer: waiting is not a failure
        default:
            if t - lastProgress > Self.openTimeout {
                fail(streamPlayed ? "the picture froze" : "it took too long to start")
            }
        }
    }

    private func fail(_ reason: String) {
        halt()
        let t = now
        let stream = streams[idx]
        if playedThisSession && troubleSince == nil { troubleSince = t }
        let delays = streamPlayed ? Self.retryDelays : Self.startRetryDelays
        if retries < delays.count {
            let delay = delays[retries]
            retries += 1
            retryAt = t + delay
            let what = playedThisSession ? "Connection lost" : "Couldn't start"
            onEvent(.reconnecting, "\(what) (\(reason)). Retrying in \(Int(delay))s…", channel, stream)
            return
        }
        if !playedThisSession {
            // Never played at all since you pressed play: this stream is genuinely broken.
            onEvent(.streamDead, "", channel, stream)
        }
        retries = 0
        streamPlayed = false
        idx += 1
        if idx >= streams.count {
            idx = 0
            if !playedThisSession {
                let ch = channel
                channel = nil
                onEvent(.failed, "This channel isn't working right now (every stream failed). "
                        + "It has been marked offline; try again later.", ch, nil)
                return
            }
        }
        if playedThisSession, let since = troubleSince, t - since > Self.keepTryingSeconds {
            let ch = channel
            channel = nil
            onEvent(.lost, "The connection has been down for 3 minutes, so playback stopped. "
                    + "Check your internet, then try again.", ch, nil)
            return
        }
        if streams.count > 1 {
            retryAt = t + 1
            onEvent(.switching, "Switching to backup stream \(idx + 1) of \(streams.count)…", channel, streams[idx])
        } else {
            retryAt = t + 10
            onEvent(.reconnecting, "Still trying to reconnect…", channel, stream)
        }
    }
}
