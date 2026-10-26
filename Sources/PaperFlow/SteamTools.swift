import Foundation
import Combine
import Core

// Owner: STEAM. The Steam sign-in wizard backend (SPEC3.md section 4): installs Valve's SteamCMD itself, signs the
// user in through a pseudo-terminal (SteamPTY.swift), checks that the account owns Wallpaper Engine, signs out, and
// fetches the shared assets. The views (SteamWizardView.swift, owner SETTINGS) consume `SteamSetupModel` only.
//
// Rules (non-negotiable, SPEC3.md 0 and 4.1):
//  - SteamCMD is downloaded from Valve at the user's request, never bundled or re-hosted.
//  - The password and Steam Guard code travel only through the pty to steamcmd. They are never in argv, in the
//    environment, in a file, in UserDefaults, in the log, or in any @Published property. Captured output is
//    scrubbed of ANSI codes and of every occurrence of the secret before anything else sees it.
//  - Only the user's own account, only Valve's SteamCMD. No anonymous login, no third-party downloaders.
// Everything above `SteamSetupModel` is pure (no AppKit/SwiftUI, no process) so the Linux harness tests it.

enum SteamArch: String, Equatable {
    case arm64, x86_64, universal, unknown
}

struct SteamToolsInfo: Equatable {
    var path: String                 // absolute path of steamcmd.sh (the launcher) to run
    var arch: SteamArch              // of the real binary, from `lipo -archs`
    var managedByApp: Bool           // installed by this app into AppPaths.steamToolsDirectory
}

enum SteamInstallStep: Equatable {
    case downloading(fraction: Double?)   // nil = size unknown
    case extracting
    case firstRun(note: String)           // SteamCMD updates itself on its first start; can take minutes
    case checking                         // lipo + Rosetta test
}

enum SteamToolsState: Equatable {
    case unknown
    case missing                          // nothing usable found
    case installing(SteamInstallStep)
    case rosettaRequired                  // x86_64-only binary, Apple silicon Mac, Rosetta not installed
    case ready(SteamToolsInfo)
    case failed(SteamSetupError)
}

enum SteamCodeKind: Equatable {
    case email                            // "a code was sent to your email"
    case authenticator                    // Steam Mobile app code
    case unknown                          // a Steam Guard prompt we could not classify: ask for "the code"
}

enum SteamSignInStep: Equatable {
    case starting                         // steamcmd launched, waiting for the first prompt
    case working(String)                  // after the password / code was sent: "Signing in…"
    case needsCode(SteamCodeKind, previousWasWrong: Bool)
    case needsMobileApproval              // "approve the sign-in in the Steam Mobile app"; the app keeps waiting
    case unrecognizedPrompt(lastLines: String)   // fallback: nothing matched for 20 s; text is scrubbed
}

enum SteamAccountState: Equatable {
    case unknown
    case checking
    case signedOut                        // no cached login
    case signingIn(SteamSignInStep)
    case signedIn(username: String)       // steamcmd accepted its cached login token
}

enum SteamOwnershipState: Equatable {
    case unknown
    case checking
    case owned
    case notOwned
    case couldNotCheck(String)            // user-facing reason; downloads may still work
}

enum SteamAssetsState: Equatable {
    case unknown
    case notFetched
    case discovering                      // reading app info to find the depot
    case needsConfirmation(downloadBytes: Int64, depotName: String)   // shown before the big download
    case fetching(fraction: Double?)
    case ready(folder: String)
    case unavailable(String)              // discovery found no usable depot (UNVERIFIED territory)
    case failed(SteamSetupError)
}

/// The step the wizard shows. Derived from the four states above by `SteamSetupModel.step`.
enum SteamWizardStep: Equatable {
    case installTools, fixRosetta, signIn, checkOwnership, done
}

enum SteamSetupError: Error, Equatable {
    case downloadFailed(String)           // fetching steamcmd_osx.tar.gz
    case extractFailed(String)
    case toolsBroken(String)              // no executable / unreadable architecture after install
    case rosettaMissing
    case rosettaInstallFailed
    case firstRunFailed(String)
    case badPassword
    case badCode
    case rateLimited
    case guardTimedOut                    // no code / approval within the window
    case unrecognizedPrompt(String)
    case loginFailed(String)              // any other FAILED line from steamcmd (scrubbed)
    case processFailed(String)
    case timedOut
    case cancelled
    case diskSpace(neededBytes: Int64)
    case assetsFailed(String)

    /// Bold line.
    var title: String {
        switch self {
        case .downloadFailed: return "Couldn’t download Steam’s command-line tool"
        case .extractFailed, .toolsBroken: return "The Steam tool didn’t install correctly"
        case .rosettaMissing: return "Rosetta is needed"
        case .rosettaInstallFailed: return "Rosetta didn’t install"
        case .firstRunFailed: return "Steam’s tool couldn’t finish its first start"
        case .badPassword: return "Steam didn’t accept that password"
        case .badCode: return "That Steam Guard code didn’t work"
        case .rateLimited: return "Steam is asking you to wait"
        case .guardTimedOut: return "Steam Guard timed out"
        case .unrecognizedPrompt: return "Steam is waiting for something unexpected"
        case .loginFailed: return "Steam sign-in failed"
        case .processFailed: return "The Steam tool stopped unexpectedly"
        case .timedOut: return "Steam took too long to answer"
        case .cancelled: return "Cancelled"
        case .diskSpace: return "Not enough free disk space"
        case .assetsFailed: return "Couldn’t get Wallpaper Engine’s shared files"
        }
    }

    /// Secondary line (exact copy: SPEC3.md 4.6).
    var message: String {
        switch self {
        case .downloadFailed(let detail): return "Check your internet connection and try again. (\(detail))"
        case .extractFailed(let detail), .toolsBroken(let detail): return "Remove it in Steam Setup and install it again. (\(detail))"
        case .rosettaMissing: return "Steam’s tool is built for Intel Macs. Install Rosetta, then try again."
        case .rosettaInstallFailed: return "Check your internet connection and try again. If this Mac has only standard accounts, ask an administrator to install Rosetta."
        case .firstRunFailed(let detail): return "Try again. If it keeps failing, remove the tool and reinstall. (\(detail))"
        case .badPassword: return "Check the password and try again. After several wrong tries Steam makes you wait."
        case .badCode: return "Enter the newest code. Codes from the Steam Mobile app change every 30 seconds."
        case .rateLimited: return "Too many sign-in attempts. Wait about 30 minutes before trying again."
        case .guardTimedOut: return "No code or approval arrived in time. Start again."
        case .unrecognizedPrompt: return "Steam sent a prompt this app doesn’t know. Details are below; you can also sign in using Terminal."
        case .loginFailed(let line): return line.hasSuffix(".") ? line : "Steam said: \(line)"   // our own sentences end with a period
        case .processFailed(let detail): return "Try again. (\(detail))"
        case .timedOut: return "Check your connection and try again."
        case .cancelled: return ""
        case .diskSpace(let bytes): return "About \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of free space is needed."
        case .assetsFailed(let detail): return detail
        }
    }
}


