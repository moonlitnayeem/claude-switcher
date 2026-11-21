import SwiftUI

struct ClaudeUsageTarget: Identifiable {
    let id: UUID
    let profile: String
    let member: String
    let name: String
}

enum ClaudeUsageEditorError: LocalizedError {
    case accountChanged
    var errorDescription: String? { L10n.text("This account changed. Close this window and select the account again.") }
}

struct ClaudeUsageEditor: View {
    let accountName: String
    var readClipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }
    /// A nil value removes the locally saved readings for the selected account.
    let apply: (ClaudeUsageDisplay.Values?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        let parsed = ClaudeUsageDisplay.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            Text("Update usage from Claude").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(accountName).font(.headline).textSelection(.enabled)
            Text("In this account’s Claude Usage page, copy the text for This week and Fable. Paste it below to preview the percentages.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body.monospaced())
                .padding(5).frame(height: 100)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)) }
                .accessibilityLabel("Copied Claude Usage text").identified("routing.usage-editor.text")
            Button("Paste text") {
                if let copied = readClipboard(), !copied.isEmpty {
                    text = copied
                    error = nil
                } else {
                    error = L10n.text("Copy some text from Claude’s Usage page first.")
                }
            }.identified("routing.usage-editor.paste")
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(.headline)
                preview("Overall weekly", value: parsed.weekly, id: "weekly")
                preview("Fable usage", value: parsed.fable, id: "fable")
            }
            Text("Only the percentages you see in this preview will be saved. This updates your dashboard only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout)
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            } else if !text.isEmpty && parsed.isEmpty {
                Text("Include the This week or Fable heading and its percent used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Clear saved readings") { submit(nil) }
                    .help("Remove the readings you saved here. Readings reported by Graft can still appear.")
                    .identified("routing.usage-editor.clear")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).identified("routing.usage-editor.cancel")
                Button("Save readings") { submit(parsed) }.keyboardShortcut(.defaultAction)
                    .disabled(parsed.isEmpty).identified("routing.usage-editor.save")
            }
        }.disabled(saving).padding(20).frame(width: 480)
    }

    private func preview(_ key: String, value: Int?, id: String) -> some View {
        let reading = value.map { L10n.format("%ld%% used", $0) } ?? L10n.text("Missing from pasted text")
        return HStack {
            Text(L10n.text(key))
            Spacer()
            Text(reading).foregroundStyle(.secondary)
        }.font(.callout)
         .spoken(L10n.text(key), value: reading).identified("routing.usage-editor." + id)
    }

    private func submit(_ values: ClaudeUsageDisplay.Values?) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await apply(values)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
