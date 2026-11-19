import SwiftUI

/// Labels belong to AI Switcher. Keep routing IDs, sign-ins and provider account names independent.
final class ClaudeAccountLabels: ObservableObject {
    static let graft = ClaudeAccountLabels(scope: "graft")
    static let standalone = ClaudeAccountLabels(scope: "standalone")
    static let maximumLength = 64

    private let defaults: UserDefaults
    private let key: String
    @Published private var labels: [String: String]

    init(scope: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "ClaudeAccountLabels." + scope
        labels = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func nickname(for id: String) -> String? { labels[id] }

    static func canSave(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= maximumLength &&
            !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func set(_ name: String, for id: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, Self.canSave(cleaned) else { return }
        labels[id] = cleaned.isEmpty ? nil : cleaned
        defaults.set(labels, forKey: key)
    }
}

struct ClaudeLabelTarget: Identifiable {
    let id: String
    let name: String
}

struct ClaudeAccountLabelEditor: View {
    let id: String
    let accountName: String
    @ObservedObject var labels: ClaudeAccountLabels
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var editing: Bool

    init(id: String, accountName: String, labels: ClaudeAccountLabels) {
        self.id = id
        self.accountName = accountName
        self.labels = labels
        _name = State(initialValue: labels.nickname(for: id) ?? "")
    }

    private func title(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "AccountLabels")
    }

    private var valid: Bool { ClaudeAccountLabels.canSave(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title("Name this account")).font(.title2.bold())
            Text(accountName).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            TextField(title("Account label"), text: $name)
                .accessibilityLabel(title("Account label")).focused($editing).identified("routing.nickname.field").onSubmit(save)
            Text(valid ? title("Leave the label empty to show the original name.") : title("Use one line of up to 64 characters."))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(title("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).identified("routing.nickname.cancel")
                Button(title("Save label"), action: save).disabled(!valid)
                    .keyboardShortcut(.defaultAction).identified("routing.nickname.save")
            }.padding(.top, 4)
        }.padding(22).frame(width: 360).onAppear { editing = true }
    }

    private func save() {
        guard valid else { return }
        labels.set(name, for: id)
        dismiss()
    }
}
