import SwiftUI

enum Theme {
    static let background = LinearGradient(
        colors: [Color(red: 0.035, green: 0.043, blue: 0.055), Color(red: 0.066, green: 0.082, blue: 0.101)],
        startPoint: .top, endPoint: .bottom
    )
    static let card = Color(red: 0.086, green: 0.102, blue: 0.122)
    static let cardBorder = Color.white.opacity(0.06)
    static let accent = Color(red: 0.20, green: 0.84, blue: 0.78)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)
    static let danger = Color(red: 0.96, green: 0.42, blue: 0.42)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
            } icon: {
                Image(systemName: symbol)
            }
            .foregroundStyle(Theme.secondaryText)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct IconTile: View {
    let symbol: String
    var active = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Theme.tertiaryText)
            .frame(width: 34, height: 34)
            .background(
                (active ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04)),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }
}
