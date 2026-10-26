import SwiftUI
import AppKit
import Core

/// The standard macOS Settings window (⌘,). Global playback and performance options live here so the
/// Library inspector can stay focused on the selected wallpaper.
@MainActor
struct PlaybackSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playback").font(.system(size: 24, weight: .semibold))
                    Text("These settings apply to every wallpaper.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                LibrarySettingsCard(model: model)

                about
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var about: some View {
        InspectorSection(title: "About") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PaperFlow").font(.callout.weight(.semibold))
                        Text("Version \(version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Videos and Wallpaper Engine scenes for your desktop and lock screen. Settings never plays a wallpaper; the background service does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Link("Project page", destination: URL(string: "https://github.com/NOOB-3301/LiveWallpaper")!)
                    Link("Wallpaper Settings", destination: URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                }
                .font(.caption)
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
