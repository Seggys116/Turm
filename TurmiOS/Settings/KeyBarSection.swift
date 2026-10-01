import SwiftUI
import TurmCore

struct KeyBarSection: View {
    @Bindable private var layout = KeyBarLayout.shared

    var body: some View {
        ChromeSection("Keyboard Bar", footer: "The row of terminal keys above the keyboard. Function keys sit on a second page behind fn.") {
            NavigationLink {
                KeyBarEditor()
            } label: {
                ChromeRow("Customize Keys", detail: "\(layout.keys.count) keys in the bar") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            ChromeRow("Haptic Feedback", detail: "Tap feedback on the keys.") {
                Toggle("Haptic Feedback", isOn: $layout.haptics)
                    .labelsHidden()
                    .tint(Chrome.accent)
            }
        }
    }
}

struct KeyBarEditor: View {
    @Bindable private var layout = KeyBarLayout.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                TerminalKeyBar()
                    .frame(height: TerminalKeyBarView.height)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Chrome.statusBar)
            } header: {
                header("Preview")
            }
            Section {
                ForEach(layout.keys) { key in
                    KeyRow(key: key).keyListRow()
                }
                .onMove(perform: layout.move)
                .onDelete(perform: layout.remove(at:))
            } header: {
                header("In the Bar")
            } footer: {
                Text("Drag to reorder, or delete a key to move it to Available.")
                    .font(Chrome.Typeface.caption)
                    .foregroundStyle(Chrome.secondaryText)
            }
            if !layout.available.isEmpty {
                Section {
                    ForEach(layout.available) { key in
                        Button {
                            Haptics.tap()
                            withAnimation(.snappy) { layout.add(key) }
                        } label: {
                            HStack {
                                KeyRow(key: key)
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Chrome.accent)
                            }
                        }
                        .buttonStyle(.plain)
                        .keyListRow()
                    }
                } header: {
                    header("Available")
                }
            }
            Section {
                Button("Reset to Default", role: .destructive) {
                    Haptics.warn()
                    withAnimation(.snappy) { layout.reset() }
                }
                .font(Chrome.Typeface.body)
                .foregroundStyle(Chrome.failure)
                .disabled(layout.isDefault)
                .keyListRow()
            }
        }
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Chrome.sidebar.ignoresSafeArea())
        .chromeBar(ChromeTopBar("Keyboard Bar", leading: { ChromeBackButton { dismiss() } }))
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Chrome.Typeface.section)
            .tracking(0.6)
            .foregroundStyle(Chrome.secondaryText)
    }
}

private extension View {
    func keyListRow() -> some View {
        self
            .listRowBackground(Chrome.chipFill)
            .listRowSeparatorTint(Chrome.subtleDivider)
    }
}

private struct KeyRow: View {
    let key: TerminalKey

    var body: some View {
        HStack(spacing: 12) {
            glyph
                .frame(width: 44, height: 30)
                .background(Chrome.chipFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Chrome.chipStroke, lineWidth: 1))
            Text(key.name)
                .font(Chrome.Typeface.body)
                .foregroundStyle(Chrome.text)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyph: some View {
        if let symbol = key.symbol {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Chrome.text)
        } else {
            Text(key.label)
                .font(.system(size: key.label.count == 1 ? 15 : 12, weight: .medium, design: key.label.count == 1 ? .monospaced : .rounded))
                .foregroundStyle(Chrome.text)
        }
    }
}
