import SwiftUI

/// Home (banner and a row per category), one category as a grid, or search results.
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    let open: (Channel) -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private var cardWidth: CGFloat { Theme.cardWidth(compact: compact) }
    private var showingHome: Bool { model.query.isEmpty && model.group == "Home" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if model.channels.isEmpty {
                        emptyLibrary
                    } else if showingHome {
                        home
                    } else {
                        grid
                    }
                } header: {
                    CategoryBar()
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: model.group)
    }

    // MARK: Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.featured.isEmpty {
                HeroCarousel(channels: model.featured, compact: compact, open: open)
            }
            if model.checking { CheckBanner().padding(.horizontal, Theme.gutter) }
            if !model.recentChannels.isEmpty {
                Rail(title: Theme.label("Recent"), group: "Recent", channels: model.recentChannels,
                     cardWidth: cardWidth, open: open)
            }
            ForEach(ChannelGroup.all.filter { $0 != "All channels" }, id: \.self) { group in
                if let list = model.rails[group], !list.isEmpty {
                    Rail(title: Theme.label(group), group: group, channels: list, cardWidth: cardWidth, open: open,
                         seeAll: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.group = group } })
                }
            }
        }
    }

    // MARK: One category, or search results

    private var grid: some View {
        let title = model.query.isEmpty ? Theme.label(model.group) : "Results for “\(model.query)”"
        let accent = model.query.isEmpty ? model.group : "Home"
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: compact ? 28 : 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.gradient(for: accent))
                    .brightness(0.15)
                Text("\(model.visible.count) channels").foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 18)
            if model.checking { CheckBanner() }
            if model.visible.isEmpty {
                emptyCategory.frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 210, maximum: 300), spacing: 18)],
                          alignment: .leading, spacing: 24) {
                    ForEach(model.visible) { channel in
                        ChannelCard(channel: channel, open: open)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
    }

    @ViewBuilder
    private var emptyCategory: some View {
        if !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else if model.group == "Favourites" {
            ContentUnavailableView("Nothing in My List yet", systemImage: "star",
                                   description: Text("Right-click a channel, or use **My List** on the banner or "
                                                     + "under the video, to keep it here."))
        } else {
            ContentUnavailableView("No channels here", systemImage: "tv",
                                   description: Text("Try another category or country."))
        }
    }

    @ViewBuilder
    private var emptyLibrary: some View {
        if let error = model.freeListError {
            ContentUnavailableView {
                Label("Couldn't load the free channel list", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your internet connection, then try again.\n\n(\(error))")
            } actions: {
                Button("Try again") { model.reloadAll(force: true) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 80)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 18) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Loading channels…").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(model.statusLine).font(.callout).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 140)
        }
    }
}

/// "Checking which channels work…" with a progress bar, while the background check runs.
struct CheckBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Theme.gradient(for: "Home"))
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 6) {
                Text("Checking which channels work: \(model.checkDone) of \(model.checkTotal)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                ProgressView(value: Double(model.checkDone), total: Double(max(model.checkTotal, 1)))
                    .tint(Theme.accent)
                Text("Working channels move to the front as they pass. You can start watching now.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 640, alignment: .leading)
    }
}
