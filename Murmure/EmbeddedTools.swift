import Foundation
import MurmureCore

/// The two external binaries the acquisition shells out to, seen from the app target
/// (plan §4 lot 4, `Murmure/EmbeddedTools.swift`).
///
/// **This file has no tests, and that is a property of the target, not an omission.** The app
/// target has no test bundle (`MainWindowView.swift` states it), so nothing here can be covered by
/// `swift test`. The decisions therefore live in `MurmureCore` -- `ToolLocations` is the contract
/// that IS tested -- and this file only hands it the two things the core is not allowed to know:
/// the running bundle, and where Murmure keeps what it owns.
///
/// **`ffmpeg` travels inside the bundle, `yt-dlp` does not**, and the split is the whole point
/// (`ToolLocations`). ffmpeg is built and vendored by lot 5 and signed with the application
/// (criterion 4: an LGPL build, never Homebrew's GPL one). yt-dlp is downloaded at first use into
/// Application Support (criterion 5) precisely so it can be updated (criterion 6) without
/// notarising a new app.
enum EmbeddedTools {
    /// `Murmure.app/Contents/Resources/ffmpeg`, or `nil` when the resource is not there.
    static func ffmpeg(in bundle: Bundle = .main) -> URL? {
        ToolLocations.ffmpeg(inBundle: bundle)
    }

    /// `Application Support/Murmure/tools/yt-dlp`.
    static func ytDlp(in applicationSupport: URL = Storage.url()) -> URL {
        ToolLocations.ytDlp(in: applicationSupport)
    }
}
