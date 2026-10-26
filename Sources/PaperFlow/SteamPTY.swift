import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Owner: STEAM. One interactive steamcmd run under a pseudo-terminal (SPEC3.md section 4.4), plus the helpers every
// steamcmd run shares: the output scrubber and process-tree termination. Foundation + libc only (no AppKit or
// SwiftUI) so the Linux harness can typecheck and run it. Design:
//  - posix_openpt / grantpt / unlockpt / ptsname give a master fd and a slave path. `Process` gets the slave as
//    stdin, stdout and stderr, so steamcmd sees a terminal and prompts for the password. Nothing secret is ever
//    in argv or the environment.
//  - Plan B (`useScript`): `/usr/bin/script -q /dev/null <steamcmd.sh> ...` on the same pty. `script` gives its child
//    its own pty with a controlling terminal, for the case that steamcmd refuses a bare stdin terminal.
//  - Before a secret is written, `tcgetattr` on the master must show ECHO off (it is turned off if needed); if that
//    fails the secret is not written and the run is ended.
//  - Output is scrubbed (ANSI removed, every occurrence of a registered secret replaced by "••••") BEFORE it
//    reaches `onOutput`. The secret is a [UInt8] that is overwritten with zeros right after the write.

struct SteamCommandLine {
    var executable: String           // absolute path to steamcmd.sh
    var arguments: [String]          // never contains a password
    var environment: [String: String]
}

/// Removes control sequences and registered secrets from steamcmd output. `feed` works on a stream: it holds back
/// an unfinished escape sequence and any tail that could still turn into a secret, so nothing leaks across chunks.
struct SteamScrubber {
    static let mask = "••••"
    private static let escapes = "\u{1B}\\[[0-9;?<=>]*[ -/]*[@-~]|\u{1B}[()#][0-9A-Za-z]|\u{1B}[@-Z\\\\-_]"

    private var secrets: [String] = []
    private var held = ""

    mutating func register(_ secret: String) {
        if !secret.isEmpty { secrets.append(secret) }
    }

    mutating func clear() {
        secrets = []
        held = ""
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: escapes, with: "", options: .regularExpression)
    }

    /// One-shot: ANSI removed, every secret replaced; with `redactCodes` a five-character Steam Guard code right
    /// after the word "code" is masked as well (for lines that are shown to the user after a code was sent).
    static func scrub(_ text: String, secrets: [String], redactCodes: Bool = false) -> String {
        var plain = stripANSI(text)
        for secret in secrets where !secret.isEmpty { plain = plain.replacingOccurrences(of: secret, with: mask) }
        if redactCodes {
            plain = plain.replacingOccurrences(of: "([Cc]ode\\W{0,3})\\b[0-9A-Z]{5}\\b", with: "$1" + mask,
                                               options: .regularExpression)
        }
        return plain
    }

    /// The text that is safe to show now; the rest stays held until the next chunk or `flush`.
    mutating func feed(_ text: String) -> String {
        var pending = held + text
        held = ""
        if let escape = pending.lastIndex(of: "\u{1B}"), Self.isUnfinishedEscape(pending[escape...]) {
            held = String(pending[escape...])
            pending = String(pending[..<escape])
        }
        let safe = Self.scrub(pending, secrets: secrets)
        let keep = secrets.map { Self.partialSecretLength(in: safe, secret: $0) }.max() ?? 0
        held = String(safe.suffix(keep)) + held
        return String(safe.dropLast(keep))
    }

    mutating func flush() -> String {
        let rest = Self.scrub(held, secrets: secrets)
        held = ""
        return rest
    }

    private static func isUnfinishedEscape(_ tail: Substring) -> Bool {
        guard tail.count > 1 else { return true }
        let second = tail[tail.index(after: tail.startIndex)]
        if second == "[" { return !tail.dropFirst(2).contains { $0.asciiValue.map { (0x40...0x7E).contains($0) } ?? false } }
        if "()#".contains(second) { return tail.count < 3 }
        return false
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `secret`.
    private static func partialSecretLength(in text: String, secret: String) -> Int {
        guard secret.count > 1 else { return 0 }
        for length in stride(from: min(text.count, secret.count - 1), to: 0, by: -1)
        where text.suffix(length) == secret.prefix(length) {
            return length
        }
        return 0
    }
}

/// Bytes -> text without splitting a multi-byte character across two reads.
struct SteamUTF8Stream {
    private var pending: [UInt8] = []

    mutating func decode(_ bytes: [UInt8]) -> String {
        pending += bytes
        for cut in 0...min(3, pending.count) {
            if let text = String(bytes: pending.dropLast(cut), encoding: .utf8) {
                pending = Array(pending.suffix(cut))
                return text
            }
        }
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}

enum SteamSecret {
    /// Overwrites the bytes with zeros and empties the array.
    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            #if canImport(Darwin)
            _ = memset_s(base, buffer.count, 0, buffer.count)
            #else
            explicit_bzero(base, buffer.count)
            #endif
        }
        bytes.removeAll()
    }
}