// MARK: - Prompt classifier

/// What the text coming out of steamcmd's pty means. Pure and tolerant (SPEC3.md 4.4): lower-cased substring and
/// small regex matching on the last ~2 KB of the output, first match in the order of the table wins.
enum SteamPrompt: Equatable {
    case none
    case passwordPrompt
    case guardCode(SteamCodeKind)
    case mobileApproval
    case badPassword
    case badCode
    case rateLimited
    case signedIn
    case failed(String)          // other "FAILED" / "ERROR!" line, scrubbed
    case rosettaMissing          // "Bad CPU type"
}

enum SteamPromptClassifier {
    /// `tail` is the most recent output; ANSI sequences and carriage-return redraws are resolved here.
    static func classify(_ tail: String) -> SteamPrompt {
        let lines = cleanLines(tail)
        let text = lines.joined(separator: "\n")
        let lower = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }
        if has("bad cpu type") { return .rosettaMissing }
        if has("rate limit exceeded", "too many login failures", "too many retries")
            || (has("account logon denied") && has("rate")) { return .rateLimited }
        if has("invalid password") { return .badPassword }
        if has("two-factor code mismatch", "invalid login auth code") || (has("incorrect") && has("code"))
            || ((has("code") || has("steam guard")) && has("wrong", "invalid", "mismatch", "expired")) { return .badCode }
        if has("logged in ok", "waiting for user info...ok") { return .signedIn }
        if has("confirm the login in the steam mobile app", "waiting for confirmation", "check your phone")
            || (has("approve") && has("sign in", "login", "log in")
                && lower.range(of: "\\bapp\\b", options: .regularExpression) != nil) { return .mobileApproval }
        let last = (lines.last { !$0.isEmpty } ?? "")
        let lastLower = last.lowercased()
        if ["steam guard code", "two-factor code", "enter the code", "enter your code"].contains(where: lastLower.contains) {
            return .guardCode(codeKind(lower))
        }
        if lastLower.range(of: "password\\s*:$", options: .regularExpression) != nil { return .passwordPrompt }
        for line in lines.reversed() {
            if let reason = capture("(?i)failed.*\\((.+)\\)", in: line) ?? capture("(?i)login failure: (.+)", in: line) {
                return .failed(reason.trimmingCharacters(in: .whitespaces))
            }
            if line.lowercased().hasPrefix("error!") {
                return .failed(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            }
        }
        return .none
    }

    /// ANSI removed, "\r\n" is a newline, a carriage return redraws its line, trailing spaces trimmed, last 2000
    /// characters only.
    static func cleanLines(_ text: String) -> [String] {
        let plain = SteamScrubber.stripANSI(text).replacingOccurrences(of: "\r\n", with: "\n")
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let visible = line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return visible.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var kept: [String] = []
        var budget = 2000
        for line in lines.reversed() {
            budget -= line.count + 1
            kept.append(line)
            if budget <= 0 { break }
        }
        return kept.reversed()
    }

    private static func codeKind(_ lowerTail: String) -> SteamCodeKind {
        func has(_ needles: String...) -> Bool { needles.contains { lowerTail.contains($0) } }
        if has("email", "e-mail", "sent to") { return .email }
        if has("mobile", "authenticator", "two-factor") || lowerTail.range(of: "\\bapp\\b", options: .regularExpression) != nil {
            return .authenticator
        }
        return .unknown
    }

    private static func capture(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}

// MARK: - The sign-in conversation (pure; the model feeds it scrubbed output and executes its reactions)

struct SteamSignInMachine {
    enum Reaction: Equatable {
        case sendPassword, sendCode, terminate, rosetta, signedIn
        case show(SteamSignInStep)
        case fail(SteamSetupError)
    }

    static let maxCodes = 3
    static let stallSeconds: TimeInterval = 20
    static let codeSeconds: TimeInterval = 300
    static let approvalSeconds: TimeInterval = 120

    private enum Phase { case starting, working, awaitingCode, approval, signedIn, ended }
    private var phase = Phase.starting
    private var window = ""                    // output since the last action
    private var transcript = ""                // last output, for messages
    private var kind = SteamCodeKind.unknown
    private var passwordSent = false
    private var codesSent = 0
    private var shown = SteamSignInStep.starting
    private var lastOutput: Date
    private var waitingSince: Date

    init(now: Date) {
        lastOutput = now
        waitingSince = now
    }

    var isFinished: Bool { phase == .signedIn || phase == .ended }

    /// The last meaningful lines, for the "unrecognized prompt" card.
    var lastLines: String {
        SteamPromptClassifier.cleanLines(transcript).filter { !$0.isEmpty }.suffix(6).joined(separator: "\n")
    }

    mutating func receive(_ text: String, now: Date) -> [Reaction] {
        guard !isFinished else { return [] }
        lastOutput = now
        window = String((window + text).suffix(4000))
        transcript = String((transcript + text).suffix(4000))
        return advance(now: now)
    }

    /// The user typed a code while the code prompt was showing.
    mutating func codeSubmitted(now: Date) -> [Reaction] {
        guard phase == .awaitingCode else { return [] }
        codesSent += 1
        phase = .working
        window = ""
        lastOutput = now
        return [.sendCode] + show(.working("Checking the code…"))
    }

    mutating func tick(now: Date) -> [Reaction] {
        switch phase {
        case .starting, .working:
            let quiet = now.timeIntervalSince(lastOutput)
            if quiet >= Self.codeSeconds { return end(.fail(.guardTimedOut)) }
            return quiet >= Self.stallSeconds ? show(.unrecognizedPrompt(lastLines: lastLines)) : []
        case .awaitingCode:
            return now.timeIntervalSince(waitingSince) >= Self.codeSeconds ? end(.fail(.guardTimedOut)) : []
        case .approval:
            return now.timeIntervalSince(waitingSince) >= Self.approvalSeconds ? end(.fail(.guardTimedOut)) : []
        case .signedIn, .ended:
            return []
        }
    }

    /// The process ended. Whatever it said last is the reason when nothing decisive was seen.
    mutating func exited(_ status: Int32) -> [Reaction] {
        guard !isFinished else { return [] }
        phase = .ended
        let line = SteamPromptClassifier.cleanLines(transcript).last { !$0.isEmpty } ?? ""
        return [line.isEmpty ? .fail(.processFailed("Steam’s tool stopped (exit code \(status)).")) : .fail(.loginFailed(line))]
    }

