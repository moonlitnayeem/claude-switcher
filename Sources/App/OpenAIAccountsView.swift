import AppKit
import SwiftUI

struct OpenAIAccountsView: View {
    @AppStorage("openai.chosenSlot") private var chosenID = OpenAIAccountSlot.first.rawValue
    @AppStorage("openai.firstLabel") private var firstLabel = ""
    @AppStorage("openai.secondLabel") private var secondLabel = ""
    @State private var rename = false
    @State private var draftName = ""
    @State private var errorText: String?
    @State private var feedback = ""
    @State private var opening = false

    private var chosen: OpenAIAccountSlot { OpenAIAccountSlot(rawValue: chosenID) ?? .first }
    private var launcher: OpenAIProfileLauncher {
        OpenAIProfileLauncher(root: Graft.graftFolder.appendingPathComponent("OpenAIProfiles", isDirectory: true))
    }
    private let accent = Color(red: 0.22, green: 0.55, blue: 0.68)
    private let copy = OpenAICopy.text

    private func name(_ slot: OpenAIAccountSlot) -> String {
        let value = slot == .first ? firstLabel : secondLabel
        return value.isEmpty ? slot.title : value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ChatGPT & Codex").font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(copy("Choose an account")).font(.headline)
                        Spacer()
                        Button(copy("Rename")) {
                            draftName = name(chosen)
                            rename = true
                        }.accessibilityLabel(copy("Rename selected account")).identified("openai.rename")
                    }
                    HStack(spacing: 8) {
                        ForEach(OpenAIAccountSlot.allCases) { slot in
                            Button {
                                chosenID = slot.rawValue
                                feedback = ""
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: chosen == slot ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                                    Text(verbatim: name(slot)).fontWeight(.medium).lineLimit(1)
                                    Spacer(minLength: 4)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 9).fill(
                                    chosen == slot ? accent.opacity(0.14) : Color.secondary.opacity(0.065)))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .stroke(chosen == slot ? accent : Color.secondary.opacity(0.28), lineWidth: 1))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(chosen == slot ? .isSelected : [])
                                .identified("openai.slot." + slot.rawValue)
                        }
                    }
                    Text(copy("Use the same email when you sign in to ChatGPT and Codex for this name."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 13).fill(Color.secondary.opacity(0.065)))

                appCard("ChatGPT", symbol: "bubble.left.and.bubble.right.fill", tone: .teal,
                        detail: copy("Open a separate Chrome window for this account. Sign in there the first time."),
                        action: copy("Open ChatGPT"), id: "openai.chat", tapped: openChat) {
                    Button(copy("Use my usual browser")) {
                        if NSWorkspace.shared.open(OpenAIProfileLauncher.chatURL) {
                            feedback = copy("In ChatGPT, open your profile menu and choose the account you want.")
                        } else { errorText = copy("Your browser could not open ChatGPT.") }
                    }
                        .buttonStyle(.link).identified("openai.usual-browser")
                        .help(copy("In ChatGPT, open your profile menu and choose the account you want."))
                }
                appCard("Codex", symbol: "terminal.fill", tone: .indigo,
                        detail: copy("Pick a project folder to start Codex in Terminal. Sign in with this account the first time."),
                        action: copy("Open Codex…"), id: "openai.codex", tapped: openCodex) {
                    if OpenAIProfileLauncher.codexURL() == nil {
                        Link(copy("Get Codex"), destination: OpenAIProfileLauncher.cliURL).identified("openai.install-codex")
                    }
                }
                Label(copy("Your choice applies to the next window. Open chats and tasks stay with their own account."),
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !feedback.isEmpty {
                    Label(feedback, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $rename) {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy("Account name")).font(.headline)
                TextField(copy("Name"), text: $draftName)
                    .identified("openai.name").onSubmit(saveName)
                HStack {
                    Spacer()
                    Button(copy("Cancel")) { rename = false }.identified("openai.cancel").keyboardShortcut(.cancelAction)
                    Button(copy("Save"), action: saveName).identified("openai.save").keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 300)
        }
        .alert(copy("Couldn’t open the account"), isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(copy("OK")) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private func appCard<Extra: View>(_ title: String, symbol: String, tone: Color, detail: String,
                                      action: String, id: String, tapped: @escaping () -> Void,
                                      @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .foregroundStyle(tone).frame(width: 37, height: 37)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { launchButton(action, id: id, tapped); extra() }
                    VStack(alignment: .leading, spacing: 8) { launchButton(action, id: id, tapped); extra() }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
    }

    private func launchButton(_ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent).tint(accent)
            .disabled(opening).identified(id)
    }

    private func saveName() {
        let cleaned = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = String(cleaned.prefix(48))
        if chosen == .first { firstLabel = label } else { secondLabel = label }
        rename = false
    }

    private func openChat() {
        let slot = chosen
        launch(message: String(format: copy("Opened ChatGPT for %@."), name(slot))) {
            try await launcher.openChat(slot)
        }
    }

    private func openCodex() {
        guard OpenAIProfileLauncher.codexURL() != nil else {
            errorText = OpenAILaunchError.codexMissing.localizedDescription
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = copy("Choose the project you want to work on.")
        panel.prompt = copy("Open Codex")
        guard panel.runModal() == .OK, let project = panel.url else { return }
        let slot = chosen
        launch(message: String(format: copy("Opened Terminal for %@."), name(slot))) {
            try await launcher.openCodex(slot, project: project)
        }
    }

    private func launch(message: String, _ action: @escaping @MainActor () async throws -> Void) {
        opening = true
        feedback = ""
        Task { @MainActor in
            defer { opening = false }
            do { try await action(); feedback = message }
            catch { errorText = error.localizedDescription }
        }
    }
}
