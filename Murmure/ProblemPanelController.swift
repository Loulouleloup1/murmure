import AppKit
import MurmureCore
import SwiftUI
import os

/// The one surface in Murmure that takes clicks, and the only one that does not leave on its own.
///
/// **Why it is not the notch.** Every other surface of lot 3 is an indicator: it says what is
/// happening and retracts. This one makes an offer -- Re-paste, Copy, Open Settings -- and an
/// offer needs a button, a button needs a mouse event, and a mouse event is exactly what the two
/// existing surfaces refuse. That refusal is load-bearing rather than incidental: Murmure pastes
/// by sending ⌘V to `NSWorkspace.frontmostApplication`, so a window that took focus would swallow
/// the very keystroke the dictation depends on, and the notch's window cannot be made safe from
/// outside -- DynamicNotchKit's `DynamicNotchPanel` overrides `canBecomeKey` to `true`
/// (`DynamicNotchPanel.swift:29`) and draws its black through a `Rectangle().padding(-50)` inside
/// a panel half the screen wide (`NotchView.swift:58-62`), so making it interactive would also
/// hand it fifty points of invisible hit-testing in every direction across the menu bar.
///
/// So the recovery lives in a window Murmure owns end to end: `MurmureStatusPanel`, the class that
/// already carries `canBecomeKey → false`, `canBecomeMain → false` and `.nonactivatingPanel`, with
/// `takesClicks: true` flipping `ignoresMouseEvents` and nothing else. **What stops it becoming
/// key is the `canBecomeKey` override**, which AppKit consults before every `makeKey`: the window
/// cannot receive key status, so no click on it can move the keyboard, and `.nonactivatingPanel`
/// keeps the click from activating Murmure at the application level either. A click that lands on
/// the panel but not on a button reaches an ordinary SwiftUI background and does nothing at all --
/// `isMovableByWindowBackground` is false, so it cannot even be dragged.
///
/// **What that leaves unproven.** That the click reaches the button at all is AppKit behaviour on
/// real hardware and cannot be checked here: a window that never becomes key is served mouse
/// events all the same, and `acceptsFirstMouse` below is what stops the first one being eaten as
/// an activation click -- but only the eye proves it. That is why the menu keeps a working route
/// to both actions (`MurmureApp`): if a button ever fails to respond, the transcript is still
/// recoverable rather than lost, which is the one outcome this task exists to prevent.
///
/// It is placed under the floating strip, not over it: see `StatusSurfaceChoice
/// .standingTopMargin`. Both can be on screen at once, because a paste failure shows the strip for
/// `NotchPresenter.failureDwell` while this opens beneath it and stays.
@MainActor
final class ProblemPanelController {
    private let model = ProblemPanelModel()
    private var panel: MurmureStatusPanel?
    private let log = Logger(subsystem: "com.louiscourcier.Murmure", category: "problem-panel")

    /// The problem Louis waved away, kept so it does not come back until something changes.
    /// Which changes count is `FailureSurface.visible(problem:dismissed:)`, in the package.
    private var dismissed: StandingProblem?

    /// The acquisition failure Louis waved away, for the same reason and under the same rule: one
    /// click covers exactly the failure it was aimed at, and a *different* failure -- or the same
    /// one after it cleared -- opens the panel again. `AcquisitionProblem` is `Equatable` for this
    /// comparison and nothing else.
    private var dismissedAcquisition: AcquisitionProblem?

    /// Pastes a transcript again.
    ///
    /// Injected rather than done here, and that is the point of the injection: it runs through
    /// `DictationController`'s one `PasteInserter`, the same object the dictation itself used. A
    /// second inserter would be a second consumer of the clipboard-restore outcome, which
    /// `PasteInserter`'s required `onClipboardOutcome` exists to prevent.
    ///
    /// It takes the text rather than fetching it, so the button cannot deliver a dictation other
    /// than the one the panel is showing.
    private let repaste: (String) -> Void

    init(repaste: @escaping (String) -> Void) {
        self.repaste = repaste
        model.repaste = { [weak self] text in self?.repaste(text) }
        model.copy = { [weak self] text in self?.copy(text) }
        model.openSettings = { [weak self] url in self?.open(url) }
        model.dismiss = { [weak self] in self?.dismissCurrent() }
    }