    private mutating func advance(now: Date) -> [Reaction] {
        switch SteamPromptClassifier.classify(window) {
        case .none:
            if case .unrecognizedPrompt = shown { return show(phase == .starting ? .starting : .working("Signing in…")) }
            return []
        case .rosettaMissing: return end(.rosetta)
        case .rateLimited: return end(.fail(.rateLimited))
        case .badPassword: return end(.fail(.badPassword))
        case .failed(let line): return end(.fail(.loginFailed(line)))
        case .signedIn:
            phase = .signedIn
            return [.signedIn]
        case .passwordPrompt:
            if passwordSent { return end(.fail(.badPassword)) }       // Steam asked again: the password was wrong
            passwordSent = true
            phase = .working
            window = ""
            return [.sendPassword] + show(.working("Signing in…"))
        case .guardCode(let found):
            if phase == .awaitingCode, kind == found { return [] }
            return wait(for: found, wrong: codesSent > 0, now: now)
        case .mobileApproval:
            guard phase != .approval else { return [] }
            phase = .approval
            waitingSince = now
            return show(.needsMobileApproval)
        case .badCode:
            guard codesSent < Self.maxCodes else { return end(.fail(.badCode)) }
            // Keep what follows the failure line: Steam usually asks for the next code right away.
            let lines = SteamPromptClassifier.cleanLines(window)
            let after = lines.lastIndex { SteamPromptClassifier.classify($0) == .badCode }.map { Array(lines[($0 + 1)...]) } ?? []
            window = after.joined(separator: "\n")
            let reactions = wait(for: kind, wrong: true, now: now)
            return window.isEmpty ? reactions : reactions + advance(now: now)
        }
    }

    private mutating func wait(for found: SteamCodeKind, wrong: Bool, now: Date) -> [Reaction] {
        kind = found
        phase = .awaitingCode
        waitingSince = now
        return show(.needsCode(found, previousWasWrong: wrong))
    }

    private mutating func end(_ reaction: Reaction) -> [Reaction] {
        phase = .ended
        return [reaction, .terminate]
    }

