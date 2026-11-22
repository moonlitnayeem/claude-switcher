import AppKit
import SwiftUI

struct GeminiAccountsView: View {
    @AppStorage("gemini.profileIndex") private var storedIndex: Data?
    @AppStorage("gemini.lastProject") private var lastProject = ""
    @AppStorage("gemini.lastAgyProject") private var lastAgyProject = ""
    @AppStorage("gemini.showSeparateProfiles") private var showSeparateProfiles = true
    @State private var editing = false
    @State private var editingID: GeminiAccountSlot?
    @State private var pendingRemoval: GeminiProfileIndex.Profile?
    @State private var draftName = ""
    @State private var errorText: String?
    @State private var feedback = ""
    @State private var opening = false

    private var index: GeminiProfileIndex {
        if let storedIndex, let decoded = try? JSONDecoder().decode(GeminiProfileIndex.self, from: storedIndex) {
            return decoded
        }
        return GeminiProfileIndex()
    }

    private var launcher: GeminiProfileLauncher {
        GeminiProfileLauncher(root: Graft.graftFolder.appendingPathComponent("GeminiProfiles", isDirectory: true))
    }

    private let accent = Color(red: 0.26, green: 0.48, blue: 0.88)

    var body: some View {
        let currentIndex = index
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gemini & Antigravity").font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                    .identified("gemini.header")

                desktopCard(currentIndex)

                Button {
                    showSeparateProfiles.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: showSeparateProfiles ? "chevron.down" : "chevron.right")
                            .accessibilityHidden(true)
                        Text("Multi-account Browser & CLI profiles").font(.headline)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(L10n.text(showSeparateProfiles ? "Expanded" : "Collapsed"))
                .identified("gemini.separate-accounts")

                if showSeparateProfiles {
                    VStack(alignment: .leading, spacing: 14) {
                        accountList(currentIndex)

                        appCard(
                            L10n.text("Gemini & AI Studio in Chrome"),
                            symbol: "sparkles.rectangle.stack.fill",
                            tone: .blue,
                            detail: L10n.text("Open an isolated Chrome window for the selected Google account so multiple accounts stay signed in side by side."),
                            action: L10n.text("Open Gemini in Chrome"),
                            id: "gemini.web",
                            enabled: currentIndex.selected != nil,
                            tapped: { openBrowser(destination: GeminiDesktop.geminiWebURL, label: L10n.text("Gemini")) }
                        ) {
                            Button(L10n.text("Open AI Studio")) {
                                openBrowser(destination: GeminiDesktop.aiStudioURL, label: L10n.text("Google AI Studio"))
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(opening || currentIndex.selected == nil)
                            .identified("gemini.aistudio")

                            Button(L10n.text("Use default browser")) {
                                if NSWorkspace.shared.open(GeminiDesktop.geminiWebURL) {
                                    feedback = L10n.text("Opened Gemini in your default browser.")
                                } else {
                                    errorText = L10n.text("Your browser could not open Gemini.")
                                }
                            }
                            .buttonStyle(.link)
                            .identified("gemini.default-browser")
                        }

                        appCard(
                            L10n.text("Gemini CLI in Terminal"),
                            symbol: "terminal.fill",
                            tone: .indigo,
                            detail: L10n.text("Start Gemini CLI with its own isolated GEMINI_CLI_HOME credentials for the selected Google account."),
                            action: L10n.text("Open Gemini CLI…"),
                            id: "gemini.cli",
                            enabled: currentIndex.selected != nil,
                            tapped: openGeminiCLI
                        ) {
                            if !lastProject.isEmpty {
                                Button(L10n.text("Use same folder")) {
                                    launchGeminiCLI(at: URL(fileURLWithPath: lastProject, isDirectory: true))
                                }
                                .buttonStyle(.link)
                                .identified("gemini.cli-same-folder")
                                .disabled(currentIndex.selected == nil || opening)
                                .help(lastProject)
                            }
                            if GeminiDesktop.geminiCLIURL() == nil {
                                Link(L10n.text("Install Gemini CLI"), destination: GeminiDesktop.geminiCLIDocsURL)
                                    .identified("gemini.install-cli")
                            }
                        }
                    }
                }

                if !feedback.isEmpty {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Google account label").font(.headline)
                TextField("Label (e.g. personal or work)", text: $draftName)
                    .accessibilityLabel(L10n.text("Google account label"))
                    .identified("gemini.name")
                    .onSubmit(saveName)
                if !draftName.isEmpty && !validName {
                    Text("Use a unique name up to 48 characters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                        .identified("gemini.cancel").keyboardShortcut(.cancelAction)
                    Button("Save", action: saveName)
                        .disabled(!validName).identified("gemini.save").keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 320)
        }
        .confirmationDialog(
            L10n.text("Remove this Google account from the list?"),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { profile in
            Button("Remove", role: .destructive) { update { $0.setRemoved(true, profile.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text(L10n.format("You can restore %@ with its saved sign-ins from Removed accounts.", profile.displayName))
        }
        .alert(
            L10n.text("Couldn’t open Gemini or Antigravity"),
            isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
        ) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func desktopCard(_ currentIndex: GeminiProfileIndex) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Antigravity & Gemini Desktop", systemImage: "sparkles")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Open Google Antigravity / Gemini on your Mac, or start an Antigravity CLI (agy) session in a project folder.")
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { desktopButtons(currentIndex) }
                VStack(alignment: .leading, spacing: 10) { desktopButtons(currentIndex) }
            }
            Text("In Antigravity, manage connected accounts under Plugins Manager or name a profile below to pass AGY_ACCOUNT in Terminal.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if GeminiDesktop.installedURL() == nil {
                Link(L10n.text("Download Antigravity"), destination: GeminiDesktop.downloadURL)
                    .identified("gemini.install-desktop")
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.26)))
    }

    @ViewBuilder
    private func desktopButtons(_ currentIndex: GeminiProfileIndex) -> some View {
        Button(L10n.text("Open Antigravity / Gemini")) {
            launch(message: L10n.text("Opened Antigravity / Gemini.")) {
                try await GeminiDesktop.openDesktop()
            }
        }
        .buttonStyle(.borderedProminent).tint(accent)
        .identified("gemini.desktop").disabled(opening)

        Button(L10n.text("Open agy CLI in folder…")) {
            guard GeminiDesktop.agyURL() != nil else {
                errorText = GeminiLaunchError.agyMissing.localizedDescription
                return
            }
            if let folder = chooseFolder() {
                openAntigravityCLI(folder, selected: currentIndex.selected)
            }
        }
        .identified("gemini.agy-folder").disabled(opening)

        if !lastAgyProject.isEmpty {
            Button(L10n.text("Open agy in last folder")) {
                openAntigravityCLI(URL(fileURLWithPath: lastAgyProject, isDirectory: true),
                                   selected: currentIndex.selected)
            }
            .buttonStyle(.link)
            .identified("gemini.agy-reopen")
            .help(lastAgyProject)
            .disabled(opening)
        }
    }

    private var validName: Bool { index.canUse(draftName, for: editingID) }

    private func accountList(_ currentIndex: GeminiProfileIndex) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a Google account").font(.headline)
                Spacer()
                Button {
                    editingID = nil
                    draftName = currentIndex.nextName()
                    editing = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .identified("gemini.add")
                if let selected = currentIndex.selected {
                    Button("Rename") {
                        editingID = selected.id
                        draftName = selected.displayName
                        editing = true
                    }
                    .accessibilityLabel(L10n.text("Rename selected Google account"))
                    .identified("gemini.rename")
                    Menu {
                        Button("Remove from list…") { pendingRemoval = selected }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(L10n.text("Google account options"))
                    .identified("gemini.options")
                }
            }
            if currentIndex.available.count > 6 {
                Picker("Selected account", selection: Binding(
                    get: { currentIndex.selectedID },
                    set: { id in if let id { update { $0.select(id) } } }
                )) {
                    ForEach(currentIndex.available) { profile in
                        Text(verbatim: profile.displayName).tag(Optional(profile.id))
                    }
                }
                .identified("gemini.picker")
            } else if !currentIndex.available.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 6) {
                    ForEach(currentIndex.available) { profile in
                        accountButton(profile, selected: currentIndex.selectedID == profile.id)
                    }
                }
            }
            Text(currentIndex.available.isEmpty
                 ? L10n.text("Add an account to launch isolated Gemini browser or CLI sessions.")
                 : L10n.text("Each slot keeps its own Chrome profile and Gemini CLI login on this Mac."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !currentIndex.removed.isEmpty {
                Menu("Removed accounts") {
                    ForEach(currentIndex.removed) { profile in
                        Button(L10n.format("Restore %@", profile.displayName)) {
                            update { $0.setRemoved(false, profile.id) }
                        }
                    }
                }
                .fixedSize().identified("gemini.restore")
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color.secondary.opacity(0.065)))
    }

    private func accountButton(_ profile: GeminiProfileIndex.Profile, selected: Bool) -> some View {
        Button {
            update { $0.select(profile.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                Text(verbatim: profile.displayName).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? accent.opacity(0.14) : Color.secondary.opacity(0.065)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? accent : Color.secondary.opacity(0.28)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .identified("gemini.slot." + profile.id.rawValue)
    }

    private func appCard<Extra: View>(_ title: String, symbol: String, tone: Color, detail: String,
                                      action: String, id: String, enabled: Bool,
                                      tapped: @escaping () -> Void,
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
                    HStack(spacing: 12) {
                        Button(action, action: tapped)
                            .buttonStyle(.borderedProminent).tint(accent)
                            .disabled(opening || !enabled).identified(id)
                        extra()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action, action: tapped)
                            .buttonStyle(.borderedProminent).tint(accent)
                            .disabled(opening || !enabled).identified(id)
                        extra()
                    }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
    }

    private func update(_ edit: (inout GeminiProfileIndex) -> Void) {
        var current = index
        edit(&current)
        do {
            storedIndex = try JSONEncoder().encode(current)
            feedback = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveName() {
        guard validName else { return }
        if let editingID { update { $0.rename(editingID, to: draftName) } }
        else { update { $0.add(draftName) } }
        editing = false
    }

    private func openBrowser(destination: URL, label: String) {
        guard let selected = index.selected else { return }
        launch(message: L10n.format("Opened %@ for %@.", label, selected.displayName)) {
            try await launcher.openBrowser(selected.id, destination: destination)
        }
    }

    private func openGeminiCLI() {
        guard GeminiDesktop.geminiCLIURL() != nil else {
            errorText = GeminiLaunchError.geminiCLIMissing.localizedDescription
            return
        }
        if let folder = chooseFolder() { launchGeminiCLI(at: folder) }
    }

    private func launchGeminiCLI(at project: URL) {
        guard let selected = index.selected else { return }
        launch(message: L10n.format("Opened Gemini CLI for %@.", selected.displayName)) {
            try await launcher.openGeminiCLI(selected.id, project: project)
            lastProject = project.path
        }
    }

    private func openAntigravityCLI(_ project: URL, selected: GeminiProfileIndex.Profile?) {
        let slot = selected?.id ?? .first
        let customLabel = selected?.label
        let targetName = selected?.displayName ?? L10n.text("Antigravity")
        launch(message: L10n.format("Opened Antigravity CLI for %@.", targetName)) {
            try await launcher.openAntigravityCLI(slot, accountLabel: customLabel, project: project)
            lastAgyProject = project.path
        }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("Choose the project folder you want to work on.")
        panel.prompt = L10n.text("Choose folder")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func launch(message: String, _ action: @escaping @MainActor () async throws -> Void) {
        opening = true
        feedback = ""
        Task { @MainActor in
            defer { opening = false }
            do {
                try await action()
                feedback = message
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
