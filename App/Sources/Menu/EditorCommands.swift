import SwiftUI
import UIKit
import FileEncoding
import LineEnding
import LineSort

/// iPadOS menu-bar wiring. Every Button routes through
/// `CommandActions` so the command palette can share the same code.
struct EditorCommands: Commands {

    @Bindable private var bus = AppStateBus.shared
    @Environment(\.openWindow) private var openWindow
    /// `@State` so the menu rebuilds when the store mutates —
    /// reading `.shared` inline from a ViewBuilder doesn't subscribe.
    @State private var snippetsStore = SnippetsStore.shared
    @State private var jsTransformStore = JSTransformStore.shared
    @State private var recentFilesStore = RecentFilesStore.shared
    /// `@FocusedValue` so sheet triggers and tab commands hit the
    /// foreground window, not whichever scene happens to be the
    /// stale `currentEditor` on the bus.
    @FocusedValue(\.presentEditorSheet) private var focusedPresenter: SheetPresenter?
    @FocusedValue(\.focusedSession) private var focusedSession: EditorSession?

    private var editorState: EditorState? { bus.scenes.currentEditor }
    private var isEnabled: Bool { editorState != nil }

    /// Resyncs the bus to the focused scene before any CommandAction
    /// runs — otherwise actions can target a stale `currentEditor`
    /// during iPad Stage Manager focus shifts.
    private func claimFocus() {
        guard let session = focusedSession else { return }
        if AppStateBus.shared.scenes.currentSession !== session {
            AppStateBus.shared.scenes.currentSession = session
        }
        let activeState = session.activeTab.state
        if AppStateBus.shared.scenes.currentEditor !== activeState {
            AppStateBus.shared.scenes.currentEditor = activeState
        }
    }

    /// Routes through the focused scene's presenter when available
    /// and falls back to the bus on cold launch. Always claims focus
    /// first — fixes the "Clipboard History opens on the wrong
    /// window" class of bug for every menu sheet at once.
    private func presentSheet(_ sheet: EditorSheet) {
        claimFocus()
        if let focusedPresenter {
            focusedPresenter(sheet)
        } else {
            bus.editing.presentedSheet = sheet
        }
    }

    /// Every menu Button in this file should route through here.
    /// Without claimFocus the action reads a possibly-stale
    /// `currentEditor` / `currentSession` and targets a background
    /// window during iPad Stage Manager / Split View transitions.
    ///
    /// Use as `Button("X", action: focused(CommandActions.x))`, or
    /// for inline closures: `Button("X") { focused { … } }`.
    private func focused(_ action: @escaping @MainActor () -> Void) -> () -> Void {
        {
            claimFocus()
            action()
        }
    }

    private func focused(_ action: () -> Void) {
        claimFocus()
        action()
    }