    private mutating func show(_ step: SteamSignInStep) -> [Reaction] {
        guard step != shown else { return [] }
        shown = step
        return [.show(step)]
    }
}

// MARK: - Pure helpers: architecture, archive, token, licences, VDF

enum SteamKit {
    static let installerURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    /// The environment of every steamcmd run: the app's own, minus anything that could carry a credential, plus
    /// TERM=dumb and `extra` (HOME for the isolated token).
    static func childEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            let name = key.uppercased()
            return !name.hasPrefix("STEAM_") && !name.contains("PASSWORD")
        }
        environment["TERM"] = "dumb"
        return environment.merging(extra) { _, new in new }
    }

    // MARK: Architecture

    /// `lipo -archs` ("x86_64 arm64") and `file -b` ("Mach-O 64-bit executable x86_64", fat files list every slice).
    static func parseArch(_ output: String) -> SteamArch {
        let words = output.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        let arm = words.contains { $0.hasPrefix("arm64") }
        let intel = words.contains { $0.hasPrefix("x86_64") }
        switch (arm, intel) {
        case (true, true): return .universal
        case (true, false): return .arm64
        case (false, true): return .x86_64
        default: return .unknown
        }
    }

    /// Rosetta only matters on Apple silicon, for a binary without an arm64 slice, when it is not installed.
    static func needsRosetta(arch: SteamArch, appleSilicon: Bool, rosettaInstalled: Bool) -> Bool {
        appleSilicon && arch == .x86_64 && !rosettaInstalled
    }

    /// The real binary the launcher script runs.
    static func binary(in folder: URL) -> URL? {
        [folder.appendingPathComponent("steamcmd"),
         folder.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamcmd")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Blocking (runs `lipo`/`file`, `arch`): call off the main thread.
    static func inspect(steamcmd path: String) -> SteamToolsState {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        var arch = SteamArch.unknown
        if let binary = binary(in: folder) {
            if let result = SteamProcess.capture("/usr/bin/lipo", ["-archs", binary.path]), result.status == 0 {
                arch = parseArch(result.output)
            }
            if arch == .unknown, let result = SteamProcess.capture("/usr/bin/file", ["-b", binary.path]) {
                arch = parseArch(result.output)
            }
        }
        let silicon = isAppleSilicon()
        let rosetta = silicon && arch == .x86_64 ? rosettaInstalled() : true
        if needsRosetta(arch: arch, appleSilicon: silicon, rosettaInstalled: rosetta) { return .rosettaRequired }
        let managed = URL(fileURLWithPath: path).standardizedFileURL.path
            == AppPaths.steamToolsDirectory.appendingPathComponent("steamcmd.sh").standardizedFileURL.path
        return .ready(SteamToolsInfo(path: path, arch: arch, managedByApp: managed))
    }

    /// `hw.optional.arm64` (not `#if arch(arm64)`: the app itself may run translated).
    static func isAppleSilicon() -> Bool {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #else
        return false
        #endif
    }

    /// Installs Rosetta behind macOS's own administrator prompt, so no Terminal is needed. Blocking: call off the
    /// main thread. nil on success. Error -128 is the user pressing Cancel on that prompt.
    static func installRosetta() -> SteamSetupError? {
        let script = "do shell script \"softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        guard let result = SteamProcess.capture("/usr/bin/osascript", ["-e", script]) else { return .rosettaInstallFailed }
        if result.status == 0 { return nil }
        return result.output.contains("-128") ? .cancelled : .rosettaInstallFailed
    }

    static func rosettaInstalled() -> Bool {
        guard let result = SteamProcess.capture("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) else { return false }
        return result.status == 0 && !result.output.lowercased().contains("bad cpu type")
    }

    // MARK: Installing from the tarball

    /// Absolute paths and `..` never come out of an archive.
    static func isSafeArchiveEntry(_ entry: String) -> Bool {
        !entry.isEmpty && !entry.hasPrefix("/") && !entry.split(separator: "/").contains("..")
    }

    /// True when every symbolic link below `root` points inside it.
    static func linksStayInside(_ root: URL) -> Bool {
        let base = root.standardizedFileURL.path + "/"
        guard let names = FileManager.default.enumerator(atPath: root.path) else { return true }
        for case let name as String in names {
            let link = root.appendingPathComponent(name)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { continue }
            if target.hasPrefix("/") { return false }
            let resolved = link.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
            if !(resolved + "/").hasPrefix(base) { return false }
        }
        return true
    }

    /// Lists, checks and unpacks the tarball into a fresh sibling folder, and only then moves it to `folder`, so
    /// nothing from a bad archive is ever in place (or executed). Blocking: call off the main thread.
    static func install(archive: URL, into folder: URL) throws {
        let manager = FileManager.default
        guard let listing = SteamProcess.capture("/usr/bin/tar", ["-tzf", archive.path]), listing.status == 0 else {
            throw SteamSetupError.extractFailed("the download isn’t a valid archive")
        }
        let entries = listing.output.split(separator: "\n").map(String.init)
        guard !entries.isEmpty, entries.allSatisfy(isSafeArchiveEntry) else {
            throw SteamSetupError.extractFailed("the archive contains unsafe paths")
        }
        let partial = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".partial")
        try? manager.removeItem(at: partial)
        do {
            try AppPaths.ensureDirectory(partial)
            guard let result = SteamProcess.capture("/usr/bin/tar", ["-xzf", archive.path, "-C", partial.path]),
                  result.status == 0 else { throw SteamSetupError.extractFailed("tar could not unpack it") }
            guard linksStayInside(partial) else { throw SteamSetupError.extractFailed("the archive links outside itself") }
            let launcher = partial.appendingPathComponent("steamcmd.sh")
            guard manager.fileExists(atPath: launcher.path) else { throw SteamSetupError.toolsBroken("steamcmd.sh is missing") }
            for file in [launcher, partial.appendingPathComponent("steamcmd")] where manager.fileExists(atPath: file.path) {
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            try? manager.removeItem(at: folder)
            try manager.moveItem(at: partial, to: folder)
        } catch {
            try? manager.removeItem(at: partial)
            throw error as? SteamSetupError ?? SteamSetupError.extractFailed(error.localizedDescription)
        }
    }

    /// "Downloading update (1234 of 5678 KB)..." -> 0...1 (steamcmd updating itself).
    static func updateFraction(_ line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "\\((\\d+) of (\\d+) [KMG]?B\\)"),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let done = Range(match.range(at: 1), in: line).flatMap({ Double(line[$0]) }),
              let total = Range(match.range(at: 2), in: line).flatMap({ Double(line[$0]) }), total > 0 else { return nil }
        return min(1, done / total)
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func freeBytes(at folder: URL) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemFreeSize] as? NSNumber)??.int64Value
    }

    // MARK: Token and ownership

    /// SteamCMD's cached login (`config/config.vdf`) below a Steam data folder.
    static func tokenFile(dataFolder: URL) -> URL {
        dataFolder.appendingPathComponent("Library/Application Support/Steam/config/config.vdf")
    }

    static func tokenMentions(_ username: String, in file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return String(decoding: data, as: UTF8.self).lowercased().contains(username.lowercased())
    }

    /// `+licenses_print` output: any mention of app 431960 -> owned; licences listed without it -> not owned.
    static func ownership(fromLicenses lines: [String]) -> SteamOwnershipState {
        if lines.contains(where: { $0.range(of: "\\b431960\\b", options: .regularExpression) != nil }) { return .owned }
        if lines.contains(where: { $0.contains("License packageID") }) { return .notOwned }
        return .couldNotCheck("Steam didn’t list your games. You can still try a download.")
    }

    // MARK: Shared assets: Valve's key-value text (VDF)

    struct VDFNode {
        var value: String?
        var children: [(key: String, node: VDFNode)] = []

        func child(_ key: String) -> VDFNode? {
            children.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.node
        }
    }

    private enum VDFToken { case text(String), open, close }

    private static func vdfTokens(_ text: Substring) -> [VDFToken] {
        var tokens: [VDFToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            if character == "{" { tokens.append(.open) }
            else if character == "}" { tokens.append(.close) }
            else if character == "\"" {
                var value = ""
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", text.index(after: index) < text.endIndex { index = text.index(after: index) }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
                tokens.append(.text(value))
            }
        }
        return tokens
    }

    private static func vdfBlock(_ tokens: [VDFToken], _ index: inout Int, depth: Int) -> [(key: String, node: VDFNode)] {
        var items: [(key: String, node: VDFNode)] = []
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case .close: return items
            case .open: if depth < 64 { _ = vdfBlock(tokens, &index, depth: depth + 1) }
            case .text(let key):
                guard index < tokens.count else { return items }
                if case .text(let value) = tokens[index] {
                    index += 1
                    items.append((key, VDFNode(value: value)))
                } else if case .open = tokens[index], depth < 64 {
                    index += 1
                    items.append((key, VDFNode(children: vdfBlock(tokens, &index, depth: depth + 1))))
                }
            }
        }
        return items
    }

    /// The `"<appid>" { ... }` block that `+app_info_print` prints, preceded by chatter.
    static func parseAppInfo(_ output: String, appID: String) -> VDFNode? {
        guard let start = output.range(of: "(?m)^\\s*\"\(appID)\"\\s*$", options: .regularExpression) else { return nil }
        let tokens = vdfTokens(output[start.lowerBound...])
        guard tokens.count > 2, case .open = tokens[1] else { return nil }
        var index = 2
        return VDFNode(children: vdfBlock(tokens, &index, depth: 0))
    }

    struct Depot: Equatable {
        var id: String
        var name: String
        var bytes: Int64          // what Steam will transfer (falls back to the unpacked size)
        var unpackedBytes: Int64
    }

    /// The depot most likely to hold Wallpaper Engine's shared files (UNVERIFIED): the largest public Windows depot
    /// without a language, DLC or other app attached. No depot id is hard-coded.
    static func sharedAssetsDepot(in app: VDFNode) -> Depot? {
        var best: Depot?
        for (key, node) in app.child("depots")?.children ?? [] where !key.isEmpty && key.allSatisfy({ $0.isNumber }) {
            let config = node.child("config")
            guard node.child("dlcappid") == nil, node.child("depotfromapp") == nil,
                  (config?.child("language")?.value ?? "").isEmpty,
                  config?.child("oslist")?.value.map({ $0.lowercased().contains("windows") }) ?? true,
                  let manifest = node.child("manifests")?.child("public") else { continue }
            let unpacked = Int64(manifest.child("size")?.value ?? "") ?? Int64(node.child("maxsize")?.value ?? "") ?? 0
            let download = Int64(manifest.child("download")?.value ?? "") ?? 0
            let rank = unpacked > 0 ? unpacked : download
            guard rank > 0 else { continue }
            if rank > (best?.unpackedBytes ?? 0) {
                best = Depot(id: key, name: node.child("name")?.value ?? "Depot \(key)",
                             bytes: download > 0 ? download : unpacked, unpackedBytes: rank)
            }
        }
        return best
    }

    /// The `assets` folder inside a downloaded depot (any case, up to three levels down), else the folder that
    /// holds `shaders` or `materials`.
    static func assetsFolder(in depot: URL) -> URL? {
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var level = [depot]
        for _ in 0..<3 {
            let next = level.flatMap(children)
            if let named = next.first(where: { $0.lastPathComponent.lowercased() == "assets" }) { return named }
            level = next
        }
        let candidates = [depot] + level
        return candidates.first { folder in
            children(folder).contains { ["shaders", "materials"].contains($0.lastPathComponent.lowercased()) }
        }
    }
}

