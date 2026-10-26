import SwiftUI
import AppKit
import Core

// The Steam sign-in wizard (SPEC3.md 4.6 and 6.4): cards for Install tools -> (Rosetta) -> Sign in (username,
// password, Steam Guard) -> Wallpaper Engine check -> done, plus Sign out and the optional shared files. Only the
// card of the current step is open; finished steps shrink to one line with a check mark. It reads `SteamSetupModel`
// (owner STEAM) and calls its methods. The typed password and Steam Guard code live in @State of the two small
// forms below, are handed to the model and cleared in the same call, and are cleared again when the form goes away.
// Nothing here logs, stores or displays them.

private let terminalApp = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

@MainActor
private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(text, forType: .string)
}

private func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// "<prefix><name in bold><suffix>" without Markdown (user names may contain underscores).
private func boldName(_ prefix: String, _ name: String, _ suffix: String) -> AttributedString {
    var result = AttributedString(prefix)
    var bold = AttributedString(name)
    bold.inlinePresentationIntent = .stronglyEmphasized
    result.append(bold)
    result.append(AttributedString(suffix))
    return result
}

private extension View {
    func wizardCard() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    }
            }
    }
}

// MARK: - Wizard

@MainActor
struct SteamWizardView: View {
    @ObservedObject var setup: SteamSetupModel
    @State private var checkOwnershipAfterSignIn = false   // set by a sign-in started here; the check follows it
    @State private var continuedAnyway = false

    init(setup: SteamSetupModel) {
        self._setup = ObservedObject(wrappedValue: setup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolsCard
            accountCard
            ownershipCard
            if showsSharedFiles { SharedFilesCard(setup: setup).padding(.top, 14) }
            Text("Not affiliated with Valve or Wallpaper Engine. Downloads use Valve’s own SteamCMD with your own account, for your personal use on this Mac. Workshop items belong to their creators; don’t redistribute them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if !isBusy { setup.refresh() } }
        .onChange(of: setup.account) { _, account in accountChanged(account) }
    }

    // MARK: Steps

    private var phases: (tools: WizardPhase, account: WizardPhase, ownership: WizardPhase) {
        switch setup.step {
        case .installTools, .fixRosetta: return (.current, .waiting, .waiting)
        case .signIn: return (.done, .current, .waiting)
        case .checkOwnership, .done: return (.done, .done, .current)
        }
    }

    private var signedInName: String {
        if case .signedIn(let name) = setup.account { return name }
        return setup.username
    }

    private var isBusy: Bool {
        if case .installing = setup.tools { return true }
        switch setup.account {
        case .signingIn, .checking: return true
        case .unknown, .signedOut, .signedIn: return false
        }
    }

    private var showsSharedFiles: Bool {
        if case .ready = setup.tools, case .signedIn = setup.account { return true }
        return false
    }

    private func accountChanged(_ account: SteamAccountState) {
        switch account {
        case .signedIn:
            if checkOwnershipAfterSignIn {
                checkOwnershipAfterSignIn = false
                setup.checkOwnership()
            }
        case .signedOut:
            checkOwnershipAfterSignIn = false
            continuedAnyway = false
        case .unknown, .checking, .signingIn:
            break
        }
    }

    // MARK: Cards

    private var toolsCard: some View {
        WizardCard(index: 1, isLast: false, phase: phases.tools, title: toolsTitle) {
            ToolsContent(setup: setup)
        }
    }

    private var accountCard: some View {
        WizardCard(index: 2, isLast: false, phase: phases.account, title: accountTitle) {
            AccountContent(setup: setup, onSignIn: { checkOwnershipAfterSignIn = true })
        }
    }

    private var ownershipCard: some View {
        WizardCard(index: 3, isLast: true, phase: phases.ownership, title: ownershipTitle) {
            OwnershipContent(setup: setup, name: signedInName, continued: continuedAnyway,
                             continueAnyway: { continuedAnyway = true },
                             recheck: {
                                 continuedAnyway = false
                                 setup.checkOwnership()
                             })
        }
    }

    private var toolsTitle: String {
        switch setup.tools {
        case .unknown: return "Checking…"
        case .missing: return "Install Steam’s download tool"
        case .installing(let step):
            switch step {
            case .downloading: return "Downloading…"
            case .extracting: return "Unpacking…"
            case .firstRun: return "Setting up Steam’s tool"
            case .checking: return "Checking…"
            }
        case .rosettaRequired: return "Rosetta is needed"
        case .failed(let error): return error.title
        case .ready(let info): return info.arch == .unknown ? "Steam tools installed" : "Steam tools installed · \(info.arch.rawValue)"
        }
    }

    private var accountTitle: String {
        guard phases.account == .current else {
            if case .signedIn(let name) = setup.account { return "Signed in as \(name)" }
            return "Sign in to Steam"
        }
        switch setup.account {
        case .unknown, .checking: return "Checking…"
        case .signedOut: return "Sign in to Steam"
        case .signedIn(let name): return "Signed in as \(name)"
        case .signingIn(let step):
            switch step {
            case .starting, .working: return "Signing in…"
            case .needsCode: return "Steam Guard code"
            case .needsMobileApproval: return "Approve on your phone"
            case .unrecognizedPrompt: return "Steam is waiting for something unexpected"
            }
        }
    }

    private var ownershipTitle: String {
        if continuedAnyway { return "Ready to download" }
        guard phases.ownership == .current else { return "Check Wallpaper Engine" }
        switch setup.ownership {
        case .unknown: return "Check Wallpaper Engine"
        case .checking: return "Checking Wallpaper Engine…"
        case .owned: return "You’re all set"
        case .notOwned: return "Wallpaper Engine isn’t on this account"
        case .couldNotCheck: return "Couldn’t confirm Wallpaper Engine"
        }
    }
}

// MARK: - Card frame

private enum WizardPhase: Equatable {
    case done, current, waiting
}

/// One step on the setup rail. Only the current step is open; completed steps collapse to a summary row.
@MainActor
private struct WizardCard<Content: View>: View {
    let index: Int
    let isLast: Bool
    let phase: WizardPhase
    let title: String
    let content: Content

    init(index: Int, isLast: Bool, phase: WizardPhase, title: String, @ViewBuilder content: () -> Content) {
        self.index = index
        self.isLast = isLast
        self.phase = phase
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            rail
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                    if phase == .done {
                        Text("Done").font(.caption).foregroundStyle(.green)
                    } else if phase == .waiting {
                        Text("Next").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if phase == .current {
                    content
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                            .strokeBorder(phase == .current ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.07),
                                          lineWidth: phase == .current ? 1.5 : 1)
                    }
            }
        }
        .opacity(phase == .waiting ? 0.58 : 1)
        .animation(LWMotion.panel, value: phase)
        .accessibilityElement(children: .contain)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(nodeBackground)
                    .frame(width: 24, height: 24)
                if phase == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(phase == .current ? Color.white : Color.secondary)
                }
            }
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .frame(width: 24)
    }

    private var nodeBackground: Color {
        switch phase {
        case .done: return .green
        case .current: return .accentColor
        case .waiting: return Color.primary.opacity(0.08)
        }
    }
}

