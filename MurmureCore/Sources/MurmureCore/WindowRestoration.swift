import CoreGraphics
import Foundation

/// Where the window was left: which section, and what frame — remembered across launches.
///
/// `UserDefaults` is the whole store, and injected, for the two reasons `ModePreference` gives:
/// this is furniture and not content, so losing it costs a drag and a click; and a test that
/// reached `.standard` would write into the preferences domain of the application Louis is using.
///
/// **Reading is total and never fails.** Neither half of this is worth refusing to open a window
/// over, so both degrade to a default rather than to an error: an unrecognised section name
/// resolves to History, and a frame that would put the window somewhere Louis cannot reach it is
/// dropped in favour of AppKit's own placement. The failure being guarded against is not a corrupt
/// plist — it is the ordinary one, an external display unplugged since the last launch, which
/// leaves a perfectly well-formed frame at x = 2560 and a window nobody will ever see again. An
/// accessory app makes that worse than it sounds: there is no ⌘Tab entry and no Dock icon to get
/// it back with (plan §2.4).
public struct WindowRestoration {
    /// Never renamed lightly — the name IS the migration, the same rule
    /// `ModePreference.storageKey` carries. A rename here forgets which section the window was
    /// left on, which costs one click; the getter below is written so that it costs exactly that
    /// and never an empty window.
    private static let sectionKey = "windowSection"
    private static let frameKey = "windowFrame"

    /// How much of the window has to be on some screen for the stored frame to be used.
    ///
    /// A titlebar's height and enough width to put a cursor on: the question this answers is not
    /// "is any of it visible" but "can it be dragged back", because a window with four points on
    /// screen is as lost as one with none. Both numbers are judgement — the constraint they encode
    /// is not.
    ///
    /// Each screen is measured on its own, so a window straddling two displays with too little on
    /// either is refused even though it would in fact be graspable. That is conservative on the
    /// safe side: the cost is that the window opens where AppKit puts it.
    public static let minimumGrab = CGSize(width: 120, height: 28)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - The section

    /// The section the window opens on.
    ///
    /// An unrecognised stored name reads as History rather than as nothing. It is reachable two
    /// ways that both matter: a hand-run `defaults write`, and — the real one — a section removed
    /// or renamed in a later lot, which leaves every window that was last closed on it holding a
    /// name that no longer exists. Resolving to `nil` there would mean a window with no selection
    /// and an empty detail pane, which looks exactly like a bug.
    public var section: WindowSection {
        get {
            guard let stored = defaults.string(forKey: Self.sectionKey),
                  let section = WindowSection(rawValue: stored)
            else { return .fallback }
            return section
        }
        // `nonmutating` for `ModePreference`'s reason: the storage is the `UserDefaults` object,
        // not this struct, so a value type held by a view still has to be able to write through it.
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.sectionKey)
        }
    }

    // MARK: - The frame

    /// The frame exactly as it was stored, with no judgement applied about whether it is reachable.
    ///
    /// Split from `frame(onScreens:)` so that the two questions can be answered apart: this one is
    /// "did the round trip survive", which is a codec; the other is "is it still usable", which is
    /// a fact about the hardware attached right now and changes between two reads of the same
    /// value.
    ///
    /// Four numbers rather than an archived `NSValue`: a plist array of doubles can be read back
    /// by `defaults read`, and it cannot fail to decode in a way that has to be handled.
    public var storedFrame: CGRect? {
        get {
            guard let numbers = defaults.array(forKey: Self.frameKey) as? [Double],
                  numbers.count == 4,
                  numbers.allSatisfy({ $0.isFinite })
            else { return nil }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        nonmutating set {
            // An explicit nil is an instruction: forget where the window was.
            guard let frame = newValue else {
                defaults.removeObject(forKey: Self.frameKey)
                return
            }
            // A malformed frame is not an instruction, it is a bug upstream -- a live window never
            // has one, so this is only reachable through a hand-edit or a mistake. Ignored, and
            // deliberately NOT treated as the clear above: erasing would spend the last frame that
            // WAS good and send the next launch back to AppKit's placement, which is a visible
            // regression caused by a value that should never have arrived. Dropping it on the
            // floor costs nothing and keeps the window where Louis last left it.
            guard Self.isWellFormed(frame) else { return }
            defaults.set(
                [frame.origin.x, frame.origin.y, frame.width, frame.height], forKey: Self.frameKey)
        }
    }

    /// The stored frame if the window would land somewhere Louis can reach, otherwise nil — in
    /// which case the caller lets AppKit place the window and stores whatever it chose.
    ///
    /// `visibleFrames` is `NSScreen.screens.map(\.visibleFrame)`, read at the moment the window
    /// opens. Passed in rather than read here so that this stays a function of its arguments: the
    /// display layout is the one input a test cannot otherwise vary, and it is the whole subject.
    public func frame(onScreens visibleFrames: [CGRect]) -> CGRect? {
        guard let stored = storedFrame else { return nil }
        return Self.usableFrame(stored, onScreens: visibleFrames)
    }

    /// Whether a frame may be restored, given the screens attached right now.
    public static func usableFrame(_ stored: CGRect, onScreens visibleFrames: [CGRect]) -> CGRect? {
        guard isWellFormed(stored) else { return nil }
        for screen in visibleFrames {
            let overlap = stored.intersection(screen)
            // `.intersection` returns the null rect when they do not touch, and a null rect's
            // width and height are 0 — so this holds without a special case. It is spelled out
            // because a reader checking for one would otherwise go looking.
            guard overlap.width >= minimumGrab.width, overlap.height >= minimumGrab.height
            else { continue }
            return stored
        }
        return nil
    }

    /// Finite, and an actual rectangle. Guards the write as well as the read: `NaN` cannot be
    /// stored in a property list, and a frame containing one would take the app down on the way
    /// out rather than on the way in.
    private static func isWellFormed(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