// MARK: - One steamcmd action at a time

/// The wizard and the Workshop downloads never run steamcmd together. Wizard actions hold this gate; downloads
/// wait for it (WorkshopModel.pump) and wizard actions are refused while a download runs.
@MainActor enum SteamRunGate {
    private(set) static var busy = false
    static var onRelease: (@MainActor () -> Void)?

    static func acquire() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    static func release() {
        guard busy else { return }
        busy = false
        onRelease?()
    }
}

// MARK: - Download of steamcmd_osx.tar.gz (progress through a delegate; the async download(from:) has none)

final class SteamDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var downloaded: URL?
    private var failure: Error?

    init(progress: @escaping @Sendable (Double?) -> Void) {
        self.progress = progress
    }

    /// Saves `url` to `destination` (an http error status is a failure).
    func fetch(_ url: URL, to destination: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            lock.lock()
            self.continuation = continuation
            self.destination = destination
            task = session.downloadTask(with: url)
            task?.resume()
            lock.unlock()
            session.finishTasksAndInvalidate()
        }
    }

    func cancel() {
        lock.lock()
        let running = task
        lock.unlock()
        running?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            failure = URLError(.badServerResponse)
            return
        }
        guard let destination else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            downloaded = destination      // the temporary file is deleted when this method returns
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        if let error = error ?? failure { waiting?.resume(throwing: error) }
        else if let downloaded { waiting?.resume(returning: downloaded) }
        else { waiting?.resume(throwing: URLError(.cannotCreateFile)) }
    }
}

// MARK: - Model

@MainActor final class SteamSetupModel: ObservableObject {
    static let shared = SteamSetupModel()

    @Published private(set) var tools: SteamToolsState = .unknown { didSet { onChange?() } }
    @Published private(set) var account: SteamAccountState = .unknown { didSet { onChange?() } }
    @Published private(set) var ownership: SteamOwnershipState = .unknown { didSet { onChange?() } }
    @Published private(set) var assets: SteamAssetsState = .unknown
    /// Persisted (UserDefaults); not secret. Shown pre-filled in the sign-in form.
    @Published var username: String = WorkshopKit.Prefs.username.value {
        didSet { WorkshopKit.Prefs.username.value = username }
    }
    /// The last error, for the card to show; cleared when a new action starts.
    @Published private(set) var lastError: SteamSetupError?
    @Published private(set) var rosettaInstalling = false

    /// Called after tools, account or ownership changed (the Workshop model recomputes its setup status).
    var onChange: (() -> Void)?

    /// Which wizard card to show.
    var step: SteamWizardStep {
        switch tools {
        case .unknown, .missing, .installing, .failed: return .installTools
        case .rosettaRequired: return .fixRosetta
        case .ready: break
        }
        guard case .signedIn = account else { return .signIn }
        return ownership == .owned ? .done : .checkOwnership
    }

    /// Workshop downloads may start (tools ready and a cached login). Ownership `.couldNotCheck` still allows it.
    var canDownload: Bool {
        guard case .ready = tools, case .signedIn = account else { return false }
        return ownership != .notOwned
    }

    /// The steamcmd launcher to use for Workshop downloads, nil until tools are ready.
    var steamcmdPath: String? {
        if case .ready(let info) = tools { return info.path }
        return nil
    }

    /// HOME for a run of this steamcmd: the app-managed copy keeps its login token inside the app's own folder
    /// (UNVERIFIED that SteamCMD honours it); a copy the user installed keeps using the user's own folders.
    static func environment(forTool path: String) -> [String: String] {
        guard URL(fileURLWithPath: path).standardizedFileURL.path
                == AppPaths.steamToolsDirectory.appendingPathComponent("steamcmd.sh").standardizedFileURL.path else { return [:] }
        try? AppPaths.ensureDirectory(AppPaths.steamHomeDirectory)
        return ["HOME": AppPaths.steamHomeDirectory.path]
    }

    private var readyTool: SteamToolsInfo? {
        if case .ready(let info) = tools { return info }
        return nil
    }

    private var installTask: Task<Void, Never>?
    private var download: SteamDownload?
    private var installCancelled = false
    private var runner: WorkshopKit.Runner?
    private var pendingDepot: SteamKit.Depot?
    // Sign-in: the password and the code exist only in these byte buffers, from the call until the write.
    private var session: SteamPTYSession?
    private var machine = SteamSignInMachine(now: Date())
    private var pendingPassword: [UInt8] = []
    private var pendingCode: [UInt8] = []
    private var signInName = ""
    private var tickTask: Task<Void, Never>?
    private var generation = 0
    private var usedScript = false
    private var startedAt = Date()
    private var gotOutput = false
    private var signedInAt: Date?

    private let installerURL: URL

    init(installerURL: URL = SteamKit.installerURL) {
        self.installerURL = installerURL
    }

    // MARK: Tools

    /// Cheap, no network: look for the app-managed SteamCMD, then the Homebrew / manual locations of phase 2,
    /// read the architecture (`lipo -archs`), test Rosetta only when it matters, and see whether a cached login exists.
    func refresh() {
        if case .installing = tools { return }
        username = WorkshopKit.Prefs.username.value
        let managed = AppPaths.steamToolsDirectory.appendingPathComponent("steamcmd.sh").path
        let found = WorkshopKit.Locate.runnable(managed) ? managed
            : WorkshopKit.Locate.steamcmd(override: WorkshopKit.Prefs.steamcmd.value, home: WorkshopKit.home)
        guard let path = found else {
            tools = .missing
            resolveAccount()
            return
        }
        if tools == .unknown || tools == .missing { tools = .installing(.checking) }
        Task { @MainActor [weak self] in
            let state = await Task.detached { SteamKit.inspect(steamcmd: path) }.value
            guard let self else { return }
            if case .installing(let step) = self.tools, step != .checking { return }
            self.tools = state
            self.resolveAccount()
            if self.assets == .unknown { self.assets = Self.fetchedAssets() }
        }
    }

    private static func fetchedAssets() -> SteamAssetsState {
        let folder = AppPaths.sharedAssetsDirectory
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return items.isEmpty ? .notFetched : .ready(folder: folder.path)
    }

    /// Downloads steamcmd_osx.tar.gz from Valve, extracts it into AppPaths.steamToolsDirectory, runs it once
    /// (`+quit`) so it can update itself, then checks the architecture. Reports `.installing(step)`.
    /// One button for the Rosetta step: macOS asks for an administrator password, then the state is checked again.
    func installRosetta() {
        guard case .rosettaRequired = tools, !rosettaInstalling else { return }
        lastError = nil
        rosettaInstalling = true
        Task { @MainActor [weak self] in
            let failure = await Task.detached { SteamKit.installRosetta() }.value
            guard let self else { return }
            self.rosettaInstalling = false
            self.lastError = failure
            if failure == nil { self.refresh() }
        }
    }

