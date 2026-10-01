import SwiftUI

struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Third-party notices")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text.color)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SettingsButtonStyle(prominent: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .squareScrollbar()
        }
        .frame(width: 720, height: 560)
        .background(Theme.terminalBackground.color)
        .task { text = Self.bundledNotices() }
    }

    private static func bundledNotices() -> String {
        let files: [(String, String?)] = [("ThirdPartyNotices", nil), ("NOTICES", "BrandIcons")]
        let parts = files.compactMap { name, folder in
            Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: folder)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        return parts.isEmpty ? "The licence notices are missing from this build." : parts.joined(separator: "\n\n")
    }
}
