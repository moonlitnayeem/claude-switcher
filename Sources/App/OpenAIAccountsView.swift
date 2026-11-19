import AppKit
import SwiftUI

struct OpenAIAccountsView: View {
    @AppStorage("openai.profileIndex") private var storedIndex: Data?
    @AppStorage("openai.chosenSlot") private var legacySelection = "first"
    @AppStorage("openai.firstLabel") private var legacyFirst = ""
    @AppStorage("openai.secondLabel") private var legacySecond = ""
    @AppStorage("openai.lastProject") private var lastProject = ""
    @AppStorage("openai.lastDesktopProject") private var lastDesktopProject = ""
    @AppStorage("openai.showSeparateProfiles") private var showSeparateProfiles = false
    @State private var editing = false
    @State private var editingID: OpenAIAccountSlot?
    @State private var pendingRemoval: OpenAIProfileIndex.Profile?
    @State private var draftName = ""
    @State private var errorText: String?
    @State private var feedback = ""
    @State private var opening = false

    private var index: OpenAIProfileIndex? {
        if let storedIndex { return try? JSONDecoder().decode(OpenAIProfileIndex.self, from: storedIndex) }
        return OpenAIProfileIndex(legacyFirst: legacyFirst, legacySecond: legacySecond, legacySelection: legacySelection)
    }
    private var launcher: OpenAIProfileLauncher {
        OpenAIProfileLauncher(root: Graft.graftFolder.appendingPathComponent("OpenAIProfiles", isDirectory: true))
    }
    private let accent = Color(red: 0.22, green: 0.55, blue: 0.68)
    private let copy = OpenAICopy.text

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("ChatGPT & Codex").font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                desktopCard
                Button {
                    showSeparateProfiles.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: showSeparateProfiles ? "chevron.down" : "chevron.right").accessibilityHidden(true)
                        Text(copy("Browser and Terminal profiles")).font(.headline)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(copy(showSeparateProfiles ? "Expanded" : "Collapsed"))
                .identified("openai.separate-accounts")
                if showSeparateProfiles {
                    VStack(alignment: .leading, spacing: 14) {
                        if let index {
                            accountList(index)
                        } else {
                            Label(copy("Your saved account list could not be read."), systemImage: "exclamationmark.circle")
                        }

                        appCard(copy("ChatGPT in Chrome"), symbol: "bubble.left.and.bubble.right.fill", tone: .teal,
                                detail: copy("Open a separate Chrome window for this account. Sign in there the first time."),
                                action: copy("Open in Chrome"), id: "openai.chat", tapped: openChat) {
                            Button(copy("Use my usual browser")) {
                                if NSWorkspace.shared.open(OpenAIProfileLauncher.chatURL) {
                                    feedback = copy("In ChatGPT, open your profile menu and choose the account you want.")
                                } else { errorText = copy("Your browser could not open ChatGPT.") }
                            }
                                .buttonStyle(.link).identified("openai.usual-browser")
                                .help(copy("In ChatGPT, open your profile menu and choose the account you want."))
                        }
                        appCard(copy("Codex in Terminal"), symbol: "terminal.fill", tone: .indigo,
                                detail: copy("Pick a project folder to start Codex in Terminal. Sign in with this account the first time."),
                                action: copy("Open in Terminal…"), id: "openai.codex", tapped: openCodex) {
                            if !lastProject.isEmpty {
                                Button(copy("Use same folder")) {
                                    launchCodex(at: URL(fileURLWithPath: lastProject, isDirectory: true))
                                }
                                .buttonStyle(.link).identified("openai.same-folder")
                                .disabled(index?.selected == nil || opening)
                                .help(lastProject)
                            }
                            if OpenAIProfileLauncher.codexURL() == nil {
                                Link(copy("Get Codex"), destination: OpenAIProfileLauncher.cliURL).identified("openai.install-codex")
                            }
                        }
                        Label(copy("Switch inside a ChatGPT tab using its profile menu. Chats stay with their account. In Codex, a new session can work on the same files."),
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !feedback.isEmpty {
                    Label(feedback, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy("Account name")).font(.headline)
                TextField(copy("Name"), text: $draftName)
                    .accessibilityLabel(copy("Name"))
                    .identified("openai.name").onSubmit(saveName)
                if !draftName.isEmpty && !validName {
                    Text(copy("Use a different name, up to 48 characters.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(copy("Cancel")) { editing = false }.identified("openai.cancel").keyboardShortcut(.cancelAction)
                    Button(copy("Save"), action: saveName).disabled(!validName).identified("openai.save").keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 300)
        }
        .confirmationDialog(copy("Remove this account from the list?"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { profile in
            Button(copy("Remove"), role: .destructive) { update { $0.setRemoved(true, profile.id) } }
            Button(copy("Cancel"), role: .cancel) {}
        } message: { profile in
            Text(String(format: copy("You can restore %@ with its sign-ins from Removed accounts."), profile.displayName))
        }
        .alert(copy("Couldn’t open the app"), isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(copy("OK")) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private var desktopCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(copy("Codex Desktop"), systemImage: "macwindow").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(copy("Open the desktop app to return to your work. Choose a folder only to start a new Codex chat with local files."))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { desktopButtons }
                VStack(alignment: .leading, spacing: 10) { desktopButtons }
            }
            Text(copy("To change accounts, sign out in the desktop app and sign in with your other account.")).font(.callout)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if OpenAIDesktop.installedURL() == nil {
                Link(copy("Get the desktop app"), destination: OpenAIDesktop.downloadURL).identified("openai.install-desktop")
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.26)))
    }

    @ViewBuilder private var desktopButtons: some View {
        Button(copy("Open desktop app")) {
            launch(message: copy("Opened the desktop app.")) { try await OpenAIDesktop.open() }
        }.buttonStyle(.borderedProminent).tint(accent).identified("openai.desktop").disabled(opening)
        Button(copy("New chat in folder…")) {
            guard OpenAIDesktop.installedURL() != nil else {
                errorText = OpenAILaunchError.desktopMissing.localizedDescription
                return
            }
            if let folder = chooseFolder() { openDesktopProject(folder) }
        }.identified("openai.desktop-project").disabled(opening)
        if !lastDesktopProject.isEmpty {
            Button(copy("New chat in last folder")) { openDesktopProject(URL(fileURLWithPath: lastDesktopProject, isDirectory: true)) }
                .buttonStyle(.link).identified("openai.desktop-reopen").help(lastDesktopProject).disabled(opening)
        }
    }

    private func openDesktopProject(_ folder: URL) {
        launch(message: copy("Opened a new Codex chat for your folder.")) {
            try await OpenAIDesktop.open(project: folder)
            lastDesktopProject = folder.path
        }
    }

    private var validName: Bool { index?.canUse(draftName, for: editingID) == true }

    private func accountList(_ index: OpenAIProfileIndex) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(copy("Choose an account")).font(.headline)
                Spacer()
                Button {
                    editingID = nil
                    draftName = index.nextName()
                    editing = true
                } label: { Label(copy("Add account"), systemImage: "plus") }
                .identified("openai.add")
                if let selected = index.selected {
                    Button(copy("Rename")) {
                        editingID = selected.id
                        draftName = selected.displayName
                        editing = true
                    }.accessibilityLabel(copy("Rename selected account")).identified("openai.rename")
                    Menu {
                        Button(copy("Remove from list…")) { pendingRemoval = selected }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(copy("Account options")).identified("openai.options")
                }
            }
            if index.available.count > 6 {
                Picker(copy("Selected account"), selection: Binding(
                    get: { index.selectedID }, set: { id in if let id { update { $0.select(id) } } })) {
                    ForEach(index.available) { profile in
                        Text(verbatim: profile.displayName).tag(Optional(profile.id))
                    }
                }.identified("openai.picker")
            } else if !index.available.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132))], spacing: 6) {
                    ForEach(index.available) { profile in accountButton(profile, selected: index.selectedID == profile.id) }
                }
            }
            Text(copy(index.available.isEmpty ? "Add an account to open ChatGPT or Codex."
                      : "Use the same email when you sign in to ChatGPT and Codex for this name."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !index.removed.isEmpty {
                Menu(copy("Removed accounts")) {
                    ForEach(index.removed) { profile in
                        Button(String(format: copy("Restore %@"), profile.displayName)) { update { $0.setRemoved(false, profile.id) } }
                    }
                }.fixedSize().identified("openai.restore")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.secondary.opacity(0.065)))
    }

    private func accountButton(_ profile: OpenAIProfileIndex.Profile, selected: Bool) -> some View {
        Button {
            update { $0.select(profile.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                Text(verbatim: profile.displayName).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? accent.opacity(0.14) : Color.secondary.opacity(0.065)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? accent : Color.secondary.opacity(0.28)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .identified("openai.slot." + profile.id.rawValue)
    }

    private func update(_ edit: (inout OpenAIProfileIndex) -> Void) {
        guard var current = index else { return }
        edit(&current)
        do { storedIndex = try JSONEncoder().encode(current); feedback = "" }
        catch { errorText = error.localizedDescription }
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
            .disabled(opening || index?.selected == nil).identified(id)
    }

    private func saveName() {
        guard validName else { return }
        if let editingID { update { $0.rename(editingID, to: draftName) } }
        else { update { $0.add(draftName) } }
        editing = false
    }

    private func openChat() {
        guard let profile = index?.selected else { return }
        launch(message: String(format: copy("Opened ChatGPT for %@."), profile.displayName)) {
            try await launcher.openChat(profile.id)
        }
    }

    private func openCodex() {
        guard OpenAIProfileLauncher.codexURL() != nil else {
            errorText = OpenAILaunchError.codexMissing.localizedDescription
            return
        }
        if let project = chooseFolder() { launchCodex(at: project) }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = copy("Choose the project you want to work on.")
        panel.prompt = copy("Choose folder")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func launchCodex(at project: URL) {
        guard let profile = index?.selected else { return }
        let values = try? project.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            errorText = OpenAILaunchError.invalidProject.localizedDescription
            return
        }
        launch(message: String(format: copy("Opened Terminal for %@."), profile.displayName)) {
            try await launcher.openCodex(profile.id, project: project)
            lastProject = project.path
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
