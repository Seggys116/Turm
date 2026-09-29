import SwiftUI

struct StatusBar: View {
    var body: some View {
        Color.clear
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(Theme.statusBar.color)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.divider.color).frame(height: 1)
            }
    }
}

struct TopBar: View {
    static let height: CGFloat = 28

    var body: some View {
        Color.clear
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .background(Theme.topBar.color)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.divider.color).frame(height: 1)
            }
    }
}
