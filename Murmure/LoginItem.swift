import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.louiscourcier.Murmure", category: "loginitem")

/// Murmure's own login-item registration, as the General pane's toggle needs it.
///
/// **`SMAppService` holds the truth and `AppSettings.launchAtLogin` holds the intent** — that split
/// is written on the setting itself and this file is the other half of it. The two really can
/// disagree: System Settings › General › Login Items can revoke the registration while Murmure is
/// not running, and nothing tells the app. So the toggle reads the SERVICE, and the stored boolean
/// is only ever written after a call below has succeeded.
///
/// **Nothing here is called during development, and that is deliberate rather than cautious.**
/// `register()` writes a persistent registration into the login items of the machine the code is
/// being written on; there is no dry run, and undoing it means noticing it happened.
enum LoginItem {
    /// What macOS is actually doing, right now.
    ///
    /// Read every time the pane appears rather than cached at launch, for the reason above: the
    /// registration can be turned off from System Settings between two openings of this window,
    /// and a cached answer would show a toggle that is on for a launch that will not happen.
    ///
    /// `.requiresApproval` is deliberately NOT `true`. It is the state after Louis has switched
    /// Murmure off in System Settings: the app has asked, and macOS is refusing until he says yes
    /// there. Reporting that as "on" would be a toggle claiming a launch that is not going to
    /// happen — see ``approvalNote``, which is the row's only way to say so.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The line under the toggle when macOS is holding the registration back, or nil.
    ///
    /// `.requiresApproval` is the one status a toggle cannot express: flipping it again does
    /// nothing, because the refusal is not Murmure's to lift. Without this sentence the row is a
    /// switch that will not stay where it is put, with nothing anywhere saying why.
    ///
    /// `.notFound` is left silent on purpose. It means the bundle is not where `launchservicesd`
    /// expects it, which in practice is a Debug build run from Xcode's DerivedData — a state that
    /// is normal here and that Louis will never see in an installed copy.
    static var approvalNote: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            "macOS is holding this back. Turn Murmure on in System Settings › General › "
                + "Login Items to let it start with your session."
        case .enabled, .notRegistered, .notFound:
            nil
        @unknown default:
            nil
        }
    }

    /// Where ``approvalNote`` sends him. The same deep-link shape `AppAlert` already uses for
    /// Accessibility, so the two rows offer their fix the same way.
    static let settingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    /// Registers or unregisters, and says whether it worked.
    ///
    /// **Returns rather than throws-and-is-logged**, because the caller is a toggle: a failure has
    /// to put the switch back where it was and say something, and a `Bool` that is ignored would
    /// leave it sitting in a position macOS does not agree with. The error is logged here because
    /// this is the layer that has it, and the message the pane shows is the pane's.
    ///
    /// Registering twice is not an error (`SMAppService` treats it as idempotent), which matters:
    /// the toggle can be flipped faster than the service answers.
    @discardableResult
    static func setEnabled(_ wanted: Bool) -> Bool {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            logger.error("""
                login item \(wanted ? "registration" : "removal", privacy: .public) refused: \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
    }
}
