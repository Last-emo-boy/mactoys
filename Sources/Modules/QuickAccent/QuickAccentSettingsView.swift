import AppKit
import MacToysCore
import SwiftUI

struct QuickAccentSettingsView: View {
    let module: QuickAccentModule
    @Bindable var settings: Persisted<QuickAccentSettings>
    @State private var showReference = false

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .pink) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        heroTitle.font(.system(size: 14, weight: .semibold))
                        Text("Tap again to move through the characters (⇧Space or ← goes back), release the letter to type the selection. Esc cancels.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Character reference…") { showReference = true }
                }
            }
        } content: {
            Section("Activation") {
                Picker(selection: $settings.value.activation) {
                    ForEach(AccentEngine.Activation.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel(title: Text("Activation key"), subtitle: settings.value.activation == .hold
                             ? Text("The toolbar opens after you hold the letter alone; the letter is replaced only if you choose a character.")
                             : Text("Hold the letter, then press the key."))
                }
                if settings.value.activation == .hold {
                    SliderRow("Hold duration", subtitle: "How long to hold the letter before the toolbar opens.",
                              value: $settings.value.holdDuration, in: 100...3000, step: 50) { Self.milliseconds($0) }
                } else {
                    SliderRow("Input delay", subtitle: "How long the letter and the activation key must stay down before the toolbar opens. Quicker presses type normally, so fast typing isn't affected.",
                              value: $settings.value.inputDelay, in: 100...1000, step: 25) { Self.milliseconds($0) }
                }
                Toggle(isOn: $settings.value.startFromLeft) {
                    RowLabel("Start selection from the left", subtitle: "← also starts at the first character instead of the last.")
                }
            }

            Section("Toolbar") {
                Picker(selection: $settings.value.position) {
                    ForEach(QuickAccentSettings.Position.allCases, id: \.self) { p in
                        Text(verbatim: p.title).tag(p)
                        if p == .caret { Divider() }
                    }
                } label: {
                    RowLabel("Toolbar position", subtitle: "Near the text cursor falls back to top center in apps that don't report it.")
                }
                Toggle(isOn: $settings.value.showUnicode) {
                    RowLabel("Show the Unicode code point and name of the selected character")
                }
                Toggle(isOn: $settings.value.sortByUsage) {
                    RowLabel("Sort characters by usage frequency", subtitle: "Characters you type most move to the front.")
                }
                if settings.value.sortByUsage {
                    LabeledContent {
                        Button("Reset") { module.usage.reset() }.disabled(module.usage.counts.isEmpty)
                    } label: {
                        RowLabel("Usage statistics", subtitle: "\(module.usage.counts.values.reduce(0, +)) characters typed with Quick Accent.")
                    }
                }
            }

            Section("Characters") {
                Toggle(isOn: $settings.value.allSets) {
                    RowLabel("All character sets", subtitle: "Turn off to offer only the sets you choose below.")
                }
                if !settings.value.allSets {
                    if settings.value.sets.isEmpty {
                        InfoBar(.warning, title: "No character sets selected", message: "Quick Accent has nothing to offer until you choose at least one set.")
                    }
                    setGrid(.language, title: "Languages")
                    setGrid(.special, title: "Special sets")
                }
                LabeledContent {
                    Button("Open…") { showReference = true }
                } label: {
                    RowLabel("Character reference", subtitle: "Browse every set, search by character or name, click to copy.")
                }
            }

            Section("Excluded apps") {
                ExcludedAppsEditor("Don't activate in these apps", apps: $settings.value.excludedApps)
            }
        }
        .sheet(isPresented: $showReference) {
            CharacterReferenceView(selected: settings.value.allSets ? Set(AccentSet.all.map(\.id)) : Set(settings.value.sets))
        }
        .onAppear {
            if module.showReferenceOnAppear {
                module.showReferenceOnAppear = false
                showReference = true
            }
        }
    }

    private var heroTitle: Text {
        switch settings.value.activation {
        case .both: Text("Hold a letter, tap Space or ←/→")
        case .space: Text("Hold a letter, tap Space")
        case .arrows: Text("Hold a letter, tap ← or →")
        case .hold: Text("Hold a letter, tap and keep holding")
        }
    }

    static func milliseconds(_ value: Double) -> String {
        Duration.milliseconds(Int(value)).formatted(.units(allowed: [.milliseconds], width: .abbreviated))
    }

    private func setGrid(_ group: AccentSet.Group, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(AccentSet.all.filter { $0.group == group }) { accentSet in
                    Toggle(accentSet.name, isOn: Binding(
                        get: { settings.value.sets.contains(accentSet.id) },
                        set: { on in
                            if on { settings.value.sets.append(accentSet.id) } else { settings.value.sets.removeAll { $0 == accentSet.id } }
                        }))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Every set's characters per key; selected sets first. Hover for the Unicode name, click to copy.
struct CharacterReferenceView: View {
    let selected: Set<String>
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Character reference").font(.system(size: 15, weight: .semibold))
                Spacer()
                TextField("Search for a character…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let sets = filteredSets
                    if sets.isEmpty {
                        Text("No set contains “\(query)”.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    let mine = sets.filter { selected.contains($0.accentSet.id) }
                    let others = sets.filter { !selected.contains($0.accentSet.id) }
                    if !mine.isEmpty { group("Selected sets", mine) }
                    if !others.isEmpty { group("Other sets", others) }
                }
                .padding(16)
            }
        }
        .frame(width: 680, height: 600)
    }

    private struct Match: Identifiable {
        let accentSet: AccentSet
        let rows: [(key: AccentKey, chars: [String])]
        var id: String { accentSet.id }
    }

    private var filteredSets: [Match] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return AccentSet.all.compactMap { accentSet in
            let rows = AccentKey.allCases.compactMap { key -> (key: AccentKey, chars: [String])? in
                guard var chars = accentSet.characters[key] else { return nil }
                if !q.isEmpty { chars = chars.filter { Self.matches($0, q) } }
                return chars.isEmpty ? nil : (key, chars)
            }
            return rows.isEmpty ? nil : Match(accentSet: accentSet, rows: rows)
        }
    }

    /// The character itself (either case), or words of its Unicode name.
    static func matches(_ c: String, _ q: String) -> Bool {
        if c == q || c.lowercased() == q.lowercased() || AccentLogic.uppercased([c]).first == q { return true }
        guard q.count > 1 else { return false }
        return AccentLogic.unicodeInfo(c).name.localizedCaseInsensitiveContains(q)
    }

    private func group(_ title: LocalizedStringKey, _ matches: [Match]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).textCase(.uppercase).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(matches) { match in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: match.accentSet.name).font(.system(size: 13, weight: .semibold))
                    ForEach(match.rows, id: \.key) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: row.key.label)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                                .padding(.top, 6)
                            FlowRow(row.chars)
                        }
                    }
                }
            }
        }
    }
}

/// Wrapping row of copyable character chips.
private struct FlowRow: View {
    let chars: [String]
    init(_ chars: [String]) { self.chars = chars }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(chars, id: \.self) { c in
                let info = AccentLogic.unicodeInfo(c)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(c, forType: .string)
                    HUD.show(String(localized: "Copied \(c)", comment: "Character reference: %@ is the character that was copied"),
                             symbol: "doc.on.doc")
                } label: {
                    Text(verbatim: AccentLogic.display(c))
                        .font(.system(size: 17))
                        .frame(minWidth: 34, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(info.code) · \(info.name)"))
            }
        }
    }
}
