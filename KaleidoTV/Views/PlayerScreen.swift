import SwiftUI

/// The video, what's on, and more channels like this one underneath.
struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    let open: (Channel) -> Void
    let close: () -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    var body: some View {
        ScrollView {
            if let channel = model.current {
                playing(channel)
            } else {
                stopped
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(model.current?.name ?? model.lastChannel?.name ?? "")
        .inlineTitle()
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
    }

    private func playing(_ channel: Channel) -> some View {
        let group = Theme.primaryGroup(channel)
        let favourite = model.isFavourite(channel)
        let more = (model.rails[group] ?? []).filter { $0.key != channel.key }
        return VStack(alignment: .leading, spacing: 22) {
            VideoView(playback: model.playback, gravity: model.picture(for: channel).gravity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 16, style: .continuous))
                .shadow(color: Theme.colors(for: group)[0].opacity(0.35), radius: 40, y: 10)
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, compact ? 0 : Theme.gutter)
                .padding(.top, compact ? 0 : 16)

            HStack(alignment: .center, spacing: 16) {
                ChannelArt(channel: channel)
                    .frame(width: compact ? 88 : 128, height: compact ? 50 : 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(channel.name)
                        .font(.system(size: compact ? 22 : 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        StatusPill(status: channel.status)
                        Text([model.countryLabel(channel.country), channel.source].filter { !$0.isEmpty }
                            .joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Text(model.playStatus)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.gutter)

            controls(channel, favourite: favourite)
                .padding(.horizontal, Theme.gutter)

            NowNext(channel: channel)
                .padding(.horizontal, Theme.gutter)

            if !more.isEmpty {
                Rail(title: "More in \(Theme.label(group))", group: group, channels: more,
                     cardWidth: Theme.cardWidth(compact: compact), open: open)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 40)
    }

    private func controls(_ channel: Channel, favourite: Bool) -> some View {
        HStack(spacing: 10) {
            Button { model.toggleFavourite(channel) } label: {
                Label(favourite ? "In My List" : "My List", systemImage: favourite ? "checkmark" : "plus")
                    .capsule(favourite ? AnyShapeStyle(Theme.gradient(for: "Favourites")) : AnyShapeStyle(.white.opacity(0.14)))
            }
            Menu {
                Picker("Picture", selection: Binding(
                    get: { model.picture(for: channel) },
                    set: { model.setPicture($0, for: channel) }
                )) {
                    ForEach(PictureMode.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Picture", systemImage: "rectangle.arrowtriangle.2.outward")
                    .capsule(AnyShapeStyle(.white.opacity(0.14)))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Button { model.stop(); close() } label: {
                Label("Stop", systemImage: "stop.fill").capsule(AnyShapeStyle(.white.opacity(0.14)))
            }
        }
        .buttonStyle(PressableStyle())
    }

    /// After a channel fails (or the connection was lost for good).
    private var stopped: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.slash")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.4))
            if !model.playStatus.isEmpty {
                Text(model.playStatus)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                if let last = model.lastChannel {
                    Button { model.play(last) } label: {
                        Label("Try \(last.name) again", systemImage: "arrow.clockwise")
                            .capsule(AnyShapeStyle(.white.opacity(0.14)))
                    }
                }
                Button(action: close) {
                    Label("Back to channels", systemImage: "square.grid.2x2")
                        .capsule(AnyShapeStyle(Theme.gradient(for: "Home")))
                }
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.horizontal, Theme.gutter)
    }
}

private extension View {
    func capsule(_ fill: AnyShapeStyle) -> some View {
        font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(fill, in: Capsule())
    }
}

/// Now / Next from the programme guide, refreshed every half minute.
struct NowNext: View {
    @Environment(AppModel.self) private var model
    let channel: Channel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let (now, next) = model.guide.nowNext(channel.epgID)
            VStack(alignment: .leading, spacing: 10) {
                if now == nil && next == nil {
                    Label("No programme guide for this channel.", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    row("NOW", now, highlight: true)
                    row("NEXT", next, highlight: false)
                }
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: 700, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func row(_ label: String, _ programme: Programme?, highlight: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.heavy))
                .tracking(1.5)
                .foregroundStyle(highlight ? Theme.accent : .white.opacity(0.5))
                .frame(width: 44, alignment: .leading)
            Text(programme.map { EPG.format($0) } ?? "–")
                .foregroundStyle(.white.opacity(highlight ? 1 : 0.7))
        }
    }
}
