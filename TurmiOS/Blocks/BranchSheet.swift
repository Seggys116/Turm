import SwiftUI
import UIKit

struct BranchSheet<Session: BlockSession>: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String]?
    @State private var current: String?
    @State private var failure: String?
    @State private var switching: String?

    var body: some View {
        ChromeScroll {
            if let failure {
                Text(failure)
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.failure)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let names {
                if names.isEmpty {
                    Text("This folder has no branches.")
                        .font(Chrome.Typeface.caption)
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 6)
                } else {
                    ChromeSection("Branches") {
                        ForEach(names, id: \.self) { name in row(name) }
                    }
                }
            } else if failure == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            }
            if let name = current ?? session.branch {
                ChromeSection("Current") {
                    ChromeActionRow("Copy Branch Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = name }
                }
            }
        }
        .chromeBar(ChromeTopBar("Branches", leading: { ChromeBarButton(title: "Done", systemImage: "checkmark") { dismiss() } }))
        .task { await load() }
        .chromeSheet()
    }

    private func row(_ name: String) -> some View {
        let isCurrent = name == (current ?? session.branch)
        return Button {
            switchTo(name)
        } label: {
            HStack(spacing: 10) {
                Text(name)
                    .font(Chrome.Typeface.monoBody)
                    .foregroundStyle(Chrome.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if switching == name {
                    ProgressView().controlSize(.small)
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .disabled(isCurrent || switching != nil)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func load() async {
        do {
            let result = try await session.branches()
            names = result.names
            current = result.current
        } catch {
            failure = (error as? MacRequestError)?.text ?? error.localizedDescription
        }
    }

    private func switchTo(_ name: String) {
        guard switching == nil else { return }
        switching = name
        failure = nil
        Task {
            do {
                if let problem = try await session.switchBranch(to: name) {
                    failure = problem
                } else {
                    Haptics.confirm()
                    dismiss()
                }
            } catch {
                failure = (error as? MacRequestError)?.text ?? error.localizedDescription
            }
            switching = nil
        }
    }
}