    var body: some Commands {

        // Suppress the system text-formatting group (Bold / Italic /
        // Underline) — its defaults claim ⌘B / ⌘I and would collide
        // with our Markdown menu, dropping the latter via
        // `_UIMenuBuilderError`.
        CommandGroup(replacing: .textFormatting) { }

        // MARK: App — Preferences, Command Palette

        // Grouped so they count as one CommandsBuilder slot (body is
        // at the 10-child cap):
        //   1. Replace iOS 26's auto-injected "Settings…" — without
        //      a Settings.bundle, the system item routes to a blank
        //      Settings.app page.
        //   2. Add Command Palette… after the Preferences entry.
        Group {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: SceneID.preferences.rawValue) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Command Palette…") { presentSheet(.commandPalette) }
                    .keyboardShortcut(";", modifiers: .command)
            }
        }

        // MARK: File — New (new scene) / Open / Save / Save As

        CommandGroup(replacing: .newItem) {
            // ⌘N is always a fresh window, ⌘T always a new tab —
            // they override the destination preference per spec.
            // iPhone is single-window so the item is hidden.
            if DeviceIdiom.supportsMultipleWindows {
                Button("New Window") { openWindow(id: SceneID.editor.rawValue) }
                    .keyboardShortcut("n")
            }
            // No `.disabled(...)`: SwiftUI evaluates the disable
            // expression at menu-build time, so a transient nil
            // session during a scene swap would leave the item
            // greyed out indefinitely. Fall back to a new window.
            Button("New Tab") {
                // Prefer the focused session — the bus's
                // currentSession can lag on iPad Stage Manager.
                if let session = focusedSession ?? AppStateBus.shared.scenes.currentSession {
                    session.newTab()
                    CommandActions.offerDraftsIfAvailable()
                } else {
                    openWindow(id: SceneID.editor.rawValue)
                }
            }
            .keyboardShortcut("t")
            // Unshortcut'd: `LSSupportsOpeningDocumentsInPlace = YES`
            // makes iPadOS auto-inject its own ⌘O Open (which already
            // routes through `.onOpenURL` → destination preference).
            // Binding our button to ⌘O would collide and `_UIMenu-
            // BuilderError` would drop the entire `.newItem`
            // replacement. iPhone is single-window so "new window"
            // collapses to "new tab" in practice.
            Button(DeviceIdiom.supportsMultipleWindows ? "Open…" : "Open in New Tab…") {
                claimFocus()
                if DeviceIdiom.supportsMultipleWindows {
                    CommandActions.presentFileBrowserInNewWindow()
                } else {
                    CommandActions.presentFileBrowserInNewTab()
                }
            }
            // No `Menu("Open Recent")` here: iPadOS auto-injects one
            // when `LSSupportsOpeningDocumentsInPlace = YES`, and the
            // previous explicit Menu produced a duplicate entry.
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { AppStateBus.shared.editing.saveCurrentDocument?() }
                .keyboardShortcut("s")
                .disabled(!isEnabled)
            Button("Save As…") { AppStateBus.shared.pickers.pending = .saveAs }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!isEnabled)
            Divider()
            Button("Revert to Saved") {
                AppStateBus.shared.editing.revertRequestCount += 1
            }
            .disabled(!isEnabled)
            Button("Show Revisions…") {
                presentSheet(.revisions)
            }
            .keyboardShortcut("h", modifiers: [.command, .option])
            .disabled(!isEnabled)
            // App-lifetime entry to the recovery sheet (drafts
            // persist until the user explicitly Discards or Saves).
            Button("Recover Unsaved Drafts…") {
                presentSheet(.draftsRecovery)
            }
            Divider()
            Button("Speak Selection", action: focused(CommandActions.speakSelection))
                .disabled(!isEnabled)
        }

        // MARK: Edit — selection submenu + character-level edits

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Clipboard History…") { presentSheet(.clipboardHistory) }
                .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Menu("Selection") {
                Button("Select Word", action: focused(CommandActions.selectCurrentWord))
                Button("Select Line", action: focused(CommandActions.selectCurrentLine))
                Button("Select Lines Containing…") { presentSheet(.selectLinesContaining) }
                Divider()
                Button("Smart Move to Line Start", action: focused(CommandActions.smartMoveToLineStart))
            }
            .disabled(!isEnabled)

            Divider()

            Button("Transpose Characters", action: focused(CommandActions.transposeCharacters))
                .keyboardShortcut("t", modifiers: .control)
                .disabled(!isEnabled)
            Button("Delete to End of Line", action: focused(CommandActions.deleteToEndOfLine))
                .keyboardShortcut("k", modifiers: .control)
                .disabled(!isEnabled)
            Button("Delete Word Backward", action: focused(CommandActions.deleteWordBackward))
                .keyboardShortcut(.delete, modifiers: .option)
                .disabled(!isEnabled)
            Button("Delete Word Forward", action: focused(CommandActions.deleteWordForward))
                .keyboardShortcut(.deleteForward, modifiers: .option)
                .disabled(!isEnabled)
            Button("Join Lines", action: focused(CommandActions.joinLines))
                .keyboardShortcut("j", modifiers: .control)
                .disabled(!isEnabled)
        }

        // MARK: Search

        // Items in `findSubmenuContent` so the same body can move
        // between an Edit submenu and a top-level menu.
        CommandMenu("Search") {
            findSubmenuContent
        }

        // MARK: View — append to iPadOS's auto-injected View menu.
        //
        // `CommandMenu("View")` would collide with the system title
        // and lose. `CommandGroup(replacing: .toolbar)` buries items
        // inside a Toolbar submenu. `CommandGroup(after: .sidebar)`
        // lands at the View menu's top level, which is where the
        // user looks.
        //
        // The system-injected Show Sidebar drives UIKit's sidebar
        // API, but our outline panel reads `state.sidebarOpen` —
        // replace it with a working Show Outline toggle.
        CommandGroup(replacing: .sidebar) {
            Button("Show Outline", action: focused(CommandActions.showOutline))
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!isEnabled)
        }
        CommandGroup(after: .sidebar) {
            viewMenuFontItems
            Divider()
            viewMenuToggleItems
            Divider()
            viewMenuFoldItems
            Divider()
            viewMenuTailItems
        }

        // MARK: Text — line operations + content transforms

        CommandMenu("Text") {
            Group {
                // Each preset is one tap — a dialog felt heavy for
                // nine fixed wraps.
                Menu("Surround Selection") {
                    Button("Bold **…**")       { focused { CommandActions.surroundSelection(prefix: "**", suffix: "**") } }
                    Button("Italic _…_")       { focused { CommandActions.surroundSelection(prefix: "_",  suffix: "_") } }
                    Divider()
                    Button("Parentheses ( )") { focused { CommandActions.surroundSelection(prefix: "(",  suffix: ")") } }
                    Button("Brackets [ ]")    { focused { CommandActions.surroundSelection(prefix: "[",  suffix: "]") } }
                    Button("Braces { }")      { focused { CommandActions.surroundSelection(prefix: "{",  suffix: "}") } }
                    Button("Angles < >")      { focused { CommandActions.surroundSelection(prefix: "<",  suffix: ">") } }
                    Divider()
                    Button("Double Quotes \"\"") { focused { CommandActions.surroundSelection(prefix: "\"", suffix: "\"") } }
                    Button("Single Quotes ''")   { focused { CommandActions.surroundSelection(prefix: "'",  suffix: "'") } }
                    Button("Backticks ``")       { focused { CommandActions.surroundSelection(prefix: "`",  suffix: "`") } }
                }

                Divider()

                // Most-used line ops (move/dup/delete) live at the
                // top; transforms (sort/reverse/etc.) follow.
                Menu("Lines") {
                    Button("Move Line Up", action: focused(CommandActions.moveLineUp))
                        .keyboardShortcut(.upArrow, modifiers: .option)
                    Button("Move Line Down", action: focused(CommandActions.moveLineDown))
                        .keyboardShortcut(.downArrow, modifiers: .option)
                    Button("Duplicate Line", action: focused(CommandActions.duplicateLine))
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    Button("Delete Line", action: focused(CommandActions.deleteLine))
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                    Divider()
                    Button("Sort Lines…", action: focused(CommandActions.sortLines))
                    Button("Reverse Lines", action: focused(CommandActions.reverseLines))
                    Button("Unique Lines", action: focused(CommandActions.uniqueLines))
                    Button("Remove Blank Lines", action: focused(CommandActions.removeBlankLines))
                    Divider()
                    Button("Add Linebreaks", action: focused(CommandActions.addLinebreaks))
                    Button("Remove Linebreaks", action: focused(CommandActions.removeLinebreaks))
                    Divider()
                    Button("Add Line Numbers", action: focused(CommandActions.addLineNumbers))
                    Button("Remove Line Numbers", action: focused(CommandActions.removeLineNumbers))
                    Button("Prefix / Suffix Lines…", action: focused(CommandActions.presentPrefixSuffixLines))
                    Divider()
                    Button("Process Lines Containing…", action: focused(CommandActions.presentProcessLines))
                }

                Menu("Transform") {
                    Button("UPPERCASE", action: focused(CommandActions.uppercase))
                    Button("lowercase", action: focused(CommandActions.lowercase))
                    Button("Capitalized", action: focused(CommandActions.capitalize))
                    Button("Title Case", action: focused(CommandActions.titleCase))
                    Divider()
                    Button("snake_case", action: focused(CommandActions.snakeCase))
                    Button("kebab-case", action: focused(CommandActions.kebabCase))
                    Button("camelCase", action: focused(CommandActions.camelCase))
                    Button("PascalCase", action: focused(CommandActions.pascalCase))
                    Divider()
                    Menu("Normalize Unicode") {
                        Button("NFC — Canonical Composed", action: focused(CommandActions.normalizeNFC))
                        Button("NFD — Canonical Decomposed", action: focused(CommandActions.normalizeNFD))
                        Button("NFKC — Compatibility Composed", action: focused(CommandActions.normalizeNFKC))
                        Button("NFKD — Compatibility Decomposed", action: focused(CommandActions.normalizeNFKD))
                    }
                    Menu("Encode / Decode") {
                        Button("URL Encode", action: focused(CommandActions.urlEncode))
                        Button("URL Decode", action: focused(CommandActions.urlDecode))
                        Divider()
                        Button("Base64 Encode", action: focused(CommandActions.base64Encode))
                        Button("Base64 Decode", action: focused(CommandActions.base64Decode))
                    }
                    Divider()
                    Button("Reverse Selection", action: focused(CommandActions.reverseSelection))
                }

                Menu("Cleanup") {
                    Menu("Whitespace") {
                        Button("Trim Trailing Whitespace", action: focused(CommandActions.trimTrailingWhitespace))
                        Divider()
                        Button("Normalize Spaces", action: focused(CommandActions.normalizeSpaces))
                        Button("Convert Tabs to Spaces", action: focused(CommandActions.tabsToSpaces))
                        Button("Convert Spaces to Tabs", action: focused(CommandActions.spacesToTabs))
                        Button("Normalize Line Endings", action: focused(CommandActions.normalizeLineEndingsToDocument))
                    }
                    Menu("Quotes & Escapes") {
                        Button("Educate Quotes", action: focused(CommandActions.educateQuotes))
                        Button("Straighten Quotes", action: focused(CommandActions.straightenQuotes))
                        Divider()
                        Button("Interpret Escape Sequences", action: focused(CommandActions.interpretEscapeSequences))
                        Button("Escape Special Characters", action: focused(CommandActions.escapeSpecialCharacters))
                    }
                    Divider()
                    Button("Zap Gremlins…", action: focused(CommandActions.presentZapGremlins))
                    Button("Strip Diacritics", action: focused(CommandActions.stripDiacritics))
                    Button("Convert to ASCII", action: focused(CommandActions.convertToASCII))
                    Divider()
                    Button("Canonize…", action: focused(CommandActions.presentCanonize))
                }

                Divider()

                Menu("Insert") {
                    Button("Date & Time", action: focused(CommandActions.insertDateTime))
                    Button("Date", action: focused(CommandActions.insertDate))
                    Button("Time", action: focused(CommandActions.insertTime))
                    Divider()
                    Button("Tab", action: focused(CommandActions.insertTab))
                    Button("Newline", action: focused(CommandActions.insertNewline))
                    Divider()
                    Button("File Contents…", action: focused(CommandActions.presentInsertFileContents))
                    Button("Folder Listing…", action: focused(CommandActions.presentInsertFolderListing))
                    Button("Lorem Ipsum…", action: focused(CommandActions.presentInsertLoremIpsum))
                }

                Menu("Snippets") {
                    Button("Insert Snippet…", action: focused(CommandActions.presentSnippetPicker))
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                    if !snippetsStore.snippets.isEmpty {
                        Divider()
                        ForEach(snippetsStore.snippets) { snippet in
                            Button(snippet.name.isEmpty ? "(unnamed)" : snippet.name) {
                                focused { CommandActions.insertSnippet(snippet) }
                            }
                        }
                    }
                    Divider()
                    Button("Manage Snippets…", action: focused(CommandActions.presentSnippetsManager))
                }

                Menu("JavaScript Transforms") {
                    jsTransformItems
                }

                // Markdown lives under Text — saves a top-level menu
                // slot. Show Outline / Preview are also in View since
                // they're view-state.
                Menu("Markdown") { markdownSubmenuContent }
            }
            .disabled(!isEnabled)
        }

        // MARK: Tabs (attached to the system Window menu)

        CommandGroup(after: .windowArrangement) {
            Button("Show All Tabs", action: focused(CommandActions.showTabSwitcher))
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Close Tab", action: focused(CommandActions.closeActiveTab))
                .keyboardShortcut("w")
            Button("Reopen Last Closed Tab", action: focused(CommandActions.reopenLastClosedTab))
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab", action: focused(CommandActions.nextTab))
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab", action: focused(CommandActions.previousTab))
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Pin / Unpin Tab", action: focused(CommandActions.pinCurrentTab))
            Button("Close Other Tabs", action: focused(CommandActions.closeOtherTabs))
            Button("Close Tabs to the Right", action: focused(CommandActions.closeTabsToRight))
            Divider()
            Menu("Jump to Tab") {
                Button("Tab 1") { focused { CommandActions.selectTab(at: 1) } }.keyboardShortcut("1")
                Button("Tab 2") { focused { CommandActions.selectTab(at: 2) } }.keyboardShortcut("2")
                Button("Tab 3") { focused { CommandActions.selectTab(at: 3) } }.keyboardShortcut("3")
                Button("Tab 4") { focused { CommandActions.selectTab(at: 4) } }.keyboardShortcut("4")
                Button("Tab 5") { focused { CommandActions.selectTab(at: 5) } }.keyboardShortcut("5")
                Button("Tab 6") { focused { CommandActions.selectTab(at: 6) } }.keyboardShortcut("6")
                Button("Tab 7") { focused { CommandActions.selectTab(at: 7) } }.keyboardShortcut("7")
                Button("Tab 8") { focused { CommandActions.selectTab(at: 8) } }.keyboardShortcut("8")
                Button("Last Tab") { focused { CommandActions.selectTab(at: 9) } }.keyboardShortcut("9")
            }
        }
    }

    // MARK: - Markdown menu

    /// View ▸ Format submenu body.
    @ViewBuilder
    private var formatSubmenuContent: some View {
        Group {
            Menu("File Encoding")        { encodingMenuItems }
            Menu("Reopen with Encoding") { reopenWithEncodingMenuItems }
            Menu("Line Endings")         { lineEndingMenuItems }

            Divider()

            Menu("Syntax Style") { syntaxLanguageMenuItems }

            Divider()

            Menu("Indent") { indentMenuItems }
            Button("Indent Selection", action: focused(CommandActions.indentSelection))
                .keyboardShortcut("]")
            Button("Outdent Selection", action: focused(CommandActions.outdentSelection))
                .keyboardShortcut("[")
        }
        Divider()
        Group {
            Menu("Convert to List") {
                // Distinct titles from the Markdown ▸ List submenu —
                // UIKit derives UIAction identifiers from the title,
                // and duplicates make iPadOS drop the whole owning
                // menu via `_UIMenuBuilderError`.
                Button("Format as Dash List", action: focused(CommandActions.convertToBulletListDash))
                Button("Format as Asterisk List", action: focused(CommandActions.convertToBulletListStar))
                Button("Format as Numbered List", action: focused(CommandActions.convertToNumberedList))
            }

            Divider()

            Menu("Spelling") {
                Toggle("Check Spelling While Typing",
                       isOn: bindingFor(\.spellCheck, defaultsKey: AppPreferenceKey.spellCheck))
                Divider()
                // Unshortcut'd: ⌘; collides with Command Palette and
                // ⇧⌘' with Markdown ▸ Blockquote — either would drop
                // the whole Spelling submenu via `_UIMenuBuilderError`.
                // Manual check stays useful even when the live
                // toggle is off (audit on demand without the
                // squiggles).
                Button("Check Document Spelling", action: focused(CommandActions.highlightAllMisspellings))
                Button("Clear Spelling Marks", action: focused(CommandActions.clearMisspellingHighlights))
                Divider()
                Button("Find Next Misspelling", action: focused(CommandActions.jumpToNextMisspelling))
                Button("Learn Spelling of Word", action: focused(CommandActions.learnSelectedWord))
                Button("Ignore Spelling for Word", action: focused(CommandActions.ignoreSelectedWord))
            }
        }
    }

    @ViewBuilder
    private var viewMenuFontItems: some View {
        Button("Bigger Font", action: focused(CommandActions.increaseFontSize))
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!isEnabled)
        Button("Smaller Font", action: focused(CommandActions.decreaseFontSize))
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!isEnabled)
        Button("Reset Font Size", action: focused(CommandActions.resetFontSize))
            .keyboardShortcut("0", modifiers: .command)
            .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuToggleItems: some View {
        Toggle("Show Line Numbers", isOn: bindingFor(\.showLineNumbers, defaultsKey: AppPreferenceKey.showLineNumbers))
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!isEnabled)
        Toggle("Wrap Lines", isOn: bindingFor(\.wrapLines, defaultsKey: AppPreferenceKey.wrapLines))
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Toggle("Show Invisibles", isOn: bindingFor(\.showInvisibles, defaultsKey: AppPreferenceKey.showInvisibles))
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!isEnabled)
        Toggle("Show Page Guide", isOn: bindingFor(\.showPageGuide, defaultsKey: AppPreferenceKey.showPageGuide))
            .disabled(!isEnabled)
        Toggle("Show Status Bar", isOn: bindingFor(\.showStatusBar, defaultsKey: AppPreferenceKey.showStatusBar))
            .disabled(!isEnabled)
        Toggle("Show Toolbar", isOn: bindingFor(\.showToolbar, defaultsKey: AppPreferenceKey.showToolbar))
            .disabled(!isEnabled)
        Toggle("Highlight All Occurrences of Selection",
               isOn: bindingFor(\.liveMatchHighlight, defaultsKey: AppPreferenceKey.liveMatchHighlight))
            .disabled(!isEnabled)
        Toggle("Show Change History in Gutter",
               isOn: bindingFor(\.showChangeHistoryGutter, defaultsKey: AppPreferenceKey.showChangeHistoryGutter))
            .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuFoldItems: some View {
        // ⌃⌘F matches Xcode's Code Folding convention; ⌥⌘F is taken
        // by Find and Replace.
        Button("Fold at Cursor", action: focused(CommandActions.toggleFoldAtCursor))
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(!isEnabled)
        Button("Fold Selection", action: focused(CommandActions.foldSelection))
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(!isEnabled)
        Button("Fold All", action: focused(CommandActions.foldAll))
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Button("Unfold All", action: focused(CommandActions.unfoldAll))
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Button("Clear Manual Fold Points", action: focused(CommandActions.clearManualFolds))
            .disabled(!isEnabled)
    }

    @ViewBuilder
    private var viewMenuTailItems: some View {
        Button("Cycle Split View", action: focused(CommandActions.cycleSplitView))
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Divider()
        Button("Show File Information", action: focused(CommandActions.toggleInspector))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!isEnabled)
        Button("Character Inspector…", action: focused { presentSheet(.characterInspector) })
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(!isEnabled)
        Divider()
        Menu("Bookmarks") { bookmarkMenuItems }
            .disabled(!isEnabled)
        Divider()
        Menu("Format") { formatSubmenuContent }
            .disabled(!isEnabled)
    }

    /// Extracted so the submenu and any future palette / shortcut
    /// wiring share one source.
    @ViewBuilder
    private var markdownSubmenuContent: some View {
        Group {
            Button("Bold", action: focused(CommandActions.markdownBold))
                .keyboardShortcut("b")
            Button("Italic", action: focused(CommandActions.markdownItalic))
                .keyboardShortcut("i")
            Button("Inline Code", action: focused(CommandActions.markdownCode))
                .keyboardShortcut("`")
            Button("Strikethrough", action: focused(CommandActions.markdownStrike))
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Menu("Heading") {
                Button("Heading 1") { focused { CommandActions.markdownHeader(level: 1) } }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Heading 2") { focused { CommandActions.markdownHeader(level: 2) } }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Heading 3") { focused { CommandActions.markdownHeader(level: 3) } }
                    .keyboardShortcut("3", modifiers: [.command, .control])
                Button("Heading 4") { focused { CommandActions.markdownHeader(level: 4) } }
                    .keyboardShortcut("4", modifiers: [.command, .control])
                Button("Heading 5") { focused { CommandActions.markdownHeader(level: 5) } }
                    .keyboardShortcut("5", modifiers: [.command, .control])
                Button("Heading 6") { focused { CommandActions.markdownHeader(level: 6) } }
                    .keyboardShortcut("6", modifiers: [.command, .control])
            }
            Menu("List") {
                Button("Bullet List (- )", action: focused(CommandActions.convertToBulletListDash))
                Button("Bullet List (* )", action: focused(CommandActions.convertToBulletListStar))
                Button("Numbered List", action: focused(CommandActions.convertToNumberedList))
            }
        }
        Divider()
        Group {
            Button("Blockquote", action: focused(CommandActions.markdownBlockquote))
                .keyboardShortcut("'", modifiers: [.command, .shift])
            Button("Horizontal Rule", action: focused(CommandActions.markdownHorizontalRule))
                .keyboardShortcut("-", modifiers: [.command, .shift])
            Button("Link…", action: focused(CommandActions.markdownLink))
                .keyboardShortcut("k")
            Button("Image…", action: focused(CommandActions.markdownImage))
                .keyboardShortcut("k", modifiers: [.command, .option])
            // ⌥⌘N — ⇧⌘0 collides with Default Zoom, ⌃⌘F with Fold
            // at Cursor.
            Button("Footnote", action: focused(CommandActions.markdownFootnote))
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Organize Footnotes…") { presentSheet(.organizeFootnotes) }
            Button("Insert Table…", action: focused(CommandActions.presentMarkdownTable))
                .keyboardShortcut("t", modifiers: [.command, .control])
            Divider()
            Button("Preview…", action: focused(CommandActions.presentMarkdownPreview))
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }

    /// Body of the Search menu — pulled out so the same items can
    /// live under Edit ▸ Find too.
    @ViewBuilder
    private var findSubmenuContent: some View {
        Group {
            Button("Find…") {
                // Mirror presentSheet's claimFocus so the seed
                // selection comes from the focused editor.
                focused {
                    CommandActions.seedFindFromSelection()
                    presentSheet(.findReplace)
                }
            }
            .keyboardShortcut("f")
            Button("Multi-File Search…", action: focused(CommandActions.presentMultiFileSearch))
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        Divider()

        Group {
            Button("Go to Line…") { presentSheet(.goToLine) }
                .keyboardShortcut("l")
            // ⌃⌘B — ⇧⌘\ is Show All Tabs.
            Button("Go to Matching Bracket", action: focused(CommandActions.goToMatchingBracket))
                .keyboardShortcut("b", modifiers: [.command, .control])
            Button("Center Line", action: focused(CommandActions.centerLine))
        }

        Divider()

        Group {
            Divider()

            Button("Back", action: focused(CommandActions.positionBack))
                .keyboardShortcut(.leftArrow,  modifiers: [.command, .control])
            Button("Forward", action: focused(CommandActions.positionForward))
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
        }
    }

    /// Inactive slots stay visible (disabled) so the user can see
    /// which shortcuts are open to assign. Reads `.shared` per build
    /// so edits propagate live.
    @ViewBuilder
    private var jsTransformItems: some View {
        let slots = jsTransformStore.slots
        ForEach(slots) { slot in
            Button(slot.displayName) {
                focused { CommandActions.runJSTransform(slotID: slot.id) }
            }
            .keyboardShortcut(jsShortcutKey(for: slot.id), modifiers: [.control, .option])
            .disabled(!slot.isConfigured)
        }
        Divider()
        Button("Manage Transforms…", action: focused(CommandActions.presentPreferences))
    }

    private func jsShortcutKey(for id: Int) -> KeyEquivalent {
        // Slot 10 → "0", matching the tab-jump scheme.
        switch id {
        case 10: return "0"
        default: return KeyEquivalent(Character("\(id)"))
        }
    }

    // MARK: - Submenu builders

    @ViewBuilder
    private var encodingMenuItems: some View {
        ForEach(commonEncodings, id: \.self) { encoding in
            Button {
                focused { CommandActions.setEncoding(encoding) }
            } label: {
                if editorState?.fileEncoding == encoding {
                    Label(encoding.localizedName, systemImage: "checkmark")
                } else {
                    Text(encoding.localizedName)
                }
            }
        }
        Divider()
        Button("More Encodings…") { presentSheet(.encodingPicker) }
    }

    @ViewBuilder
    private var reopenWithEncodingMenuItems: some View {
        ForEach(commonEncodings, id: \.self) { encoding in
            Button(encoding.localizedName) {
                focused { CommandActions.reinterpretWithEncoding(encoding) }
            }
        }
    }

    @ViewBuilder
    private var lineEndingMenuItems: some View {
        ForEach(LineEnding.allCases, id: \.self) { lineEnding in
            Button {
                focused { CommandActions.applyLineEnding(lineEnding) }
            } label: {
                let title = "\(lineEnding.label) (\(lineEnding.description))"
                if editorState?.lineEnding == lineEnding {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }

    @ViewBuilder
    private var syntaxLanguageMenuItems: some View {
        ForEach(LanguageRegistry.all, id: \.identifier) { language in
            Button {
                focused { CommandActions.setLanguage(language.identifier) }
            } label: {
                if editorState?.languageIdentifier == language.identifier {
                    Label(language.displayName, systemImage: "checkmark")
                } else {
                    Text(language.displayName)
                }
            }
        }
    }

    @ViewBuilder
    private var openRecentMenuItems: some View {
        let recents = recentFilesStore.urls
        if recents.isEmpty {
            Text("No Recent Files").disabled(true)
        } else {
            ForEach(recents, id: \.self) { url in
                Button(url.lastPathComponent) {
                    // Same pipeline as File → Open so a recent file
                    // lands in a new window, not in place.
                    if let route = AppStateBus.shared.scenes.routeOpenURL {
                        route(url)
                    } else {
                        AppStateBus.shared.pending.newWindow = url
                        AppStateBus.shared.scenes.openWindowAction?(.editor)
                    }
                }
            }
            Divider()
            Button("Clear Menu") { recentFilesStore.clear() }
        }
    }

    @ViewBuilder
    private var bookmarkMenuItems: some View {
        Menu("Set Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.setBookmark(slot) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: [.command, .shift])
            }
        }
        Menu("Jump to Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.jumpToBookmark(slot) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .option)
            }
        }
        Menu("Clear Bookmark") {
            ForEach(0..<10, id: \.self) { slot in
                Button("Slot \(slot)") {
                    focused { CommandActions.clearBookmark(slot) }
                }
            }
        }
        Divider()
        Button("Copy Bookmarked Lines", action: focused(CommandActions.copyBookmarkedLines))
        Button("Cut Bookmarked Lines", action: focused(CommandActions.cutBookmarkedLines))
        Button("Keep Only Bookmarked Lines", action: focused(CommandActions.keepBookmarkedLinesOnly))
        Button("Delete Bookmarked Lines", action: focused(CommandActions.removeBookmarkedLines))
        Divider()
        Button("Invert Bookmarks", action: focused(CommandActions.invertBookmarks))
    }

    @ViewBuilder
    private var indentMenuItems: some View {
        Button {
            focused { CommandActions.setIndentUsesTabs(false) }
        } label: {
            if editorState?.usesTabs == false {
                Label("Use Spaces", systemImage: "checkmark")
            } else {
                Text("Use Spaces")
            }
        }
        Button {
            focused { CommandActions.setIndentUsesTabs(true) }
        } label: {
            if editorState?.usesTabs == true {
                Label("Use Tabs", systemImage: "checkmark")
            } else {
                Text("Use Tabs")
            }
        }
        Divider()
        ForEach([2, 3, 4, 6, 8], id: \.self) { width in
            Button {
                focused { CommandActions.setIndentWidth(width) }
            } label: {
                if editorState?.indentWidth == width {
                    Label("Width: \(width)", systemImage: "checkmark")
                } else {
                    Text("Width: \(width)")
                }
            }
        }
    }

    private var commonEncodings: [FileEncoding] {
        [
            FileEncoding(encoding: .utf8),
            FileEncoding(encoding: .utf8, withUTF8BOM: true),
            FileEncoding(encoding: .utf16),
            FileEncoding(encoding: .utf16LittleEndian),
            FileEncoding(encoding: .utf16BigEndian),
            FileEncoding(encoding: .windowsCP1252),
            FileEncoding(encoding: .isoLatin1),
            FileEncoding(encoding: .macOSRoman),
            FileEncoding(encoding: .shiftJIS),
            FileEncoding(encoding: .japaneseEUC)
        ]
    }

    /// `defaultsKey` writes back to UserDefaults so the change
    /// survives relaunch. The getter falls back to the stored pref
    /// on cold launch — without that, the toggle would visually lie
    /// about whether the pref is on.
    private func bindingFor(
        _ keyPath: ReferenceWritableKeyPath<EditorState, Bool>,
        defaultsKey: String? = nil
    ) -> Binding<Bool> {
        Binding(
            get: {
                if let state = editorState { return state[keyPath: keyPath] }
                if let defaultsKey { return UserDefaults.standard.bool(forKey: defaultsKey) }
                return false
            },
            set: { newValue in
                editorState?[keyPath: keyPath] = newValue
                if let defaultsKey {
                    UserDefaults.standard.set(newValue, forKey: defaultsKey)
                }
            }
        )
    }
}