/// Helpers for steamcmd's process tree: steamcmd.sh does not exec the binary, so ending only the script would
/// orphan it.
enum SteamProcess {
    /// Runs a short tool to its end and returns its status and combined output. Blocking: call off the main thread.
    static func capture(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Children and grandchildren of `root`, deepest first.
    static func descendants(of root: Int32) -> [Int32] {
        guard let table = capture("/bin/ps", ["-axo", "pid=,ppid="])?.output else { return [] }
        var children: [Int32: [Int32]] = [:]
        for line in table.split(separator: "\n") {
            let numbers = line.split(separator: " ").compactMap { Int32($0) }
            if numbers.count == 2 { children[numbers[1], default: []].append(numbers[0]) }
        }
        var found: [Int32] = []
        var frontier = [root]
        while let parent = frontier.popLast() {
            for child in children[parent] ?? [] { found.append(child); frontier.append(child) }
        }
        return found.reversed()
    }

    /// SIGTERM to `pid` and everything it started, SIGKILL for whatever is left two seconds later.
    static func terminateTree(_ pid: Int32) {
        let targets = descendants(of: pid) + [pid]
        for target in targets { kill(target, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for target in targets where kill(target, 0) == 0 { kill(target, SIGKILL) }
        }
    }
}

final class SteamPTYSession: @unchecked Sendable {
    /// Scrubbed text as it arrives (any thread).
    var onOutput: (@Sendable (String) -> Void)?
    /// Exit status once the process ended and its output was delivered (any thread, once).
    var onExit: (@Sendable (Int32) -> Void)?

    private let command: SteamCommandLine
    private let useScript: Bool
    private let queue = DispatchQueue(label: "PaperFlow.steam.pty")
    private let lock = NSLock()
    private var master: Int32 = -1
    private var process: Process?
    private var reader: DispatchSourceRead?
    private var scrubber = SteamScrubber()
    private var utf8 = SteamUTF8Stream()
    private var exitStatus: Int32?
    private var outputDone = false
    private var finished = false
    private var terminated = false

    init(command: SteamCommandLine, useScript: Bool = false) {
        self.command = command
        self.useScript = useScript
    }

    /// Opens the pty, launches the process. Throws POSIX/Process errors (message contains no secrets).
    func start() throws {
        let fd = posix_openpt(O_RDWR | O_NOCTTY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard grantpt(fd) == 0, unlockpt(fd) == 0, let name = ptsname(fd) else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        let slave = open(String(cString: name), O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        master = fd
        _ = setEcho(false)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: useScript ? "/usr/bin/script" : command.executable)
        process.arguments = useScript ? ["-q", "/dev/null", command.executable] + command.arguments : command.arguments
        process.environment = command.environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            self?.queue.async { self?.processEnded(status) }
        }
        do {
            try process.run()
        } catch {
            close(slave)
            close(fd)
            master = -1
            throw error
        }
        close(slave)                                  // only the child keeps the slave, so EOF can arrive
        self.process = process
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        reader = source
        source.resume()
    }

    /// Writes `text` + "\n" to the pty and wipes the buffer. `secret` true registers the text for scrubbing.
    func sendLine(_ text: inout [UInt8], secret: Bool) {
        var line = text + [0x0A]
        defer { SteamSecret.wipe(&text); SteamSecret.wipe(&line) }
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0, !finished, !terminated else { return }
        if secret {
            scrubber.register(String(decoding: text, as: UTF8.self))
            guard setEcho(false) else {
                terminateLocked()
                return
            }
        }
        var offset = 0
        while offset < line.count {
            let written = line.withUnsafeBytes { write(master, $0.baseAddress! + offset, line.count - offset) }
            if written > 0 { offset += written }
            else if errno == EAGAIN || errno == EINTR { usleep(1000) }
            else { return }
        }
    }

    /// SIGTERM to the process tree, SIGKILL after 2 s. Idempotent.
    func terminate() {
        lock.lock()
        terminateLocked()
        lock.unlock()
    }

    // MARK: Internals

    /// Turns echo off (or on) for the pty and reports whether the master now shows the wanted state.
    private func setEcho(_ on: Bool) -> Bool {
        var attributes = termios()
        guard tcgetattr(master, &attributes) == 0 else { return false }
        let flags = tcflag_t(ECHO | ECHONL)
        if on { attributes.c_lflag |= flags } else { attributes.c_lflag &= ~flags }
        _ = tcsetattr(master, TCSANOW, &attributes)
        guard tcgetattr(master, &attributes) == 0 else { return false }
        return on || (attributes.c_lflag & tcflag_t(ECHO)) == 0
    }

    private func terminateLocked() {
        guard !terminated else { return }
        terminated = true
        scrubber.clear()
        if let process, process.isRunning { SteamProcess.terminateTree(process.processIdentifier) }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                deliver(Array(buffer[0..<count]))
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                finishOutput()      // EOF, or EIO once every slave descriptor is closed
                return
            }
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        lock.lock()
        let text = scrubber.feed(utf8.decode(bytes))
        lock.unlock()
        if !text.isEmpty { onOutput?(text) }
    }

    private func finishOutput() {
        guard !outputDone else { return }
        outputDone = true
        reader?.cancel()
        reader = nil
        lock.lock()
        let rest = scrubber.flush()
        lock.unlock()
        if !rest.isEmpty { onOutput?(rest) }
        finishIfDone()
    }

    private func processEnded(_ status: Int32) {
        exitStatus = status
        finishIfDone()
        // A grandchild that kept the terminal open would hold the output back forever.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finishOutput() }
    }

    private func finishIfDone() {
        guard outputDone, let status = exitStatus, !finished else { return }
        lock.lock()
        finished = true
        scrubber.clear()
        lock.unlock()
        onExit?(status)
    }
}
