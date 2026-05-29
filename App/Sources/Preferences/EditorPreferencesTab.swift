import SwiftUI
import FileEncoding
import LineEnding

/// iOS has no stock `.checkbox` Toggle style.
private struct CheckboxRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct EditorPreferencesTab: View {

    @AppStorage(AppPreferenceKey.fontSize) private var fontSize: Double = 14
    @AppStorage(AppPreferenceKey.showLineNumbers) private var showLineNumbers: Bool = true
    @AppStorage(AppPreferenceKey.wrapLines) private var wrapLines: Bool = true
    @AppStorage(AppPreferenceKey.overscroll) private var overscroll: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibles) private var showInvisibles: Bool = false
    @AppStorage(AppPreferenceKey.showInvisibleSpace) private var showInvisibleSpace: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleTab) private var showInvisibleTab: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleNewline) private var showInvisibleNewline: Bool = true
    @AppStorage(AppPreferenceKey.showInvisibleNonBreakingSpace) private var showInvisibleNBSP: Bool = true
    @AppStorage(AppPreferenceKey.showPageGuide) private var showPageGuide: Bool = false
    @AppStorage(AppPreferenceKey.pageGuideColumn) private var pageGuideColumn: Int = 80
    @AppStorage(AppPreferenceKey.usesTabs) private var usesTabs: Bool = false
    @AppStorage(AppPreferenceKey.indentWidth) private var indentWidth: Int = 4
    @AppStorage(AppPreferenceKey.insertCharacterPairs) private var insertCharacterPairs: Bool = true
    @AppStorage(AppPreferenceKey.themeName) private var themeRaw: String = AppThemeName.automatic.rawValue
    @AppStorage(AppPreferenceKey.fontName) private var fontNameRaw: String = EditorFont.systemMono.rawValue

    @AppStorage(AppPreferenceKey.defaultEncodingRaw) private var defaultEncodingRaw: Int = Int(String.Encoding.utf8.rawValue)
    @AppStorage(AppPreferenceKey.defaultLineEndingRaw) private var defaultLineEndingRaw: String = "\n"
    @AppStorage(AppPreferenceKey.defaultLanguage) private var defaultLanguageRaw: String = LanguageIdentifier.plain.rawValue
    @AppStorage(AppPreferenceKey.ensureTrailingNewline) private var ensureTrailingNewline: Bool = false
    @AppStorage(AppPreferenceKey.trimTrailingWhitespaceOnSave) private var trimTrailingWhitespace: Bool = false
    @AppStorage(AppPreferenceKey.syntaxLimitBytes) private var syntaxLimitRaw: Int = SyntaxLimit.up5MB.rawValue
    @AppStorage(AppPreferenceKey.iCloudSyncEnabled) private var iCloudSyncEnabled: Bool = true

    /// Int↔Double bridge — live editor/menu zoom callers use Int.
    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { Int(fontSize.rounded()) },
            set: { fontSize = Double($0) }
        )
    }

    private var defaultEncodingBinding: Binding<UInt> {
        Binding(
            get: { UInt(defaultEncodingRaw) },
            set: { defaultEncodingRaw = Int($0) }
        )
    }

    private var defaultLineEndingBinding: Binding<LineEnding> {
        Binding(
            get: { LineEnding(rawValue: defaultLineEndingRaw.first ?? "\n") ?? .lf },
            set: { defaultLineEndingRaw = String($0.rawValue) }
        )
    }

    private var defaultLanguageBinding: Binding<LanguageIdentifier> {
        Binding(
            get: { LanguageIdentifier(rawValue: defaultLanguageRaw) ?? .plain },
            set: { defaultLanguageRaw = $0.rawValue }
        )
    }

    private var syntaxLimitBinding: Binding<SyntaxLimit> {
        Binding(
            get: { SyntaxLimit(rawValue: syntaxLimitRaw) ?? .up5MB },
            set: { syntaxLimitRaw = $0.rawValue }
        )
    }

    private var themeBinding: Binding<AppThemeName> {
        Binding(
            get: { AppThemeName(stored: themeRaw) },
            set: { themeRaw = $0.rawValue }
        )
    }

    private var commonEncodings: [String.Encoding] {
        [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32,
            .windowsCP1252, .isoLatin1, .isoLatin2, .macOSRoman,
            .shiftJIS, .japaneseEUC, .iso2022JP
        ]
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: themeBinding) {
                    ForEach(AppThemeName.allCases, id: \.self) { name in
                        Text(name.displayName).tag(name)
                    }
                }
            }

            Section("Display") {
                Picker("Font", selection: $fontNameRaw) {
                    // Monospaced first — typical code-editor pick.
                    Section("Monospaced") {
                        ForEach(EditorFont.allCases.filter(\.isMonospaced), id: \.rawValue) { face in
                            Text(face.displayName).tag(face.rawValue)
                        }
                    }
                    Section("Proportional") {
                        ForEach(EditorFont.allCases.filter { !$0.isMonospaced }, id: \.rawValue) { face in
                            Text(face.displayName).tag(face.rawValue)
                        }
                    }
                }
                LabeledContent("Font Size") {
                    Stepper(value: fontSizeBinding, in: 9...96, step: 1) {
                        Text("\(fontSizeBinding.wrappedValue) pt")
                            .monospacedDigit()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                Toggle("Show Line Numbers", isOn: $showLineNumbers)
                Toggle("Wrap Lines", isOn: $wrapLines)
                Toggle("Scroll Past Last Line", isOn: $overscroll)
                Toggle("Show Page Guide", isOn: $showPageGuide)
                LabeledContent("Page Guide Column") {
                    Stepper(value: $pageGuideColumn, in: 20...200, step: 1) {
                        Text("\(pageGuideColumn)")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Show Invisible Characters", isOn: $showInvisibles)
                CheckboxRow(label: "Space",              isOn: $showInvisibleSpace)
                CheckboxRow(label: "Tab",                isOn: $showInvisibleTab)
                CheckboxRow(label: "Newline",            isOn: $showInvisibleNewline)
                CheckboxRow(label: "Non-Breaking Space", isOn: $showInvisibleNBSP)
            } header: {
                Text("Invisible Characters")
            } footer: {
                Text("The master switch gates the whole effect; tap a row to toggle each mark.")
            }

            Section("Indentation") {
                Picker("Indent With", selection: $usesTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
                LabeledContent("Width") {
                    Stepper(value: $indentWidth, in: 1...12, step: 1) {
                        Text("\(indentWidth)")
                            .monospacedDigit()
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                }
            }

            Section("Editing") {
                Toggle("Insert Closing Brackets / Quotes Automatically", isOn: $insertCharacterPairs)
            }

            Section("Defaults for New Documents") {
                Picker("Text Encoding", selection: defaultEncodingBinding) {
                    ForEach(commonEncodings, id: \.rawValue) { encoding in
                        Text(String.localizedName(of: encoding))
                            .tag(encoding.rawValue)
                    }
                }
                Picker("Line Endings", selection: defaultLineEndingBinding) {
                    ForEach(LineEnding.allCases, id: \.self) { lineEnding in
                        Text("\(lineEnding.label)").tag(lineEnding)
                    }
                }
                Picker("Syntax Language", selection: defaultLanguageBinding) {
                    ForEach(LanguageRegistry.all, id: \.identifier) { language in
                        Text(language.displayName).tag(language.identifier)
                    }
                }
            }

            Section {
                Toggle("Ensure file ends with a newline", isOn: $ensureTrailingNewline)
                Toggle("Trim trailing whitespace", isOn: $trimTrailingWhitespace)
            } header: {
                Text("On Save")
            } footer: {
                Text("Applied each time the document is written to disk — including the debounced auto-save that fires ~800 ms after typing stops. BOM and line endings are handled per document via the encoding and line-ending pickers in the status bar.")
            }

            Section {
                Picker("Apply syntax & folding", selection: syntaxLimitBinding) {
                    ForEach(SyntaxLimit.allCases) { limit in
                        Text(limit.label).tag(limit)
                    }
                }
            } header: {
                Text("Large Files")
            } footer: {
                Text("Files over the limit open in plain-text mode for snappy typing. Tree-sitter syntax highlighting, code folding, and the Markdown inline decorator are all skipped.")
            }

            iCloudSection
        }
        // Default formStyle (insetGrouped). `.grouped` runs edge-to-edge,
        // which looks broken on iPhone where the sheet = screen width.
    }

    /// Launcher always reads from both iCloud and local, so toggling sync
    /// strands nothing — new content just stops landing in iCloud.
    @ViewBuilder
    private var iCloudSection: some View {
        let signedIn = UbiquityContainer.isAvailable
        Section {
            Toggle("Sync via iCloud Drive", isOn: $iCloudSyncEnabled)
                .disabled(!signedIn)
        } header: {
            Text("iCloud")
        } footer: {
            if signedIn {
                Text("New drafts and template seeds are written to iCloud Drive and sync across your devices. Switching this off keeps existing iCloud files reachable in the launcher — new content just goes to local storage instead.")
            } else {
                Text("Sign in to iCloud and enable Drive in the system settings to sync drafts and templates across your devices.")
            }
        }
    }
}