@MainActor
private struct BusyLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// An error in the words of `SteamSetupError`: bold orange title, secondary message.
@MainActor
private struct ErrorLines: View {
    let error: SteamSetupError

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(error.title).font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            if !error.message.isEmpty {
                Text(error.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Step 1: tools

@MainActor
private struct ToolsContent: View {
    @ObservedObject var setup: SteamSetupModel

    var body: some View {
        switch setup.tools {
        case .unknown:
            BusyLine(text: "Checking…")
        case .missing:
            VStack(alignment: .leading, spacing: 10) {
                Text("PaperFlow downloads Steam’s official command-line tool (SteamCMD, about 3 MB) from Valve. It is used only to download wallpapers you ask for, with your own Steam account.")
                    .foregroundStyle(.secondary)
                Button("Install Steam tools") { setup.installTools() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        case .installing(let step):
            InstallProgress(step: step, cancel: { setup.cancelInstall() })
        case .rosettaRequired:
            RosettaContent(setup: setup)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                ErrorLines(error: error)
                Button("Try again") { setup.installTools() }
            }
        case .ready:
            EmptyView()
        }
    }
}

@MainActor
private struct InstallProgress: View {
    let step: SteamInstallStep
    let cancel: () -> Void

    var body: some View {
        switch step {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))% of about 3 MB").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Button("Cancel", action: cancel)
            }
        case .extracting:
            BusyLine(text: "Unpacking…")
        case .firstRun(let note):
            VStack(alignment: .leading, spacing: 6) {
                Text("Steam’s tool updates itself the first time it runs. This can take a few minutes.")
                    .foregroundStyle(.secondary)
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                BusyLine(text: "Working…")
                Button("Cancel", action: cancel)
            }
        case .checking:
            BusyLine(text: "Checking…")
        }
    }
}

/// Shown only when the tools state says this Mac needs Rosetta for Steam’s Intel-only tool. One button: macOS asks
/// for an administrator password and the app does the rest. Apple's license is shown before anything is installed.
@MainActor
private struct RosettaContent: View {
    @ObservedObject var setup: SteamSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steam’s tool is built for Intel Macs. Rosetta is Apple’s free translator that lets this Mac run it. It installs once.")
                .foregroundStyle(.secondary)
            Text("Installing it means accepting Apple’s Rosetta software license.")
                .font(.callout).foregroundStyle(.secondary)
            Link("Read Apple’s license", destination: URL(string: "https://www.apple.com/legal/sla/")!).font(.callout)
            HStack {
                Button("Install Rosetta", action: setup.installRosetta)
                    .buttonStyle(.borderedProminent)
                    .disabled(setup.rosettaInstalling)
                if setup.rosettaInstalling {
                    ProgressView().controlSize(.small)
                    Text("Installing… this can take a few minutes. Your Mac may ask for your password.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = setup.lastError {
                Text(error.message).font(.callout).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Step 2: sign in

@MainActor
private struct AccountContent: View {
    @ObservedObject var setup: SteamSetupModel
    let onSignIn: () -> Void

    var body: some View {
        switch setup.account {
        case .unknown, .checking:
            BusyLine(text: "Checking…")
        case .signedOut:
            SignInForm(setup: setup, onSignIn: onSignIn)
        case .signingIn(let step):
            SigningInContent(setup: setup, step: step)
        case .signedIn:
            EmptyView()
        }
    }
}

/// Username, password and the Sign in button. The password never leaves this view except in `setup.signIn`.
@MainActor
private struct SignInForm: View {
    @ObservedObject var setup: SteamSetupModel
    let onSignIn: () -> Void
    @State private var password = ""

    private var name: String { setup.username.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = setup.lastError, error != .cancelled { ErrorLines(error: error) }
            Text("Use the Steam account that owns Wallpaper Engine. Your password goes straight to Valve’s tool. PaperFlow never stores it.")
                .foregroundStyle(.secondary)
            TextField("Username", text: $setup.username)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320).disableAutocorrection(true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 320).onSubmit(submit)
            Button("Sign in", action: submit)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || password.isEmpty)
            Text("Your password goes straight to Valve’s tool and is never stored.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { password = "" }
    }

    private func submit() {
        guard !name.isEmpty, !password.isEmpty else { return }
        let typed = password
        password = ""
        onSignIn()
        setup.signIn(username: name, password: typed)
    }
}

@MainActor
private struct SigningInContent: View {
    @ObservedObject var setup: SteamSetupModel
    let step: SteamSignInStep

    var body: some View {
        switch step {
        case .starting:
            working("Signing in…")
        case .working(let text):
            working(text)
        case .needsCode(let kind, let wasWrong):
            GuardCodeForm(setup: setup, kind: kind, previousWasWrong: wasWrong)
        case .needsMobileApproval:
            VStack(alignment: .leading, spacing: 8) {
                Text("Open the Steam Mobile app and approve the sign-in. This window continues by itself.")
                    .foregroundStyle(.secondary)
                Button("Cancel") { setup.cancelSignIn() }
            }
        case .unrecognizedPrompt(let lastLines):
            UnrecognizedPromptContent(setup: setup, lastLines: lastLines)
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 12) {
            BusyLine(text: text)
            Button("Cancel") { setup.cancelSignIn() }
        }
    }
}

/// The Steam Guard code field. The code is cleared as it is handed to the model.
@MainActor
private struct GuardCodeForm: View {
    @ObservedObject var setup: SteamSetupModel
    let kind: SteamCodeKind
    let previousWasWrong: Bool
    @State private var code = ""

    private var prompt: String {
        if previousWasWrong { return "That code didn’t work. Enter the newest one." }
        switch kind {
        case .email: return "Steam sent a code to your email. Enter it here."
        case .authenticator: return "Open the Steam Mobile app and enter the current code."
        case .unknown: return "Steam wants a Steam Guard code. Enter the newest one you have."
        }
    }

    private var trimmed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt).foregroundStyle(previousWasWrong ? Color.orange : Color.secondary)
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .frame(maxWidth: 160).disableAutocorrection(true).onSubmit(submit)
            HStack {
                Button("Continue", action: submit)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
                Button("Cancel") { setup.cancelSignIn() }
            }
        }
        .onDisappear { code = "" }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        let typed = trimmed
        code = ""
        setup.submitGuardCode(typed)
    }
}

/// Fallback when Steam says something the app does not recognise: show it and offer Terminal.
@MainActor
private struct UnrecognizedPromptContent: View {
    @ObservedObject var setup: SteamSetupModel
    let lastLines: String

