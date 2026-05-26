import SwiftUI

/// Settings for the iPhone keyboard accessory bar. v1 surfaces the
/// drawer-default toggle and the Control / Shift quick-reference;
/// reorder + custom-keys editing are Phase 2.
struct AccessoryKeyboardSettingsSheet: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferenceKey.accessoryDrawerOpenByDefault)
    private var drawerOpenByDefault: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Open Drawer by Default", isOn: $drawerOpenByDefault)
                } footer: {
                    Text("When on, the punctuation drawer is expanded the moment the keyboard appears.")
                }

                Section("Sticky Modifiers") {
                    Text("Tap **Control** then a letter on the iOS keyboard to fire its shortcut:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    keyRow("⌃A", "Move to start of line")
                    keyRow("⌃E", "Move to end of line")
                    keyRow("⌃F / ⌃B", "Move cursor right / left")
                    keyRow("⌃N / ⌃P", "Move cursor down / up")
                    keyRow("⌃K", "Delete to end of line")
                    keyRow("⌃D / ⌃H", "Delete word forward / back")
                    keyRow("⌃T", "Transpose characters")
                    keyRow("⌃J", "Join lines")
                }

                Section {
                    Text("Tap **Shift** to capitalize the next letter typed on the iOS keyboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Tap the **Escape** key to clear armed modifiers, dismiss the find sheet, or collapse the current selection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Escape")
                }
            }
            .navigationTitle("Keyboard Accessory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ chord: String, _ description: String) -> some View {
        HStack {
            Text(chord)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .frame(width: 96, alignment: .leading)
            Text(description)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