    func installTools() {
        if case .installing = tools { return }
        lastError = nil
        guard acquireGate() else { return }
        installCancelled = false
        tools = .installing(.downloading(fraction: nil))
        installTask = Task { @MainActor [weak self] in
            await self?.runInstall()
            SteamRunGate.release()
        }
    }

    func cancelInstall() {
        installCancelled = true
        download?.cancel()
        runner?.cancel()
    }

    private func runInstall() async {
        let folder = AppPaths.steamToolsDirectory
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("steamcmd-\(UUID().uuidString).tar.gz")
        defer { try? FileManager.default.removeItem(at: archive) }
        do {
            let fetcher = SteamDownload { [weak self] fraction in
                Task { @MainActor [weak self] in
                    if case .installing(.downloading)? = self?.tools { self?.tools = .installing(.downloading(fraction: fraction)) }
                }
            }
            download = fetcher
            defer { download = nil }
            do {
                _ = try await fetcher.fetch(installerURL, to: archive)
            } catch {
                throw installCancelled ? SteamSetupError.cancelled : SteamSetupError.downloadFailed(Self.describe(error))
            }
            if SteamKit.fileSize(archive) < 100_000 { throw SteamSetupError.downloadFailed("the file is too small") }
            tools = .installing(.extracting)
            try await Task.detached { try SteamKit.install(archive: archive, into: folder) }.value
            try await firstRun(folder.appendingPathComponent("steamcmd.sh").path)
            tools = .installing(.checking)
            let state = await Task.detached { SteamKit.inspect(steamcmd: folder.appendingPathComponent("steamcmd.sh").path) }.value
            if case .ready(let info) = state, info.arch == .unknown, SteamKit.binary(in: folder) == nil {
                throw SteamSetupError.toolsBroken("the program file is missing")
            }
            tools = state
            resolveAccount()
        } catch {
            if case SteamSetupError.rosettaMissing = error {
                tools = .rosettaRequired          // installed fine, but the Intel binary cannot start yet
                return
            }
            try? FileManager.default.removeItem(at: folder)
            let reason = installCancelled ? SteamSetupError.cancelled : (error as? SteamSetupError ?? .processFailed(Self.describe(error)))
            tools = reason == .cancelled ? .missing : .failed(reason)
        }
    }

    /// SteamCMD updates itself the first time it runs (minutes). It may restart itself or need a second run.
    private func firstRun(_ path: String) async throws {
        var note = ""
        for attempt in 1...2 {
            tools = .installing(.firstRun(note: note))
            let limits = WorkshopKit.Runner.Limits(idle: 120, selfUpdate: 600, grace: 5, hard: 900)
            let run = try await steamRun(path, ["+quit"], limits: limits) { [weak self] line in
                guard let self, let fraction = SteamKit.updateFraction(line) else { return }
                note = "Updating… \(Int(fraction * 100))%"
                self.tools = .installing(.firstRun(note: note))
            }
            if installCancelled || run.cancelled { throw SteamSetupError.cancelled }
            if case .failure(.rosettaMissing)? = run.decisive { throw SteamSetupError.rosettaMissing }
            if !run.timedOut, run.exitCode == 0 { return }
            if attempt == 2 || run.timedOut {
                throw run.timedOut ? SteamSetupError.timedOut : SteamSetupError.firstRunFailed(run.detail)
            }
        }
    }

    // MARK: Account

    /// Starts `steamcmd +login <username>` under a pty and drives the prompts. The password is sent when its
    /// prompt appears and then dropped. Moves `account` through `.signingIn(step)` to `.signedIn` or back to
    /// `.signedOut` with the error in `lastError`.
    func signIn(username: String, password: String) {
        lastError = nil
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard readyTool != nil else { lastError = .processFailed("Install Steam’s tool first."); return }
        guard WorkshopKit.Invocation.isValidUsername(name) else {
            lastError = .loginFailed("Use the account name you sign in to Steam with, not your email address.")
            return
        }
        guard acquireGate() else { return }
        self.username = name
        signInName = name
        pendingPassword = Array(password.utf8)
        machine = SteamSignInMachine(now: Date())
        usedScript = false
        signedInAt = nil
        account = .signingIn(.starting)
        launchSession()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
    }

    /// Sends the Steam Guard code to the waiting prompt (or to the next one if Steam asks again).
    func submitGuardCode(_ code: String) {
        guard case .signingIn(.needsCode) = account else { return }
        pendingCode = Array(code.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        apply(machine.codeSubmitted(now: Date()))
    }

    func cancelSignIn() {
        guard session != nil else { return }
        endSignIn()
        account = .signedOut
    }

    private func launchSession() {
        guard let tool = readyTool else { return }
        generation += 1
        let mine = generation
        startedAt = Date()
        gotOutput = false
        let command = SteamCommandLine(executable: tool.path, arguments: ["+login", signInName],
                                       environment: SteamKit.childEnvironment(Self.environment(forTool: tool.path)))
        let pty = SteamPTYSession(command: command, useScript: usedScript)
        pty.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in self?.received(text, from: mine) }
        }
        pty.onExit = { [weak self] status in
            Task { @MainActor [weak self] in self?.sessionEnded(status, from: mine) }
        }
        session = pty
        do {
            try pty.start()
        } catch {
            session = nil
            let rosetta = (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == 86
            finishSignIn(rosetta ? nil : .processFailed("Steam’s tool could not be started."), rosetta: rosetta)
        }
    }

    private func received(_ text: String, from id: Int) {
        guard id == generation, session != nil else { return }
        gotOutput = true
        apply(machine.receive(text, now: Date()))
    }

    private func sessionEnded(_ status: Int32, from id: Int) {
        guard id == generation, session != nil else { return }
        if !gotOutput, !usedScript, status != 0, Date().timeIntervalSince(startedAt) < 5 {
            usedScript = true            // plan B: let /usr/bin/script give steamcmd a controlling terminal
            launchSession()
            return
        }
        apply(machine.exited(status))
        if session != nil { endSignIn() }
        if case .signedIn = account, let tool = readyTool { rememberTokenLocation(tool) }   // the token is written by +quit
    }

    private func tick() {
        apply(machine.tick(now: Date()))
        if let at = signedInAt, Date().timeIntervalSince(at) >= 10 { session?.terminate() }   // +quit did not end it
    }

    private func apply(_ reactions: [SteamSignInMachine.Reaction]) {
        for reaction in reactions {
            switch reaction {
            case .sendPassword: session?.sendLine(&pendingPassword, secret: true)
            case .sendCode: session?.sendLine(&pendingCode, secret: true)
            case .terminate: session?.terminate()
            case .show(let step): account = .signingIn(step)
            case .rosetta: finishSignIn(nil, rosetta: true)
            case .fail(let error): finishSignIn(error)
            case .signedIn:
                WorkshopKit.Prefs.signedOut.value = ""
                signedInAt = Date()
                account = .signedIn(username: signInName)
            }
        }
    }