    /// The standing problem changed, or there is none. The only entry point.
    func show(_ problem: StandingProblem?) {
        // The dismissal lapses as soon as the standing problem is anything else, so one click on
        // Ignorer can never silence a problem the panel has since stopped showing. `FailureSurface`
        // owns both halves of that rule so they cannot disagree about what "the same problem" is.
        dismissed = FailureSurface.dismissal(dismissed, given: problem)
        model.problem = FailureSurface.visible(problem: problem, dismissed: dismissed)
        refresh()
    }

    /// The acquisition failure, or what clears it (criterion 7).
    ///
    /// It enters through its own door rather than through `StandingProblem`, and that is a
    /// consequence of ownership rather than of taste: `StandingProblem` is lot 3's vocabulary for
    /// a dictation that did not reach its target, it lives in the package, and adding an
    /// acquisition case to it would make the core depend on the payload of one of its surfaces.
    /// What the two **do** share is the rule above: a dismissal covers the failure it was aimed
    /// at, and only that one.
    func showAcquisitionFailure(_ failure: AcquisitionProblem?) {
        dismissedAcquisition = failure == dismissedAcquisition ? dismissedAcquisition : nil
        model.acquisition = failure == dismissedAcquisition ? nil : failure
        refresh()
    }

    /// What is on screen, given both kinds of standing problem.
    ///
    /// **An acquisition failure takes the surface while it exists**, and the recovered dictation
    /// underneath is kept rather than overwritten: dismissing the failure brings the dictation
    /// back, which is the lot 3 invariant this panel exists for ("a transcript exists nowhere but
    /// in this one value"). The reverse cannot lose anything either -- a failure cannot be
    /// dismissed by the dictation arriving, because its dismissal is a click and nothing else.
    private func refresh() {
        // A boolean test rather than a binding: `AcquisitionPanelLayout.size` does not depend on
        // *which* failure is standing, so there is no value to carry here. The dismissal path is
        // the one that needs it, and it is the one that still binds it.
        if model.acquisition != nil {
            present(size: AcquisitionPanelLayout.size)
            return
        }
        if let problem = model.problem {
            present(size: StandingPanelLayout.size(for: problem))
            return
        }
        panel?.orderOut(nil)
    }

    private func present(size: CGSize) {
        // The focused window is deliberately NOT among the signals here, unlike
        // `StatusPanelController`'s. Reading it needs `AXIsProcessTrusted()`
        // (`focusedWindowFrame()`), and a denied Accessibility is the flagship reason this panel
        // opens at all -- on that case the best signal is unavailable by construction, so asking
        // for it would cost an Accessibility round-trip to be told nil. The pointer is where
        // Louis's hand is, which is where the buttons have to be.
        guard let screen = StatusSurfaceChoice.screen(
            among: NSScreen.screens.map(ScreenGeometry.init(_:)),
            focusedWindow: nil, mouseLocation: NSEvent.mouseLocation)
        else {
            log.error("no screen available -- the transcript is kept, the panel does not appear")
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        // Set before ordering in, so the panel is never seen at the previous problem's size for a
        // frame. Resizing a panel that is not on screen is not the notch's "never jumps" rule --
        // that rule is about a visible shape moving under something being read.
        panel.setFrame(
            StatusSurfaceChoice.frame(
                size: size, on: screen, topMargin: StatusSurfaceChoice.standingTopMargin),
            display: false)
        // `orderFrontRegardless()` for the reason `StatusPanelController` gives at length:
        // `orderFront(_:)` does not promise to show a window of an application that is not active,
        // and Murmure is `LSUIElement` and never active. Neither call can make a window key, and
        // `canBecomeKey` refuses the ones that could.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> MurmureStatusPanel {
        let panel = MurmureStatusPanel(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: StandingPanelLayout.width, height: StandingPanelLayout.alertHeight)),
            takesClicks: true)
        panel.contentView = ClickableHostingView(rootView: ProblemPanelView(model: model))
        return panel
    }

    // MARK: - What the buttons do

    /// Dismissing hides the panel and remembers what was hidden, so the same problem does not
    /// reopen on the next state change that recomputes it -- and a *different* one does.
    ///
    /// The acquisition failure is dismissed first when it is the one on screen, and the panel is
    /// then re-evaluated instead of being closed outright: the recovered dictation it was covering
    /// is still standing, and closing the panel would hide it without a dismissal of its own.
    private func dismissCurrent() {
        if let acquisition = model.acquisition {
            dismissedAcquisition = acquisition
            model.acquisition = nil
            refresh()
            return
        }
        dismissed = model.problem
        model.problem = nil
        panel?.orderOut(nil)
    }

    /// Copy is the recovery that survives a denied Accessibility, and the only reason it is beside
    /// Re-paste: without the permission `CGEvent.post` does nothing, so re-pasting cannot work and
    /// the clipboard is the only way the transcript leaves Murmure.
    ///
    /// `PasteInserter.copyToClipboard` is the one implementation, shared with the menu item that
    /// is this button's fallback; it says there why this write does not borrow. The panel stays
    /// open either way -- the offer is still standing whether or not the clipboard took it.
    private func copy(_ text: String) {
        PasteInserter.copyToClipboard(text)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// A hosting view that lets the first click through to what is under the pointer.
///
/// AppKit's default is that the click which brings an inactive window forward is consumed by that
/// activation and not delivered to the view -- so on a panel belonging to an application that is
/// *never* active, every click would be a first click and no button would ever fire. Returning
/// true is what makes a single click on Re-paste re-paste.
private final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not created from a nib") }
}

