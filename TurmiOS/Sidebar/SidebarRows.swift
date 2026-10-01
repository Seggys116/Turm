import SwiftUI
import TurmCore

extension View {
    func rowSurface(selected: Bool = false) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Chrome.Radius.chip)
                        .fill(Chrome.accent.opacity(0.14))
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
    }
}

struct MacRow: View {
    let mac: MacEntry

    private var dot: some View {
        switch mac.status {
        case .connected: StatusDot(color: Chrome.success)
        case .unreachable: StatusDot(color: Chrome.failure)
        case .discovered, .paired: StatusDot(color: Chrome.secondaryText, filled: false)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            dot
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                    .font(Chrome.Typeface.body)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                Text(mac.detail)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

struct HostRow: View {
    let host: SSHHost

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.token)
                    .font(Chrome.Typeface.monoBody)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                Text(host.summary)
                    .font(Chrome.Typeface.mono)
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SessionRow: View {
    let tab: any TerminalTab

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: tab.indicator.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(Chrome.Typeface.monoBody)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                Text(tab.subtitle)
                    .font(Chrome.Typeface.mono)
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SidebarAction: View {
    let title: String
    let systemImage: String
    var indent: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14)
                Text(title).font(Chrome.Typeface.label)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Chrome.secondaryText)
            .padding(.leading, 14 + indent)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}
