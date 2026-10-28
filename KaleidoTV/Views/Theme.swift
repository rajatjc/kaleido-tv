import SwiftUI

/// Colours and sizes for the dark, colourful browsing look. Each group has its own gradient, and every
/// channel card wears its group's gradient, nudged a little in hue so neighbouring cards differ.
enum Theme {
    static let background = hex(0x0A0A12)
    static let raised = Color.white.opacity(0.07)
    static let accent = hex(0xE5263F)
    static let live = hex(0xE5263F)

    #if os(macOS)
    static let gutter: CGFloat = 32
    #else
    static let gutter: CGFloat = 18
    #endif

    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func colors(for group: String) -> [Color] {
        switch group {
        case "Home": [hex(0xE5263F), hex(0xFF7A45)]
        case "Favourites": [hex(0xF7B733), hex(0xFC4A1A)]
        case "Recent": [hex(0x00B4DB), hex(0x0083B0)]
        case "Football": [hex(0x11998E), hex(0x38EF7D)]
        case "Tennis": [hex(0x56AB2F), hex(0xA8E063)]
        case "Cricket": [hex(0x2193B0), hex(0x6DD5ED)]
        case "News": [hex(0x1A2980), hex(0x26D0CE)]
        case "Sports": [hex(0xF12711), hex(0xF5AF19)]
        case "Entertainment": [hex(0x8E2DE2), hex(0x4A00E0)]
        case "Movies": [hex(0xB91D3A), hex(0xEF473A)]
        case "Kids": [hex(0xFF5F6D), hex(0xFFC371)]
        default: [hex(0x606C88), hex(0x3F4C6B)]
        }
    }

    static func gradient(for group: String) -> LinearGradient {
        LinearGradient(colors: colors(for: group), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The group whose colours a channel wears: its most specific one.
    private static let colourOrder = ["Kids", "Movies", "Football", "Tennis", "Cricket", "Entertainment", "Sports", "News"]

    static func primaryGroup(_ c: Channel) -> String {
        colourOrder.first(where: c.groups.contains) ?? "Other"
    }

    /// A stable hue nudge (−24…24°) per channel, so a row of same-group cards isn't one flat colour.
    static func hueShift(_ key: String) -> Double {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Double(h % 49) - 24
    }

    static func label(_ group: String) -> String {
        switch group {
        case "Favourites": "My List"
        case "Recent": "Recently watched"
        default: group
        }
    }

    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String((words.first ?? Substring(name)).prefix(2)).uppercased()
    }

    /// Card width for horizontal rows.
    static func cardWidth(compact: Bool) -> CGFloat {
        #if os(macOS)
        250
        #else
        compact ? 168 : 230
        #endif
    }
}

/// Cards shrink slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// "LIVE" / "OFFLINE" badge.
struct StatusPill: View {
    let status: StreamStatus

    var body: some View {
        switch status {
        case .ok:
            HStack(spacing: 4) {
                Circle().fill(.white).frame(width: 5, height: 5)
                Text("LIVE")
            }
            .pill(Theme.live)
        case .dead:
            Text("OFFLINE").pill(.black.opacity(0.55))
        case .unknown:
            EmptyView()
        }
    }
}

private extension View {
    func pill(_ fill: some ShapeStyle) -> some View {
        font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
    }
}
