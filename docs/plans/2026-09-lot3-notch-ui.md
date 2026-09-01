# Lot 3 — The notch interface

Follows lot 1 (dictation core, `0fc59ff`, suite 127/127) and lot 2 (modes + LLM refinement). Base
branch `feat/murmure-v1`.

Spec: §6 (UI — Notch), §9 (Error handling), §12 (open item "DynamicNotchKit API fit").
Design reference: `docs/design/ui-design-notes.md`, §3 (the recording window and its relation to
Murmure's state model), §2 (visual system), §8 (anti-goals), §9 (what could not be determined).

Out of scope, and stated so: settings window, history, vocabulary, file/YouTube, onboarding,
a mode-switcher overlay. Lot 3 gives Murmure exactly one new surface — the notch — and makes the
warnings lot 1 and lot 2 already produce visible somewhere other than a menu nobody opens.

---

## 1. What this lot delivers

Today a dictation is invisible: a 16 pt menu-bar glyph changes shape, and every warning
(`clipboardWarning`, `lastFailureMessage`, `modeProblems`, `refinementNotice`, `hotkeyUnavailable`)
waits in a menu that is only read by someone who already suspects something went wrong. During a
`Prompt` dictation the app is silent for a median 19 s and up to 57.5 s (lot 2 measurements) with
nothing on screen saying it is alive.

At the end of this lot: pressing the hotkey grows the notch itself into a live surface that stays
one continuous shape from the first waveform bar to the green flash, hovering it gives Stop and
Cancel, and a failure keeps the text where it can be pasted again.

---

## 2. The root-component constraint, and how it is held

> **The notch is the ROOT component, not a window glued under it.** It morphs continuously; it
> never opens a window and never resizes in jumps. (Louis, non-negotiable; spec §6 "Interaction
> model — continuous morphing".)

This is held by three mechanical facts, not by intent:

1. **One window per dictation, whose frame is never changed after creation.** DynamicNotchKit's
   `DynamicNotchPanel` is a borderless `.nonactivatingPanel`, `backgroundColor = .clear`,
   `hasShadow = false`, `level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces,
   .stationary]` (`DynamicNotchPanel.swift:20-31`). It is sized **half the screen**, anchored
   top-centre, once, in `initializeWindow` (`DynamicNotch.swift:354-395`), and `setFrame` is never
   called again. Every state of Murmure happens *inside* that fixed transparent canvas.
2. **The visible shape is a SwiftUI mask that follows its content.** `NotchView` masks a black
   rectangle with `NotchShape`, sized by `fixedSize()` on the content and animated with
   `.animation(.smooth, value: [compactLeadingWidth, compactTrailingWidth])`
   (`NotchView.swift:60-90`). Changing what we draw in the wings changes the shape *by animation*,
   with no window involved. This is the morphing engine, and it is free.
3. **The six dictation phases live in ONE DynamicNotchKit state.** `recording`, `transcribing`,
   `refining`, `inserting` and the completion flash are all rendered in the `.compact` state, at a
   **constant wing width**, with only the drawing inside crossfading. The library's
   `compact()`/`expand()` calls — the only thing that can produce a discontinuity — are used
   exactly twice per dictation: once to appear, once for the hover/failure panel.

**Consequence for idle: the notch is hidden, i.e. there is no window at all.** Keeping the panel
alive in `.compact` with empty wings would draw a black band of
`notchSize.width + 2 × topCornerRadius` = 185 + 12 = **197 pt** against a 185 pt physical cutout
(`NotchView.swift:32-40`, spec §6 measured geometry) — a 6 pt black tab on each side of the notch,
visible over a light menu bar. Idle costs zero pixels, which is also what spec §6 asks for
("Idle: nothing — the notch is a notch") and what design notes §3.1 observed of Superwhisper's
resting pill ("idle is inert and near-invisible").

### Flow

```
 DictationSession (actor, MurmureCore)          NotchModel (@MainActor, app)
 idle → recording → transcribing                        │
        → [refining] → inserting                        │
        → completed(insertedCharacters:) → idle         │
        └ failed(message:, recoveredText:)              │
                     │                                  │
     onStateChange (@Sendable) ──► DictationController ──┤
                                   AppState (menu)       │
                                                         ▼
   AudioRecorder ── RMS per 100 ms ──► AudioLevelMeter ─► NotchPresenter.phase(...)   [MurmureCore, tested]
   (app, audio thread)                 (MurmureCore)              │
                                                                  ▼
                                                      NotchContent (SwiftUI, app)
                                                       ├ compactLeading  ┐
                                                       ├ compactTrailing ┤ DynamicNotch 1.1.0
                                                       └ expanded        ┘ (one instance, built at launch)
```

`NotchModel` is deliberately **not** `AppState`: the waveform publishes ~20 times a second, and
every `@Published` change on `AppState` re-evaluates `MurmureApp.body`, which draws the menu-bar
scene (`MurmureApp.swift:38-40`). Two observable objects, two refresh rates.

---

## 3. Decisions, with their evidence

| # | Decision | Evidence | Where it can be revisited |
|---|---|---|---|
| D1 | **Depend on DynamicNotchKit, pinned `1.1.0`.** No custom NSPanel clone. | Spec §12 left this open. Read at the tag: `compactLeading`/`compactTrailing` are exactly the "waveform wings on both sides" the spec asked for (`NotchView.swift:106-140`), `hasNotch` derives the notch from `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` as spec §6 demands (`NSScreen+Extensions.swift:19-33`), MIT licence confirmed on the repo. **Tag 1.1.0 is byte-identical to `main` for all six files this plan depends on** (diffed 2026-09-01). | If T1's build fails, or if a state needs geometry the library refuses — fork is legal (MIT) and the whole package is ~1 200 lines |
| D2 | **`transitionConfiguration.skipIntermediateHides = true`.** | The default is `false` (`DynamicNotchTransitionConfiguration.swift:51`), and with it every compact↔expanded conversion animates to `.hidden`, sleeps 0.25 s and animates back (`DynamicNotch.swift:196-210`, `250-265`). That is the "resized by jumps" anti-model, shipped as a default. | never |
| D3 | **All in-dictation phases are DNK `.compact`, at a constant wing width.** Only `hover` and `paste-failure` call `expand()`. | (2) above: within `.compact`, the shape follows the wing widths through `.smooth`. Two calls per dictation is the minimum a library with three states can be asked to do. | — |
| D4 | **Idle = `hide()`, no window, no hover target.** No "always show" toggle in this lot. | 197 pt band vs a 185 pt cutout (§2). Design notes §3.4 recommends an *Always show* toggle for no-notch hardware, and §3 anti-copy #3 recommends defaulting it **off** on notch hardware. A toggle needs a settings window, which is a later lot. | when the settings window exists |
| D5 | **The notch does NOT take over mode selection.** It displays the active mode name in the hover panel, read-only; picking a mode stays in the menu (lot 2). | `updateHoverState` is guarded by `state != .hidden` (`DynamicNotch.swift:159`): at idle there is no window, so there is nothing to hover *before* you speak — which is the only moment choosing a mode is useful. Design notes §3 ("What Murmure has to solve"): Superwhisper's Mini shows no mode at all and solves mode identity with a global `⌥⇧K` overlay, not with the recording chrome. | a switcher-overlay lot |
| D6 | **No mode colour dot in the collapsed recording state.** The waveform is the entire recording signal. | Design notes §3.2, measured on the installed app: "no label, no timer, no red dot… This validates the spec's waveform wings as sufficient on its own. Do not add a status word." **Contradicts spec §6** ("mode colour dot"), which is also unimplementable as written: `Mode` has no `color` and no `icon` field (`Mode.swift:45-54`), a gap design notes §6.4 already flagged. | if Louis asks for it, it costs a schema field + a migration, i.e. a lot-2 change |
| D7 | **Add `case completed(insertedCharacters: Int)` to `DictationSession.State`.** | Today the success path and the *silence* path both end in `.idle` (`DictationSession.swift:169-176`; `PasteInserter.insert` returns early on empty text, `PasteInserter.swift:88-91`, and `SpeechGate` makes empty a routine outcome). A green flash driven by `.idle` would therefore congratulate Louis for a dictation that inserted nothing. Spec §6 asks for a `done` state; the code never had one. | — |
| D8 | **Add `DictationSession.cancel()`; it stops the recorder, keeps the WAV, transcribes nothing.** No confirmation dialog. | Design notes §3 anti-copy #2: "Mini has no Stop and no Cancel… Murmure's hover state must fix that, not inherit it." No confirmation because the audio is already on disk while recording (spec §4, `WavWriter`) and spec §7 makes it a recoverable history entry — nothing is destroyed, so **spec §6's "confirm if > 30 s" guards nothing**. | if lot 4 decides cancel should delete the file |
| D9 | **Cancel is a button in the hover panel, not a global `esc` hotkey.** | Registering `esc` globally would take Escape from every app; registering it only while recording is a second hotkey lifecycle in a lot that has none of its own. Design notes §3 anti-copy #2 says the *visible* affordance is the fix, and the shortcut is what Superwhisper got wrong. | a hotkeys lot, together with push-to-talk |
| D10 | **Notch fill is pure black, no stroke.** The `#242423`/`#525251` pill of design notes §2 is not copied. | Those values describe a pill *next to* the notch, which is why it needs a stroke to exist. Ours *is* the notch: any fill other than black leaves a visible seam against the hardware cutout, which is precisely the flaw spec §6 records about Superwhisper's Mini. | — |
| D11 | **Two type sizes (~13 pt regular/semibold, ~11 pt muted) and one accent colour used only for state.** | Design notes §2 "Typography": the whole installed app runs on two sizes and a muted/bright contrast, with no display size anywhere; "the accent is reserved for state, not for buttons" (§5). Anti-goal §8: no sampled brand colours — Murmure picks its own hue. | the accent hue is Louis's to pick (Q-NB2) |
| D12 | **Waveform scale floors at RMS 0.005.** | `SpeechGate.energyThreshold` — measured over Louis's 1 482 real dictations as the level below which a 100 ms frame is not voiced. Reusing it means the waveform is flat exactly when the gate would reject, so what he sees predicts what he gets. | — |
| D13 | **No test bundle is added to the `Murmure` target.** All lot-3 logic lands in `MurmureCore`; the views stay in the app and are proven by Louis's eye only. | The app target links WhisperKit, AVAudioEngine, Carbon and CGEvent; a host-app test bundle would prove a SwiftUI view renders, not that a notch aligns with a cutout. The reducer split (T2) gives the same coverage for none of the cost. | — |
| D14 | **The menu keeps every warning it shows today.** The notch adds a surface; it removes none. | The notch is transient by construction (D4): a warning shown only there is a warning shown for 4 s. `AppState.modeProblems`' own doc comment ("a warning that disappears on the next press is a warning he never finishes reading", `AppState.swift:48-53`). | — |
| D15 | *(no evidence — judgement)* **Refining shows an elapsed counter only after 5 s.** | Nothing measured says 5 s. The reasoning: at the 3.17 s median of a short refinement a number would flash and vanish; at 57.5 s the only question is whether the app is alive. Mark as arbitrary and tune it by use. | first use |
| D16 | *(no evidence — judgement)* **Hover expands only after a 300 ms dwell.** | The pointer crosses the notch every time it travels to the menu bar, and an expansion on every crossing would be unbearable. 300 ms is a guess, isolated in one constant and testable as a policy. | first use |

---

## 4. Where the spec is wrong, and where the design notes disagree with it

Reported rather than silently resolved — this happened twice in the previous lots and both times the
spec was the stale document.

1. **Spec §6's state list is stale.** It says `idle → recording → processing → done → hover →
   paste-failure`. The real machine is `idle → recording → transcribing → [refining] → inserting →
   idle/failed` (`DictationSession.swift:47-52`). "Processing" is **two** phases that must look
   different: transcription is seconds, refinement is 19 s median and 57.5 s worst (lot 2). And
   `done` does not exist in code — D7 adds it.
2. **Spec §6's "mode colour dot" is unimplementable and, per the notes, wrong.** See D6.
3. **Spec §6's "confirm if > 30 s" guards nothing.** See D8.
4. **Spec §6's hover panel lists "shortcuts to History / Settings".** Neither surface exists before
   lots 4+. Lot 3 ships the panel **without** those two buttons rather than with two dead ends.
5. **Spec §12's fallback clause is closed, in the library's favour.** "If DynamicNotchKit can't
   express the waveform-wings layout, fall back to a custom NSPanel clone" — it can; see D1.
6. **Design notes §9 is the honest list of what nobody has seen**, and three entries bear directly
   on this lot: the Mini window while *recording*, while *processing* and while *completing* were
   never captured. There is **no reference for anything after the first second of a dictation.**
   Everything in T4 is Murmure's own design, and the notes say so ("Processing and done… are
   entirely our design — there is nothing to study here").

---

## 5. Tasks

Each task ends with a commit. `swift test` in `MurmureCore/` must stay green (127 tests before this
lot, plus what each task adds); the app builds with `xcodebuild`.

**Manual gates are Louis's, not an agent's.** Launching Murmure registers a global hotkey and
pastes into whatever is focused; an agent running the app on this machine would type into his real
desktop. Every "eye" line below is a line he runs.

---

### T1 — The dependency, and one window that appears and disappears

**Delivers.** DynamicNotchKit `1.1.0` in `project.yml`; a `NotchController` (`@MainActor`, app
target) owning exactly **one** `DynamicNotch` built at launch and never rebuilt (its content views
are `let`-captured at init, `DynamicNotch.swift:76-79` — a new state means new *data*, never a new
notch); `compact()` when `AppState.status == .recording`, `hide()` otherwise; a placeholder wing.
Sets `skipIntermediateHides = true` (D2) and `hoverBehavior = [.keepVisible, .increaseShadow]`
(dropping `.hapticFeedback`, which fires on a surface the pointer crosses by accident).

Screen resolution is decided here and used by every later task: the target screen is captured
**once per dictation, when the recording starts**, as `NSScreen.main ?? NSScreen.screens[0]`, and
passed explicitly to every `compact(on:)`/`expand(on:)` call — the library's own defaults are
`NSScreen.screens[0]` (`DynamicNotch.swift:173`, `219`), which is the display with the origin, not
the one Louis is typing on.

**MurmureCore proves.** Nothing. This task is integration only, and saying otherwise would be a lie.

**Only the eye proves.** That a black band appears at the notch on the hotkey and leaves on the
second press; that it sits on the cutout and not beside it; that nothing about lot 1/2 behaviour
changed.

**Done when.** `xcodebuild` succeeds with the 14.0 deployment target (`onGeometryChange`, which DNK
uses unguarded, type-checks at `-target arm64-apple-macos14.0` on this toolchain — verified
2026-09-01; if the real build disagrees, bump the target to 15.0, which costs nothing on a Mac
running macOS 26), and Louis confirms appear/disappear.

---

### T2 — `NotchPhase` + the two state-machine changes it needs

**Delivers.** The whole of this lot's logic, with no visible change beyond the placeholder now
following every phase.

In `MurmureCore`:
- `DictationSession.State.completed(insertedCharacters: Int)` (D7), entered on the success path and
  on the empty-transcript path, immediately followed by `.idle`. The session holds no timer: how
  long a flash lasts is the UI's business.
- `DictationSession.cancel()` (D8): stops the recorder, keeps the file, returns to `.idle` without
  transcribing; a no-op unless the state is `.recording`.
- `NotchPhase`: `hidden | recording | transcribing | refining | inserting | completed(inserted:) |
  nothingHeard | failed(message:, recoveredText:) | alert(...)`.
- `NotchPresenter`: a **pure** reducer `(previous state, new state, warnings, isHovering, startedAt,
  now) → NotchPhase`, plus the display strings (elapsed `m:ss`, the "after 5 s" rule of D15, the
  300 ms dwell of D16) as pure functions over an injected clock.

In the app: `NotchModel` publishes the phase; `DictationController`'s existing `onStateChange` hop
feeds it. `AppState` gains `recoveredText: String?` from the `.failed` payload, which it currently
drops (`DictationController.swift:96-98` keeps only the message).

**MurmureCore proves.** ~20 tests: every transition maps to the phase it should; a completion with
0 characters is `nothingHeard` and **not** a green flash; a failure carries its recovered text; a
cancel from `.recording` reaches `.idle` without calling the transcriber; a cancel from any other
state does nothing; elapsed formatting; the dwell and the 5 s rules at their boundaries.

**Expect 3 existing tests to fail** — `DictationSessionTests` asserts exact sequences
(`[.recording, .transcribing, .inserting, .idle]` at line 274, and the refining variant at 384).
Updating them *is* the proof the new state is really emitted; if they stay green, the change did not
take.

**Only the eye proves.** Nothing. This is the one task in the lot that is fully closed by tests.

---

### T3 — Audio level, and the waveform wings

**Delivers.** `AudioRecorder` measures RMS on the audio thread inside the existing `TapSink` lock
(no new allocation on the happy path — the constraint `AudioRecorder.swift` already documents),
splitting each 4 096-frame buffer into 100 ms sub-blocks so the level updates at ~20 Hz rather than
at the 11.7 Hz of one value per buffer. Levels are **pulled** by the UI, not pushed: a lock-guarded
box the view samples, so a stalled main thread can never back up the audio thread.

In `MurmureCore`: `AudioLevelMeter` (RMS → 0…1 bar height, log scale floored at
`SpeechGate.energyThreshold`, D12, with attack/release smoothing) and `LevelHistory` (a fixed-capacity
ring buffer). Both pure.

The recording phase renders the bars **mirrored across the two wings, at a fixed wing width** —
amplitude changes bar heights only, never the width of the shape (design notes §3: the Mini pill is
a fixed pill with ~9 centred bars; and a shape that breathes with the voice would make every
subsequent transition unreadable).

**MurmureCore proves.** Silence maps to the floor and not to zero-height; a full-scale buffer maps
to 1; an empty buffer yields no NaN; smoothing is monotonic and bounded; the ring buffer drops the
oldest sample and never grows.

**Only the eye proves.** That the bars are legible at 32 pt of notch height, that they track his
voice with no perceptible lag, and that they do not shimmer when he is silent.

---

### T4 — The collapsed sequence: transcribing → refining → done → nothing heard

**Delivers.** The four phases after the recording, all in `.compact`, **all at the wing width T3
fixed**, so every transition is a crossfade of content inside a shape that does not move:
- `transcribing` — a travelling indeterminate mark across both wings.
- `refining` — visibly different from transcribing (the whole point: 19 s median), with the elapsed
  counter appearing after 5 s (D15). One accent hue, used here and nowhere else (D11).
- `completed(inserted > 0)` — a brief green fill, then the shape retracts into the notch. This is
  Murmure's replacement for a macOS notification (spec §6); no `UNUserNotification` is ever posted.
- `nothingHeard` — a distinct, quiet retraction with no green. Louis must be able to tell "I said
  nothing that got through" from "it worked", which today's code cannot express at all (D7).

`inserting` is not given its own appearance: it lasts one CGEvent round-trip.

**MurmureCore proves.** Nothing new — T2 already pins which phase is produced when. What T4 adds is
drawing.

**Only the eye proves.** All of it, and this is the task with no reference anywhere: design notes §9
records that the Mini window was never captured while recording, processing or completing. Judge
against one criterion — **at no point does the shape jump.**

---

### T5 — The hover dashboard

**Delivers.** Hover during a dictation (after the 300 ms dwell, D16) calls `expand(on:)`; leaving
returns to `.compact`. Content, following design notes §3 ("the *content* reference is the Classic
bar — left = identity/status/mode, right = Stop then Cancel — but the *reveal* mechanic is ours"):
active mode name and current phase on the left, elapsed time, **Stop** then **Cancel** on the right.
No History and no Settings buttons (§4.4). No mode switcher (D5).

**MurmureCore proves.** The dwell policy and the elapsed string (already in T2); that `cancel()` from
`.recording` discards without transcribing (T2).

**Only the eye proves.** That the expansion reads as a growth of the same surface and not as a
popover; that a pointer merely travelling to the menu bar does not trigger it; and the one thing
that could break dictation itself — **that clicking Stop or Cancel does not steal focus from the
target app.** `DynamicNotchPanel` is `.nonactivatingPanel` but overrides `canBecomeKey` to `true`
(`DynamicNotchPanel.swift:29-31`), and `canBecomeKey` cannot be overridden from outside the library.
Reasoned, not observed: gate it by clicking Stop mid-dictation in TextEdit and checking the text
still lands.

---

### T6 — Everything that can go wrong, made visible

**Delivers.** The failure surfaces, in the expanded panel:
- **Paste failure** (spec §9): the panel keeps the text with **Re-paste** and **Copy**. Re-paste
  reuses `DictationController.repasteLast()`, which already exists and already routes through the
  single `PasteInserter` (so the clipboard-restore consumer stays unique). It persists until
  dismissed — this is the one phase that must not retract on a timer.
- **Accessibility denied** (spec §9, and the one box `MurmureApp.swift:19-27` explicitly leaves
  unticked): checked at launch *and* at the start of each dictation; shown as an alert phase, with a
  click that opens
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. Checked at
  dictation start too, because permission can be revoked while the app runs and the launch check
  would then be a lie.
- **Hotkey unavailable**: shown once at launch. Without the hotkey no dictation can start, so the
  notch would otherwise never appear to say so.
- **Refinement notice** and **clipboard warning**: attached to the completion of the dictation they
  belong to, not to the next one — they are already cleared on the next `.recording`
  (`DictationController.swift:82-92`).
- **Mode problems**: menu only. They survive across dictations by design
  (`AppState.swift:48-53`), which is exactly the shape a transient surface cannot carry (D14).

**MurmureCore proves.** Precedence: which phase wins when a dictation both fails to paste *and*
reports a clipboard loss; that an alert never masks a `failed` carrying recoverable text.

**Only the eye proves.** That the deep link opens the right pane; that the recovered text is
readable and actually re-pastes.

---

### T7 — External display, no notch, and the hostile cases

**Delivers.** The fallback path and the hardening.

- **Mac without a notch / external display.** `hasNotch` is false → DNK selects `.floating`, and
  `NotchlessView` draws the expanded content as a floating card below the menu bar
  (`NotchlessView.swift:30-48`). **The library refuses `compact()` on a floating screen — it calls
  `hide()` instead** (`DynamicNotch.swift:226-229`). So on such a screen every phase must be
  rendered through `expand()`, with a small pill-shaped content. Accept DNK's floating chrome
  (a `.popover` material card with a 20 pt inset) for V1 and say so plainly: it is a card, not a
  pill, and it will not look like the notch path. Forking the 57-line `NotchlessView` is the escape
  hatch, and the trigger for taking it is Louis actually working on an external display often
  enough to care.
- **Screen changes.** DNK re-initialises its window on
  `didChangeScreenParametersNotification` but always on `NSScreen.screens.first`
  (`DynamicNotch.swift:146-150`), regardless of which screen we asked for. Our controller observes
  the same notification and re-asserts the current phase on the screen it chose.
- **Full screen.** `collectionBehavior` is `[.canJoinAllSpaces, .stationary]` — no
  `.fullScreenAuxiliary` (`DynamicNotchPanel.swift:26`). If the notch does not draw over a
  full-screen app, the fix is one line on the public `windowController.window`, re-applied after
  each show (the panel is recreated per appearance).
- **Wake from sleep** and **Space switches**: re-assert on `NSWorkspace.didWakeNotification`.

**MurmureCore proves.** Nothing — every line of this task is AppKit behaviour on real hardware.

**Only the eye proves.** The matrix in §8.

---

## 6. Technical risks

| Risk | Why it is real | What to do |
|---|---|---|
| **Focus theft breaks the paste** | `canBecomeKey` is `true` on the panel and cannot be overridden from outside (`DynamicNotchPanel.swift:29`). Insertion targets `NSWorkspace.frontmostApplication`; if a click on Stop changes it, the dictation is inserted into nothing. | T5 gate. If it happens: make the panel non-interactive during the phases that precede insertion, and act on hover-release rather than on click |
| **The notch does not draw over full-screen apps** | No `.fullScreenAuxiliary` in the collection behaviour. Louis dictates into a terminal that may well be full screen. | T7; one-line mitigation identified |
| **Multi-screen: the library fights our screen choice** | `observeScreenParameters` hard-codes `screens.first`; `expand`/`compact` default to `screens[0]`. A display plugged mid-dictation can move the surface. | Pass the screen explicitly everywhere (T1), re-assert on the notification (T7). Ordering against DNK's own handler is racy and cannot be made deterministic from outside — this is a "verify by unplugging a monitor" item, not a provable one |
| **Audio-thread regression** | T3 adds work inside the `os_unfair_lock` the tap block already holds, on the thread `AudioRecorder`'s doc comment guards against priority inversion. | RMS over the buffer is arithmetic on memory already in cache and allocates nothing; keep it inside the existing critical section rather than adding a second lock, and re-read that doc comment before touching it |
| **Menu redraw storm** | 20 Hz of level updates on `AppState` would re-evaluate the `MenuBarExtra` scene 20 times a second. | Separate `NotchModel` (§2). If the menu still stutters, sample the level in the view with `TimelineView` instead of publishing it |
| **Hover expansion on an accidental crossing** | The pointer crosses the notch on every trip to the menu bar. | 300 ms dwell (D16), tunable in one constant |
| **`keepVisible` never lets go** | `_hide` refuses to hide while hovering and retries every 0.1 s, spawning a Task each time (`DynamicNotch.swift:289-296`). A pointer parked on the notch keeps it on screen indefinitely. | Accepted: during hover the user is reading the panel. Worth knowing before it is called a bug |
| **A stale `.compact` after a failed press** | `DictationSession` ignores presses during the pipeline, but the notch is driven by a separate object; a dropped state change would leave a black band on screen with no dictation behind it. | The controller drives from `onStateChange` only, never from the hotkey, and `hide()` is idempotent. A watchdog is *not* being added — a band that outlives its dictation is a bug to fix, not to paper over |

---

## 7. Open questions

**Blocking — T1 cannot start without an answer**

- **Q-B1. Nothing.** Every question below can be answered while the code is being written, or after.
  This lot is unusual that way: the design constraint is stated, the library is verified, and the
  state machine is on disk.

**Non-blocking**

- **Q-NB1.** Design notes §9: the Mini window was never captured while recording, processing or
  completing, so T4 has **no reference at all**. Nothing more can be learned from the 94 captures —
  this is a design decision to make, not a measurement to take.
- **Q-NB2.** The accent hue is unpicked. Anti-goal §8 forbids reusing Superwhisper's blue. One hue,
  used only for `refining`; green for success is a system semantic, not a brand colour. Louis's call.
- **Q-NB3.** Light mode is undesigned territory — design notes §7 records that *neither* corpus ever
  showed it, and the installed app runs on `Auto`. The notch is black on a black cutout, so the
  collapsed states are unaffected; the expanded panel and the floating fallback are not. Proposal:
  ship dark-only in lot 3 and treat light mode as a later pass.
- **Q-NB4.** Does the hover panel need the elapsed time at all, given D6 removed the mode dot and
  design notes §3.2 observed that the installed app shows no timer anywhere? Cheap either way.
- **Q-NB5.** `Always show` (design notes §3.4) — deferred to the settings window (D4). It matters
  most on the no-notch path, where there is no hardware anchor.
- **Q-NB6.** Should `cancel()` delete the WAV? D8 says no because lot 4 makes it recoverable. If
  lot 4 decides a cancelled recording should not reach History, this becomes a two-line change.
- **Q-NB7.** Design notes §6.4 wants `icon`/`color` on `Mode`. D6 makes lot 3 not need them. If
  Louis wants the dot, it is a lot-2 schema change with a migration, not a UI tweak.

---

## 8. Acceptance — the recipe only Louis can run

Unit tests close T2 and the pure parts of T3 and T6. Everything else is this list, and no task above
is done until its line here is reported observed (spec §11, and Louis's own doctrine: unit tests
alone never close a feature).

1. Dictate through `Voice` into TextEdit. The notch grows, the waveform tracks the voice, the text
   lands, the flash is green. **Nothing about lot 1's behaviour changed.**
2. Dictate through `Prompt`. `transcribing` and `refining` are visibly different, and the 19 s wait
   never looks frozen.
3. Press the hotkey and immediately press again. `nothingHeard`, no green flash, no paste.
4. Hover mid-dictation: the panel grows out of the same shape. Click **Stop** — the text still lands
   in the target app (the focus-theft gate).
5. Hover mid-dictation, click **Cancel**: nothing is transcribed, nothing is pasted.
6. Move the pointer across the notch on the way to the menu bar during a dictation: no expansion.
7. Revoke Accessibility in System Settings, dictate: the alert appears and its click opens the right
   pane.
8. Force a paste failure (start a dictation, then close the target window): the panel keeps the
   text, and Re-paste puts it somewhere else.
9. Dictate into a full-screen app: the notch is visible.
10. Dictate with an external display attached, on each screen in turn; plug and unplug one
    mid-dictation.
11. Sleep and wake mid-dictation.
12. Read the shape through a whole `Prompt` dictation and answer one question: **did it ever jump?**

---

## T11 — Audio feedback (added 2026-09-01, from real use)

**Delivers.** A sound when recording starts, and a quieter one when the text is inserted.

**Why it was added, and why it outranks the visual work it follows.** Louis dictates on an
ultrawide external display. The status capsule is 260 pt on a 3440 pt screen, and his words were:
*"je suis obligé d'aller chercher si ça a démarré ou pas avant de commencer à parler."* No amount
of visual refinement fixes that — a small object on a very wide display is easy to miss by
construction, and the failure it causes is the worst one this tool has: he starts speaking before
the recorder is running and loses the front of his sentence. A sound removes the look entirely.
Superwhisper has had one from the start; this is the feature whose absence he noticed by using
ours, not by comparing feature lists.

**The trap, to be measured and not assumed.** The start sound plays through the speakers at the
instant the microphone starts capturing, so it can land in the WAV, reach Whisper as noise, or
trip `SpeechGate`. The ordering is a real decision. **Delaying capture to protect the recording is
the wrong trade**: Louis speaks as soon as he hears the sound, so audio lost to a delay is words
lost from the front of the dictation. If the two conflict, his voice wins and the sound adapts.

**MurmureCore proves.** When a sound fires and which one; that a failure never produces a start
sound; the ordering against capture. The `NSSound`/`AVAudioPlayer` call itself cannot cross.

**Only the ear proves.** Timbre, volume, and whether it is still tolerable on the fiftieth
dictation of the day — this fires every single time, so restraint is the design constraint.

**Explicitly out of scope** until asked: a sound for `nothingHeard` or for failures. An error
chime on a tool used all day is a different decision.
