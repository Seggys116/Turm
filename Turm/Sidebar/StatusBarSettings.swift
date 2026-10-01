import SwiftUI
import TurmCore

struct StatusBarSettings: View {
    @AppStorage(StatusBarPreferences.key) private var prefs = StatusBarPreferences()
    @State private var selectedID = EcosystemCatalog.entries.first?.id ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            bar
            SettingsSection("Ecosystems") {
                ecosystemPicker
                    .padding(16)
            }
            if let entry = EcosystemCatalog.entry(selectedID) {
                ecosystemSection(entry)
            }
            Text("A Turm.json in a project overrides these settings for that project.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
                .padding(.leading, 4)
        }
    }

    private var bar: some View {
        SettingsSection("Project Bar") {
            SettingsFormRow("Show project bar", detail: "Show build, run and test actions in a bar beside a shell when it sits in a project.") {
                toggle("Show project bar", isOn: $prefs.enabled)
            }
            SettingsFormRow("Alignment", detail: "Where the bar's contents sit along its edge.") {
                SlidingPicker(selection: $prefs.alignment, options: BarAlignment.allCases, title: \.title)
                    .frame(width: 240)
            }
            SettingsFormRow("Labels", detail: "Auto hides labels when the bar is narrow.") {
                SlidingPicker(selection: $prefs.titles, options: TitleMode.allCases, title: \.title)
                    .frame(width: 240)
            }
            SettingsFormRow("Run actions in a sub-shell", detail: "Actions run in a hidden shell. The bar fills green while running and pulses red on failure, and a Watch button opens the output as an overlay.") {
                toggle("Run actions in a sub-shell", isOn: $prefs.runInSubShell)
            }
        }
    }

    private var ecosystemPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(EcosystemCatalog.entries) { entry in
                let isSelected = entry.id == selectedID
                Button {
                    withAnimation(SettingsMotion.slide) { selectedID = entry.id }
                } label: {
                    HStack(spacing: 6) {
                        Glyph(symbol: entry.symbol, fallback: ProjectEcosystem.fallback(forSymbol: entry.symbol), size: 11, weight: .medium)
                        Text(entry.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Theme.text.color : Theme.secondaryText.color)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? SettingsMotion.thumbFill.color : Color.clear)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Theme.chipStroke.color, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func ecosystemSection(_ entry: EcosystemCatalog.Entry) -> some View {
        SettingsSection(entry.title) {
            SettingsFormRow("Enabled", detail: "Show \(entry.title) projects on the bar.") {
                toggle("Enabled", isOn: enabledBinding(entry.id))
            }
            editor(entry)
            SettingsFormRow("Reset to defaults", detail: nil) {
                Button("Reset to defaults") { prefs.ecosystems[entry.id] = nil }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(prefs.ecosystems[entry.id] == nil)
            }
        }
    }

    private func editor(_ entry: EcosystemCatalog.Entry) -> some View {
        let catalogue = entry.actions.map(BarLayoutItem.init) + entry.variants.map(BarLayoutItem.init)
        let ids = Binding(
            get: { prefs.items(for: entry.id, defaults: entry.defaultItems) },
            set: { prefs.setItems($0, for: entry.id) }
        )
        return VStack(alignment: .leading, spacing: 14) {
            BarLayoutEditor(catalogue: catalogue, ids: ids)
            Text("Drag to reorder. Drag off the bar or click the X to remove. Anything that does not fit collapses into the ... menu.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .labelsHidden()
            .toggleStyle(SquareToggleStyle())
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { prefs.preference(for: id).enabled },
            set: { value in
                var entry = prefs.preference(for: id)
                entry.enabled = value
                prefs.ecosystems[id] = entry
            }
        )
    }
}