    private var terminalCommand: String {
        let tool = setup.steamcmdPath ?? "steamcmd"
        let name = setup.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return "HOME=\(shellQuoted(AppPaths.steamHomeDirectory.path)) \(shellQuoted(tool)) +login \(name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PaperFlow doesn’t recognise Steam’s last message. You can sign in using Terminal instead.")
                .foregroundStyle(.secondary)
            Text(lastLines)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
            HStack {
                Button("Copy details") { copyText(lastLines) }
                Button("Copy Terminal command") { copyText(terminalCommand) }
                Button("Open Terminal") { NSWorkspace.shared.open(terminalApp) }
                Button("Cancel") { setup.cancelSignIn() }
            }
        }
    }
}

// MARK: - Step 3: Wallpaper Engine

@MainActor
private struct OwnershipContent: View {
    @ObservedObject var setup: SteamSetupModel
    let name: String
    let continued: Bool
    let continueAnyway: () -> Void
    let recheck: () -> Void

    var body: some View {
        if continued {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wallpaper Engine wasn’t confirmed, but downloads can still work.").foregroundStyle(.secondary)
                accountButtons
            }
        } else {
            result
        }
    }

    @ViewBuilder private var result: some View {
        switch setup.ownership {
        case .unknown:
            VStack(alignment: .leading, spacing: 8) {
                Text("Make sure this account owns Wallpaper Engine.").foregroundStyle(.secondary)
                Button("Check Wallpaper Engine", action: recheck).buttonStyle(.borderedProminent)
            }
        case .checking:
            BusyLine(text: "Checking Wallpaper Engine…")
        case .owned:
            VStack(alignment: .leading, spacing: 8) {
                Text(boldName("Signed in as ", name, ". Wallpaper Engine found.")).foregroundStyle(.secondary)
                accountButtons
            }
        case .notOwned:
            VStack(alignment: .leading, spacing: 8) {
                Text(boldName("Steam doesn’t show Wallpaper Engine for ", name,
                              ". Downloads need an account that owns it. If you use Steam Family Sharing, you can still try a download."))
                    .foregroundStyle(.secondary)
                accountButtons
            }
        case .couldNotCheck(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Text(reason).foregroundStyle(.secondary)
                HStack {
                    Button("Continue anyway", action: continueAnyway).buttonStyle(.borderedProminent)
                    Button("Check again", action: recheck)
                }
            }
        }
    }

    private var accountButtons: some View {
        HStack {
            Button("Sign out") { setup.signOut() }
            Button("Check again", action: recheck)
        }
    }
}

