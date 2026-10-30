import AppKit
import Foundation

/// Asks GitHub for the latest release tag and offers the download when it is newer than this copy.
/// The sidebar shows `status`; the launch check and Check for Updates… both update it.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let latestRelease = URL(string: "https://api.github.com/repos/NOOB-3301/LiveWallpaper/releases/latest")!

    enum Status: Equatable {
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    @Published private(set) var status: Status = .checking

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// `interactive` (the menu item) also reports "up to date" and failures; the launch check stays quiet unless there is an update.
    func check(interactive: Bool) async {
        status = .checking
        let release: Release
        do {
            var request = URLRequest(url: Self.latestRelease)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            status = .failed
            if interactive { Self.inform("Couldn’t check for updates", error.localizedDescription) }
            return
        }
        guard Self.isNewer(release.tagName, than: currentVersion) else {
            status = .upToDate
            if interactive { Self.inform("PaperFlow is up to date", "Version \(currentVersion) is the latest.") }
            return
        }
        let version = release.tagName.trimmingCharacters(in: ["v", "V"])
        status = .available(version: version, url: release.htmlURL)
        let alert = NSAlert()
        alert.messageText = "A new version of PaperFlow is available"
        alert.informativeText = "PaperFlow \(version) is out. You have \(currentVersion)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
    }

    /// Compares dotted numbers ("v6.10.0" vs "6.9.1"); missing parts count as 0.
    static func isNewer(_ tag: String, than version: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: ["v", "V"]).split(separator: ".").map { Int($0) ?? 0 }
        }
        let latest = parts(tag), mine = parts(version)
        for index in 0..<max(latest.count, mine.count) {
            let a = index < latest.count ? latest[index] : 0
            let b = index < mine.count ? mine[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
