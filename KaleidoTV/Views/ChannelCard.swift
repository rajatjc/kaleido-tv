import SwiftUI

/// One channel: its picture (logo on the group's colours), a LIVE badge, and the name with what's on.
/// Lifts towards you when the pointer is over it.
struct ChannelCard: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    var width: CGFloat?
    let open: (Channel) -> Void
    @State private var hovering = false

    private var subtitle: String {
        if let now = model.guide.nowNext(channel.epgID).now { return now.title }
        let place = model.countryLabel(channel.country)
        return place.isEmpty ? channel.source : place
    }

    var body: some View {
        let favourite = model.isFavourite(channel)
        Button { open(channel) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ChannelArt(channel: channel)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        StatusPill(status: channel.status).padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        if favourite {
                            Image(systemName: "star.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.yellow)
                                .padding(6)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(hovering ? 0.7 : 0.08), lineWidth: hovering ? 2 : 1)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.55 : 0.3), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
                    .scaleEffect(hovering ? 1.05 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .padding(.horizontal, 2)
            }
            .frame(width: width)
            .opacity(channel.status == .dead ? 0.45 : 1)
            .saturation(channel.status == .dead ? 0.15 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { over in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovering = over }
        }
        .contextMenu {
            Button("Watch", systemImage: "play.fill") { open(channel) }
            Button(favourite ? "Remove from My List" : "Add to My List", systemImage: favourite ? "minus" : "plus") {
                model.toggleFavourite(channel)
            }
        }
        .accessibilityLabel("\(channel.name), \(subtitle)")
    }
}

/// A titled, horizontally scrolling row of cards. On the Mac, arrows appear at the ends on hover.
struct Rail: View {
    let title: String
    let group: String
    let channels: [Channel]
    let cardWidth: CGFloat
    let open: (Channel) -> Void
    var seeAll: (() -> Void)?
    @State private var position: String?
    @State private var hovering = false

    private static let limit = 40

    var body: some View {
        let shown = Array(channels.prefix(Self.limit))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Capsule()
                    .fill(Theme.gradient(for: group))
                    .frame(width: 4, height: 18)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(title).font(.title3.weight(.bold)).foregroundStyle(.white)
                Text("\(channels.count)").font(.subheadline).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if let seeAll, channels.count > 6 {
                    Button(action: seeAll) {
                        HStack(spacing: 4) {
                            Text("See all")
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.gutter)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shown) { channel in
                        ChannelCard(channel: channel, width: cardWidth, open: open)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .leading)
            #if os(macOS)
            .overlay(alignment: .leading) { arrow(-1, shown) }
            .overlay(alignment: .trailing) { arrow(1, shown) }
            .onHover { over in withAnimation(.easeOut(duration: 0.2)) { hovering = over } }
            #endif
        }
    }

    #if os(macOS)
    private func arrow(_ direction: Int, _ shown: [Channel]) -> some View {
        let index = shown.firstIndex { $0.key == position } ?? 0
        let canMove = direction < 0 ? index > 0 : index + 4 < shown.count
        return Button {
            let target = min(max(index + direction * 4, 0), max(shown.count - 1, 0))
            withAnimation(.smooth(duration: 0.45)) { position = shown[target].key }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: cardWidth * 9 / 16)
                .background(.black.opacity(0.55))
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(hovering && canMove ? 1 : 0)
        .allowsHitTesting(hovering && canMove)
    }
    #endif
}

/// The big rotating banner at the top of Home.
struct HeroCarousel: View {
    @Environment(AppModel.self) private var model
    let channels: [Channel]
    let compact: Bool
    let open: (Channel) -> Void
    @State private var index = 0
    @State private var paused = false
    private let timer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    var body: some View {
        let channel = channels[index % channels.count]
        let group = Theme.primaryGroup(channel)
        let favourite = model.isFavourite(channel)
        let onNow = model.guide.nowNext(channel.epgID).now
        ZStack(alignment: .bottomLeading) {
            ChannelArt(channel: channel, hero: true)
                .id(channel.key)
                .transition(.opacity)
            LinearGradient(colors: [Theme.background.opacity(0.92), Theme.background.opacity(0.35), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .clear, Theme.background], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 12) {
                Text(Theme.label(group).uppercased())
                    .font(.caption.weight(.heavy))
                    .tracking(2.5)
                    .foregroundStyle(Theme.gradient(for: group))
                    .brightness(0.25)
                Text(channel.name)
                    .font(.system(size: compact ? 30 : 48, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    StatusPill(status: channel.status)
                    Text(onNow.map { "On now: \($0.title)" } ?? model.countryLabel(channel.country))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    Button { open(channel) } label: {
                        Label("Watch", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 11)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Button { model.toggleFavourite(channel) } label: {
                        Label(favourite ? "In My List" : "My List", systemImage: favourite ? "checkmark" : "plus")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .background(.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(PressableStyle())
                .padding(.top, 4)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 34)
            .frame(maxWidth: 620, alignment: .leading)
            .id("text-" + channel.key)
            .transition(.opacity.combined(with: .offset(y: 12)))

            HStack(spacing: 6) {
                ForEach(channels.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(i == index % channels.count ? 1 : 0.35))
                        .frame(width: i == index % channels.count ? 20 : 6, height: 6)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.6)) { index = i } }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: compact ? 300 : 440)
        .clipped()
        .onReceive(timer) { _ in
            guard !paused, channels.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.9)) { index = (index + 1) % channels.count }
        }
        .onHover { paused = $0 }
    }
}

/// The category tabs. The highlight slides to the one you pick.
struct CategoryBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var highlight

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.categories, id: \.self) { group in
                    let selected = model.query.isEmpty && model.group == group
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.group = group }
                    } label: {
                        Label(Theme.label(group), systemImage: group == "Home" ? "house.fill" : ChannelGroup.symbol(group))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Theme.gradient(for: group))
                                        .matchedGeometryEffect(id: "highlight", in: highlight)
                                        .shadow(color: Theme.colors(for: group)[0].opacity(0.5), radius: 10, y: 4)
                                } else {
                                    Capsule().fill(.white.opacity(0.08))
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
        }
        .background(Theme.background.opacity(0.92))
        .background(.ultraThinMaterial)
    }
}
