import SwiftUI

struct AcknowledgementsRow: View {
    var body: some View {
        NavigationLink {
            AcknowledgementsView()
        } label: {
            ChromeRow("Acknowledgements", detail: "Licences of the open-source software and logos Turm includes.") {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Chrome.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Chrome.sidebar.ignoresSafeArea())
        .chromeBar(ChromeTopBar("Acknowledgements", leading: { ChromeBackButton { dismiss() } }))
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