/// What the panel's view reads, and where its buttons go.
///
/// Deliberately not `AppState`: that object drives the menu-bar scene, and this one changes on a
/// failure rather than on a dictation.
@MainActor
final class ProblemPanelModel: ObservableObject {
    /// The dictation-shaped problem of lot 3.
    @Published var problem: StandingProblem?

    /// The acquisition failure of criterion 7, when there is one. Separate from `problem` for the
    /// reason `showAcquisitionFailure(_:)` gives, and read first by the view: the failure that has
    /// just happened is the one on the surface.
    @Published var acquisition: AcquisitionProblem?

    var repaste: (String) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
    var openSettings: (URL) -> Void = { _ in }
    var dismiss: () -> Void = {}
}

/// The panel's geometry when it shows an acquisition failure.
///
/// **Not in `StandingPanelLayout`**, and not because of tidiness: that enum is in the package, and
/// `AcquisitionProblem` is an app type -- giving the core a layout constant expressed in terms of
/// one of its surfaces' payloads would point the dependency the wrong way. The padding, the
/// headline height and the button row are borrowed from it, so the two contents line up.
enum AcquisitionPanelLayout {
    /// Eight lines of 10 pt monospace: enough to recognise the failure. **The copy is the whole
    /// block** -- what has to be complete is what leaves for the agent, not what is displayed.
    static let blockHeight: CGFloat = 104

    static let size = CGSize(
        width: StandingPanelLayout.width,
        height: StandingPanelLayout.padding * 2 + StandingPanelLayout.headlineHeight
            + StandingPanelLayout.blockSpacing + blockHeight
            + StandingPanelLayout.blockSpacing + StandingPanelLayout.buttonRowHeight)
}

/// The panel: what went wrong, the dictation it is holding, and what can be done about it.
private struct ProblemPanelView: View {
    @ObservedObject var model: ProblemPanelModel

    var body: some View {
        // Sized to the problem rather than to the largest of them, because this panel is placed
        // once per appearance and never resized while it is being read.
        let size =
            model.acquisition.map { _ in AcquisitionPanelLayout.size }
            ?? model.problem.map(StandingPanelLayout.size(for:))
            ?? CGSize(width: StandingPanelLayout.width, height: StandingPanelLayout.alertHeight)
        return VStack(alignment: .leading, spacing: StandingPanelLayout.blockSpacing) {
            // The same precedence `refresh()` in the controller decided: the failure that has just
            // happened takes the surface, and the dictation underneath comes back when it is
            // dismissed.
            if let acquisition = model.acquisition {
                acquisitionContent(acquisition)
            } else {
                switch model.problem {
                case let .recovery(recovery): recoveryContent(recovery)
                case let .alert(alert): alertContent(alert)
                case nil: EmptyView()
                }
            }
        }
        .padding(StandingPanelLayout.padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.92)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }

    /// The failure of criterion 7: what went wrong, the raw block that goes to the agent, and the
    /// one button that delivers it.
    ///
    /// The message is the panel's own sentence and the block sits under it in the monospace face,
    /// because it is machine output and not something to read as prose. It is shown bounded and
    /// **copied whole**: the panel only has to answer "is this the failure I just saw", while the
    /// clipboard has to carry everything the agent needs to get around it -- so truncating the
    /// display is safe in a way truncating the copy would not be. The block is selectable as well
    /// as copyable, because the pointer is already on it and a hand-picked fragment is sometimes
    /// what is wanted.
    private func acquisitionContent(_ acquisition: AcquisitionProblem) -> some View {
        Group {
            headline(
                acquisition.message, symbol: "exclamationmark.triangle.fill", tint: .orange)
            Text(acquisition.block)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(8)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: .infinity, minHeight: AcquisitionPanelLayout.blockHeight,
                    maxHeight: AcquisitionPanelLayout.blockHeight, alignment: .topLeading)
            HStack(spacing: 8) {
                action("Copier le rapport", isProminent: true) { model.copy(acquisition.block) }
                Spacer(minLength: 0)
                action("Ignorer") { model.dismiss() }
            }
            .frame(height: StandingPanelLayout.buttonRowHeight)
        }
    }

    private func recoveryContent(_ recovery: Recovery) -> some View {
        // The headline is orange, not red: `NotchCard.tint(for:)` gives every failure the warning
        // tint, and this panel is the same failure seen on the surface that can act on it.
        Group {
            headline(recovery.message, symbol: "exclamationmark.triangle.fill", tint: .orange)
            // The transcript, in the reading face rather than the interface one -- it is Louis's
            // sentence, not Murmure's label. Truncated at three lines: what the panel has to
            // answer is "which dictation is this", and the whole of it is what the buttons deliver.
            Text(recovery.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: .infinity, minHeight: StandingPanelLayout.transcriptHeight,
                    maxHeight: StandingPanelLayout.transcriptHeight, alignment: .topLeading)
            HStack(spacing: 8) {
                action("Recoller", isProminent: true) { model.repaste(recovery.text) }
                action("Copier") { model.copy(recovery.text) }
                Spacer(minLength: 0)
                // The clipboard's own bad news, when there is some. Second line rather than second
                // panel: `FailureSurface.standing` says why neither is dropped.
                if let note = recovery.clipboardNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                action("Ignorer") { model.dismiss() }
            }
            .frame(height: StandingPanelLayout.buttonRowHeight)
        }
    }

    private func alertContent(_ alert: AppAlert) -> some View {
        Group {
            headline(alert.message, symbol: "exclamationmark.triangle.fill", tint: .orange)
            HStack(spacing: 8) {
                // Both halves have to be there, and `AppAlertTests` pins that they always are: a
                // title with no destination is a control that does nothing.
                if let title = alert.actionTitle, let raw = alert.settingsURL,
                   let url = URL(string: raw) {
                    action(title, isProminent: true) { model.openSettings(url) }
                }
                Spacer(minLength: 0)
                action("Ignorer") { model.dismiss() }
            }
            .frame(height: StandingPanelLayout.buttonRowHeight)
        }
    }

    private func headline(_ message: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                // Two lines: `InsertError`'s descriptions are sentences, and on a 380 pt panel the
                // tail is not the disposable half it is on a 34 pt strip.
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(
            maxWidth: .infinity, minHeight: StandingPanelLayout.headlineHeight,
            alignment: .topLeading)
    }

    private func action(
        _ title: String, isProminent: Bool = false, perform: @escaping () -> Void
    ) -> some View {
        Button(title, action: perform)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isProminent ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isProminent ? Color.white : Color.white.opacity(0.12)))
            // Louis is aiming at a small target on a panel floating over his work, so the pointer
            // has to say which parts of it are targets at all -- nothing else on this window
            // responds to a click.
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