    private func finishSignIn(_ error: SteamSetupError?, rosetta: Bool = false) {
        endSignIn()
        account = .signedOut
        lastError = error
        if rosetta { tools = .rosettaRequired }
    }

    private func endSignIn() {
        session?.terminate()
        session = nil
        tickTask?.cancel()
        tickTask = nil
        SteamSecret.wipe(&pendingPassword)
        SteamSecret.wipe(&pendingCode)
        SteamRunGate.release()
    }

    /// Does the isolated HOME hold the token? If not, SteamCMD keeps it in Steam's normal folder (UNVERIFIED).
    private func rememberTokenLocation(_ tool: SteamToolsInfo) {
        let isolated = SteamKit.tokenFile(dataFolder: AppPaths.steamHomeDirectory)
        let inside = tool.managedByApp && FileManager.default.fileExists(atPath: isolated.path)
        WorkshopKit.Prefs.tokenShared.value = inside ? "" : "1"
    }

    private func resolveAccount() {
        switch account {
        case .signingIn, .checking: return
        default: break
        }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = readyTool
        var file = SteamKit.tokenFile(dataFolder: WorkshopKit.home)
        if let tool, tool.managedByApp, WorkshopKit.Prefs.tokenShared.value.isEmpty {
            file = SteamKit.tokenFile(dataFolder: AppPaths.steamHomeDirectory)
        }
        if tool != nil, !name.isEmpty, WorkshopKit.Prefs.signedOut.value.isEmpty, SteamKit.tokenMentions(name, in: file) {
            account = .signedIn(username: name)
        } else {
            account = .signedOut
            ownership = .unknown
        }
    }

    /// The Workshop side learned something about the cached login (a download signed in, or was refused).
    func noteLogin(_ state: SteamLoginState, user: String) {
        guard session == nil else { return }
        switch state {
        case .loggedIn: if account != .signedIn(username: user) { account = .signedIn(username: user) }
        case .needsLogin: account = .signedOut
        default: break
        }
    }

    /// A download was refused with "No subscription" / "Access denied".
    func noteNotOwned() {
        ownership = .notOwned
    }

