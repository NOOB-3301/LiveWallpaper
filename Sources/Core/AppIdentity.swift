import Foundation

/// Bundle identifiers and the Info.plist role key, shared by the settings app and the background service.
/// The identifiers keep the pre-rename "LiveWallpaper" spelling on purpose: changing them would orphan the
/// existing data folder and force every user to re-grant Screen Recording and Accessibility permissions.
public enum AppIdentity {
    public static let settingsBundleID = "com.noob3301.LiveWallpaper"
    public static let serviceBundleID = "com.noob3301.LiveWallpaper.service"
    /// Info.plist key that tells the two apps apart: "settings" or "service".
    public static let roleKey = "LWRole"
}
