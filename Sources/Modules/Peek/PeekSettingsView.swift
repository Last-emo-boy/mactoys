import MacToysCore
import PreviewKit
import SwiftUI

struct PeekSettingsView: View {
    let module: PeekModule
    @Bindable var settings: Persisted<PeekSettings>

    init(module: PeekModule) {
        self.module = module
        self.settings = module.settings
    }

    private static let sizeChoices: [(String, Int)] = [("256 KB", 256), ("1 MB", 1024), ("5 MB", 5120), ("10 MB", 10_240),
                                                         ("25 MB", 25_600), ("50 MB", 51_200), ("100 MB", 102_400)]

    var body: some View {
        SettingsPage(module: module) {
            Section("Activation") {
                ShortcutRow("Activation shortcut", subtitle: "Previews the items selected in Finder; press it again to close",
                            shortcut: $settings.value.activation)
                Toggle(isOn: $settings.value.browseFolder) {
                    RowLabel("Step through the folder", subtitle: "With one file selected in Finder, ← and → move through the other items of its folder. With several selected, Peek moves between those.")
                }
            }
            Section("Behavior") {
                Toggle(isOn: $settings.value.alwaysOnTop) { RowLabel("Keep the Peek window on top of other windows") }
                Toggle(isOn: $settings.value.closeOnFocusLoss) { RowLabel("Close Peek when it loses focus") }
                Toggle(isOn: $settings.value.pinned) {
                    RowLabel("Pin the window's position and size", subtitle: "Otherwise the window fits each file. Also with the pin button in the title bar.")
                }
                Toggle(isOn: $settings.value.showDetails) {
                    RowLabel("Show file details", subtitle: "Size, dimensions, date modified and type under the preview")
                }
                Toggle(isOn: $settings.value.confirmDelete) {
                    RowLabel("Ask before moving files to the Trash", subtitle: "⌫ moves the previewed file to the Trash; folders are never deleted")
                }
            }
            Section("Source code and text") {
                Picker(selection: $settings.value.codeTheme) {
                    ForEach(PreviewTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel("Color theme") }
                Toggle(isOn: $settings.value.codeWrap) { RowLabel("Wrap long lines") }
                Toggle(isOn: $settings.value.codeLineNumbers) { RowLabel("Show line numbers") }
                SliderRow("Font size", value: $settings.value.codeFontSize, in: 9...24, step: 1) { "\(Int($0)) pt" }
                Toggle(isOn: $settings.value.codeFormat) {
                    RowLabel("Format JSON and XML for reading", subtitle: "The file itself is never changed")
                }
                Picker(selection: $settings.value.codeMaxFileSizeKB) {
                    ForEach(Self.sizeChoices, id: \.1) { Text($0.0).tag($0.1) }
                    if !Self.sizeChoices.contains(where: { $0.1 == settings.value.codeMaxFileSizeKB }) {
                        Text("\(settings.value.codeMaxFileSizeKB) KB").tag(settings.value.codeMaxFileSizeKB)
                    }
                } label: {
                    RowLabel("Maximum file size to preview", subtitle: "Larger text files show their details instead")
                }
                Toggle(isOn: $settings.value.markdownAllowRemoteImages) {
                    RowLabel("Load remote images in Markdown", subtitle: "Their servers can tell when you preview a document")
                }
            }
            Section("Keyboard") {
                KeyRow("Previous / next file", keys: ["←", "→"])
                KeyRow("Previous / next from inside a text or PDF preview", keys: ["⌥", "←", "→"])
                KeyRow("Open with the default app", keys: ["⌘", "↩"])
                KeyRow("Copy the file", keys: ["⌘", "C"])
                KeyRow("Move the file to the Trash", keys: ["⌫"])
                KeyRow("Close Peek", keys: ["Space"], alternative: ["esc"])
            }
            Section {
                Text("Peek renders Markdown, source code, JSON, XML, CSV, SQLite databases, SVG, G-code, STL, QOI and folders itself; images, video, audio, PDF and documents use macOS's own previewer. Other text files are shown as plain text.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct KeyRow: View {
    let title: String
    let keys: [String]
    let alternative: [String]?

    init(_ title: String, keys: [String], alternative: [String]? = nil) {
        self.title = title
        self.keys = keys
        self.alternative = alternative
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Keycaps(keys)
                if let alternative {
                    Text("or").foregroundStyle(.secondary).font(.system(size: 11.5))
                    Keycaps(alternative)
                }
            }
        } label: {
            RowLabel(title)
        }
    }
}