    /// Logs out and removes the cached login that lives under AppPaths.steamHomeDirectory. Never touches the
    /// user's own Steam installation.
    func signOut() {
        lastError = nil
        guard session == nil, acquireGate() else { return }
        let tool = readyTool
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let tool {
                _ = try? await self.steamRun(tool.path, ["+@NoPromptForPassword", "1", "+logout", "+quit"],
                                             limits: .init(idle: 5, selfUpdate: 5, grace: 2, hard: 10)) { _ in }
            }
            let external = tool.map { !$0.managedByApp } ?? false
            let shared = external || !WorkshopKit.Prefs.tokenShared.value.isEmpty
            try? FileManager.default.removeItem(at: AppPaths.steamHomeDirectory)
            WorkshopKit.Prefs.signedOut.value = "1"
            self.account = .signedOut
            self.ownership = .unknown
            if shared {
                self.lastError = .loginFailed("Steam’s tool keeps its login in Steam’s normal folder. To remove it completely, sign out in the Steam app.")
            }
            SteamRunGate.release()
        }
    }

    /// Checks that the signed-in account owns Wallpaper Engine (app 431960). Sets `ownership`.
    func checkOwnership() {
        lastError = nil
        guard case .signedIn(let name) = account, readyTool != nil, acquireGate() else { return }
        ownership = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lines: [String] = []
            let stop = await self.runSignedIn(["+@NoPromptForPassword", "1", "+login", name, "+licenses_print", "+quit"]) {
                lines.append($0)
            }
            self.ownership = stop ?? SteamKit.ownership(fromLicenses: lines)
            SteamRunGate.release()
        }
    }

    /// Runs a signed-in steamcmd command; returns a state to stop with when the login or the tool is the problem.
    private func runSignedIn(_ arguments: [String], onLine: (String) -> Void) async -> SteamOwnershipState? {
        guard let tool = readyTool else { return .couldNotCheck("Steam’s tool isn’t installed.") }
        do {
            let run = try await steamRun(tool.path, arguments, limits: .init(), onLine: onLine)
            switch run.decisive {
            case .failure(.needsLogin)?:
                account = .signedOut
                lastError = .loginFailed("Your saved Steam login has expired. Sign in again.")
                return .unknown
            case .failure(.rosettaMissing)?:
                tools = .rosettaRequired
                return .unknown
            default:
                return run.timedOut ? .couldNotCheck("Steam took too long to answer. You can still try a download.") : nil
            }
        } catch {
            return .couldNotCheck("Steam’s tool could not be started. You can still try a download.")
        }
    }

    // MARK: Shared assets (optional; which depot holds them is UNVERIFIED)

    /// Optional: discovers the depot with Wallpaper Engine's shared assets (`+app_info_print 431960`), asks for
    /// confirmation (`.needsConfirmation`), then downloads it into AppPaths.sharedAssetsDirectory.
    /// Precondition failures are reported in the card instead of no-oping silently.
    func prepareSharedAssets() {
        lastError = nil
        guard case .signedIn(let name) = account else {
            assets = .failed(.assetsFailed("Sign in to Steam first (step 2 of the wizard)."))
            return
        }
        guard readyTool != nil else {
            assets = .failed(.assetsFailed("Install Steam’s command-line tool first (step 1 of the wizard)."))
            return
        }
        guard acquireGate() else {
            assets = .failed(.assetsFailed("A Steam download is running. Wait for it to finish, then try again."))
            return
        }
        assets = .discovering
        pendingDepot = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            var text = ""
            let stop = await self.runSignedIn(["+@NoPromptForPassword", "1", "+login", name, "+app_info_update", "1",
                                               "+app_info_print", WorkshopKit.appID, "+quit"]) { text += $0 + "\n" }
            if stop != nil {
                self.assets = .failed(.assetsFailed("Steam didn’t answer. Try again."))
            } else if let app = SteamKit.parseAppInfo(text, appID: WorkshopKit.appID),
                      let depot = SteamKit.sharedAssetsDepot(in: app) {
                self.pendingDepot = depot
                self.assets = .needsConfirmation(downloadBytes: depot.bytes, depotName: depot.name)
            } else {
                self.assets = .unavailable("PaperFlow couldn’t find Wallpaper Engine’s shared files on Steam. Scenes that need them will show their preview only.")
            }
            SteamRunGate.release()
        }
    }

    func confirmSharedAssets() {
        lastError = nil
        guard case .needsConfirmation = assets, let depot = pendingDepot else { return }
        guard case .signedIn(let name) = account else {
            assets = .failed(.assetsFailed("Sign in to Steam first (step 2 of the wizard)."))
            return
        }
        guard readyTool != nil else {
            assets = .failed(.assetsFailed("Install Steam’s command-line tool first (step 1 of the wizard)."))
            return
        }
        guard acquireGate() else {
            assets = .failed(.assetsFailed("A Steam download is running. Wait for it to finish, then try again."))
            return
        }
        let staging = AppPaths.steamStagingDirectory.appendingPathComponent("assets-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        if let free = SteamKit.freeBytes(at: WorkshopKit.home), Double(free) < Double(depot.unpackedBytes) * 1.2 {
            assets = .failed(.diskSpace(neededBytes: Int64(Double(depot.unpackedBytes) * 1.2)))
            SteamRunGate.release()
            return
        }
        assets = .fetching(fraction: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let limits = WorkshopKit.Runner.Limits(idle: 300, selfUpdate: 600, grace: 5, hard: .infinity)
            let result = await self.fetchDepot(depot, user: name, staging: staging, limits: limits)
            try? FileManager.default.removeItem(at: staging)
            self.assets = result
            SteamRunGate.release()
        }
    }

    private func fetchDepot(_ depot: SteamKit.Depot, user: String, staging: URL,
                            limits: WorkshopKit.Runner.Limits) async -> SteamAssetsState {
        guard let tool = readyTool else { return .failed(.assetsFailed("Steam’s tool isn’t installed.")) }
        // Reality check (was UNVERIFIED in the spec): download_depot ignores force_install_dir and unpacks
        // under SteamCMD's own root — staging/steamapps stays empty. Both locations are honored here.
        let toolRoot = URL(fileURLWithPath: (tool.path as NSString).deletingLastPathComponent)
        let appDirName = "app_\(WorkshopKit.appID)"
        let steamapps = toolRoot.appendingPathComponent("steamapps", isDirectory: true)
        let content = steamapps.appendingPathComponent("content/\(appDirName)", isDirectory: true)
        let candidates = [
            content.appendingPathComponent("depot_\(depot.id)", isDirectory: true),
            staging.appendingPathComponent("steamapps/content/\(appDirName)/depot_\(depot.id)", isDirectory: true),
        ]
        // A failed earlier attempt leaves a complete depot on disk: claim it instead of downloading again.
        if let ready = candidates.lazy.compactMap({ SteamKit.assetsFolder(in: $0) }).first {
            return claimSharedAssets(ready: ready, depotFolder: ready.deletingLastPathComponent(), steamapps: steamapps, depotID: depot.id)
        }
        do {
            let arguments = ["+@sSteamCmdForcePlatformType", "windows", "+force_install_dir", staging.path,
                             "+@NoPromptForPassword", "1", "+login", user,
                             "+download_depot", WorkshopKit.appID, depot.id, "+quit"]
            let total = max(depot.unpackedBytes, 1)
            let run = try await steamRun(tool.path, arguments, limits: limits, onLine: { _ in }, onTick: { [weak self] in
                let size = WorkshopKit.Locate.folderBytes(content)
                guard let self, size > 0 else { return false }
                self.assets = .fetching(fraction: min(0.99, Double(size) / Double(total)))
                return true
            })
            if case .failure(.needsLogin)? = run.decisive {
                account = .signedOut
                return .failed(.assetsFailed("Your saved Steam login has expired. Sign in again."))
            }
            guard !run.timedOut, !run.cancelled,
                  let folder = candidates.lazy.compactMap({ SteamKit.assetsFolder(in: $0) }).first else {
                return .failed(.assetsFailed(run.timedOut ? "Steam took too long to answer." : "Steam finished without the expected files. \(run.detail)"))
            }
            return claimSharedAssets(ready: folder, depotFolder: folder.deletingLastPathComponent(), steamapps: steamapps, depotID: depot.id)
        } catch {
            return .failed(.assetsFailed(Self.describe(error)))
        }
    }

    /// Moves the depot's `assets` folder into `AppPaths.sharedAssetsDirectory` and deletes the rest of the
    /// depot (`projects`, `ui`, installers: several hundred MB) plus SteamCMD's `state_<app>_<depot>.patch`.
    private func claimSharedAssets(ready: URL, depotFolder: URL, steamapps: URL, depotID: String) -> SteamAssetsState {
        do {
            try? FileManager.default.removeItem(at: AppPaths.sharedAssetsDirectory)
            try AppPaths.ensureDirectory(AppPaths.sharedAssetsDirectory.deletingLastPathComponent())
            try FileManager.default.moveItem(at: ready, to: AppPaths.sharedAssetsDirectory)
            try? FileManager.default.removeItem(at: depotFolder)
            try? FileManager.default.removeItem(
                at: steamapps.appendingPathComponent("state_\(WorkshopKit.appID)_\(depotID).patch"))
            return .ready(folder: AppPaths.sharedAssetsDirectory.path)
        } catch {
            return .failed(.assetsFailed(Self.describe(error)))
        }
    }

    func removeSharedAssets() {
        try? FileManager.default.removeItem(at: AppPaths.sharedAssetsDirectory)
        pendingDepot = nil
        assets = .notFetched
    }

    // MARK: Plumbing

    /// Ends every steamcmd action of the wizard (app quit).
    func shutdown() {
        cancelInstall()
        if session != nil { cancelSignIn() }
        runner?.cancel()
    }

    private func acquireGate() -> Bool {
        if WorkshopModel.shared.isBusyWithSteam || !SteamRunGate.acquire() {
            lastError = .processFailed("A download is running. Wait for it to finish, then try again.")
            return false
        }
        return true
    }

    private func steamRun(_ path: String, _ arguments: [String], limits: WorkshopKit.Runner.Limits,
                          onLine: (String) -> Void, onTick: () -> Bool = { false }) async throws -> WorkshopKit.Run {
        let runner = WorkshopKit.Runner(executable: path, environment: SteamKit.childEnvironment(Self.environment(forTool: path)),
                                        limits: limits)
        self.runner = runner
        defer { self.runner = nil }
        do {
            return try await runner.run(arguments: arguments, onEvent: { _ in }, onTick: onTick, onLine: onLine)
        } catch {
            if case .rosettaMissing = WorkshopKit.launchError(error) { throw SteamSetupError.rosettaMissing }
            throw SteamSetupError.processFailed("Steam’s tool could not be started.")
        }
    }

    /// Fixed wording: an error's own text can carry a URL or a path.
    private static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "no internet connection"
            case .timedOut: return "the request timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Valve’s server couldn’t be reached"
            default: return "network error \(error.code.rawValue)"
            }
        }
        return error.localizedDescription
    }
}
