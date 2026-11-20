import SwiftUI

/// Shows the text size for a moment after each zoom command in the front window, with the actual size to go back to.
struct ZoomIndicator: View {
    private let zoom = TerminalZoom.shared
    @Environment(\.controlActiveState) private var activeState
    @State private var isVisible = false
    @State private var hiding: Task<Void, Never>?

    var body: some View {
        Group {
            if isVisible {
                VStack(spacing: 3) {
                    Text("\(zoom.percent)%")
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: zoom.announcement) { show() }
        .onDisappear { hiding?.cancel() }
    }

    private var detail: String {
        let size = Int(zoom.size)
        let actual = Int(TerminalZoom.defaultSize)
        return zoom.isDefault ? "Actual size, \(size) pt" : "\(size) pt, actual size \(actual) pt (Command-0)"
    }

    private func show() {
        guard activeState == .key else { return }
        withAnimation(.easeOut(duration: 0.12)) { isVisible = true }
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { isVisible = false }
        }
    }
}