// MARK: - Optional shared files

/// Wallpaper Engine's shared scene files: optional, large, only on request.
@MainActor
private struct SharedFilesCard: View {
    @ObservedObject var setup: SteamSetupModel
    @State private var declined = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wallpaper Engine’s shared files (optional)").font(.headline)
            Text("Some scenes need files that come with Wallpaper Engine. Without them those scenes show their preview only.")
                .font(.callout).foregroundStyle(.secondary)
            content
        }
        .wizardCard()
    }

    @ViewBuilder private var content: some View {
        switch setup.assets {
        case .unknown, .notFetched:
            Button("Get shared files") { start() }
        case .discovering:
            BusyLine(text: "Looking for the files…")
        case .needsConfirmation(let bytes, _):
            if declined {
                Button("Get shared files") { start() }
            } else {
                confirmation(bytes)
            }
        case .fetching(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction { ProgressView(value: min(max(fraction, 0), 1)) } else { ProgressView() }
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            HStack {
                Label("Shared files installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Remove") { setup.removeSharedAssets() }
            }
        case .unavailable(let message):
            Text(message).font(.callout).foregroundStyle(.orange)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                ErrorLines(error: error)
                Button("Try again") { start() }
            }
        }
    }

    private func confirmation(_ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(boldName("Steam will download about ", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                          " of Wallpaper Engine files to your Mac, keep the shared scene files and delete the rest. Continue?"))
            HStack {
                Button("Continue") { setup.confirmSharedAssets() }.buttonStyle(.borderedProminent)
                Button("Not now") { declined = true }
            }
        }
    }

    private func start() {
        declined = false
        setup.prepareSharedAssets()
    }
}
