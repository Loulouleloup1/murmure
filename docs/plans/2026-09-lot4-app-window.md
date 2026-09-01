# Lot 4 — The application window

Follows lot 1 (dictation core, `0fc59ff`), lot 2 (modes + refinement) and lot 3 (the notch, the
floating panel, the sounds — through `316ea54`). Base branch `feat/murmure-v1`.

Spec: §6 (UI — Settings window), §7 (Data & storage), §5 (Vocabulary), §2 (scope).
Design reference: `docs/design/ui-design-notes.md` — §1 (information architecture), §2 (visual
system), §8 (anti-goals), §9 (what could not be determined) — plus the 74 documentation screenshots
in `docs/design/superwhisper-ui/`, read for this plan and cited below as *doc corpus*.
Visual language: `MurmureCore/Sources/MurmureCore/NotchCard.swift`, `NotchAppearance.swift`,
`WaveformLayout.swift`, `StatusPanelLayout.swift`, `StatusPanelText.swift` and
`Murmure/NotchController.swift` — the values and the reasoning already shipped.

Out of scope, and stated so: onboarding, file and YouTube transcription, a mode-switcher overlay,
recording a new hotkey, the Home statistics dashboard, light mode. Each is named again in §4 with
the reason it is out.

---

## 1. What this lot delivers, and why there is nothing to extend

Murmure has **no application window at all.** Everything it draws today is transient: the notch card
and the floating panel appear for the length of one dictation and are gone. The only durable surface
is a `MenuBarExtra` menu, and lot 3 §1 already recorded what that menu is worth — it is read by
someone who *already suspects* something went wrong.

Three things in the spec therefore have nowhere to live:

- **History** (§7). `murmure.sqlite` does not exist. `~/Library/Application Support/Murmure/`
  holds 98 recordings and 451 MB of audio with **no index of any kind** — no transcript, no mode,
  no duration, nothing. Every dictation Louis has made with Murmure is unrecoverable text.
- **Vocabulary** (§5). Not started. Neither half exists: `Transcriber` has no `initialPrompt`
  parameter, and there is no find→replace step anywhere in `DictationSession`.
- **Modes** (§5). The files are real and hand-editable; the only interface is a list of radio
  buttons in the menu. Creating, editing, duplicating or deleting a mode means opening a text
  editor.

At the end of this lot: one window, opened from the menu, where a dictation from ten minutes ago can
be found by searching for a word in it, a mode can be edited without a text editor, and a term
Whisper keeps mishearing can be taught once.

---

## 2. The window's shape

### 2.1 One window with a sidebar

**Decision: a single resizable `Window` scene holding a `NavigationSplitView`, with six sections in
the sidebar.** Not a `Settings` scene, and not the two-window split Superwhisper uses.

The alternatives, and why they lose:

- **A SwiftUI `Settings` scene** gives `⌘,` for free and nothing else. It cannot be opened
  programmatically without a private selector whose name changed between macOS 13
  (`showPreferencesWindow:`) and 14 (`showSettingsWindow:`), and Murmure's menu is the *only* entry
  point there is — an entry point resting on a private selector is one that breaks on an OS update
  with no compile error. It is also not resizable, and History is the section that wants the size.
- **Superwhisper's split** — a fixed 750 × 500 settings window with red and yellow traffic lights
  only, plus a **separate, resizable History window with all three** (observed: the doc corpus's
  sidebar row for History carries an external-link ↗ glyph, and its History window shows a green
  traffic light where the settings window shows none). That split costs a second window lifecycle,
  a second frame to restore, and a second "where did my window go" for an app with no Dock icon. For
  one user on one machine, one window that resizes is strictly less machinery for the same result.

The window is named for the application, not "Settings" — because five of its six sections are
settings and the sixth, History, is the reason it gets opened.

### 2.2 The section order, and the tint that replaces the dividers

```
  History                  ← the reason the window exists      accent tile
  Modes                                                        accent tile
  Vocabulary                                                   accent tile
  ─── extra space ───
  Models                                                       neutral tile
  General                                                      neutral tile
  Advanced                                                     neutral tile
```

The grouping device is taken whole from design notes §2: **no divider rules, one extra gap, and an
icon-colour split where coloured = the user's own material and neutral = the app's machinery.** The
notes call it "a genuinely useful, cheap device for Murmure, whose settings surface will be
smaller", and it is exactly right here — six items, one break, no headings.

The hue is Murmure's own (anti-goal §8 forbids the sampled `#3478F6` / `#7675E4`): the violet 292°
already in `NotchAppearance.accentHue`. Reusing it is not thrift, it is the point — a window whose
accent differed from the notch's would be a second visual language, which the brief rules out and
which would be a worse outcome than a plain window.

Spec §6 lists the sidebar as `General · Modes · Models · Vocabulary · History · Advanced`. That order
is wrong twice: it puts History last, where it is the most-opened section, and it puts it beside
"Advanced" as though it were a setting. See §4.1.

### 2.3 The window chrome

Following design notes §1.4, and departing from it in one place:

- **No page titles.** The installed app has deleted page-level heading prose entirely (§1.4);
  only "Modes" survives, at body size. Murmure has none: each pane opens straight onto its content.
- **A per-section header row**, ~46 pt, closed by a hairline — a contextual toolbar, not a titlebar.
  History and Models get a search field in it. The others get nothing on the left.
- **Departure:** the installed app pins the *microphone selector* into the header of every
  non-list section, which the notes call "a good call: the one setting you might need mid-session
  never requires navigation". Murmure's equivalent is not the microphone, it is **the active mode** —
  that is the setting that decides whether what he is about to say goes through an LLM, and
  `AppState.activeMode` already exists for exactly that reason (`AppState.swift:31`). Put the mode
  in the header instead; keep the microphone in General.
- **Two type sizes and a muted/bright contrast**, no display size anywhere (design notes §2
  "Typography"). This is the same rule `NotchCardView` already follows at 14 pt semibold rounded.
- Corner radii in three tiers — large surfaces 14–16 pt, interactive rows 10–11 pt, chips ~5 pt.

### 2.4 `LSUIElement`, and what it costs a real window

Murmure is `LSUIElement: true` (`project.yml`): activation policy `.accessory`, no Dock icon, no
⌘Tab entry, **and no displayed main menu bar**. Four consequences, in order of how much they matter:

1. **Nothing gets the window back except the menu-bar item.** An accessory app is not in ⌘Tab. Once
   the window is behind Xcode it is gone until Louis clicks the menu-bar glyph. That is survivable —
   the glyph is always there — but it makes the menu item mandatory, and it makes "front the
   existing window" mandatory: a second press must never open a second window.
2. **`NSApp.activate()` is required before `makeKeyAndOrderFront`**, or the window appears without
   keyboard focus and the first thing typed goes to the previous app.
3. **The standard editing key equivalents may not fire.** ⌘C / ⌘V / ⌘A / ⌘Z in an `NSTextField` are
   dispatched through `NSApp.mainMenu`, and an accessory app draws no menu bar. Whether SwiftUI still
   installs a functioning `mainMenu` for a `MenuBarExtra`-only app on macOS 26 **could not be
   determined without launching the app, which this lot's agents may not do.** A vocabulary field or
   a mode-instructions textarea that cannot paste is not a small defect — the instructions of the
   `Message` and `Email` modes are 400-character prompts nobody types by hand.
4. Closing the window must not terminate the app.

**Recommendation — the plist does not change; the runtime policy does.** Raise to
`NSApp.setActivationPolicy(.regular)` when the window opens and drop back to `.accessory` when it
closes. That buys a real menu bar (hence the Edit menu, hence ⌘V), a Dock icon and a ⌘Tab entry for
exactly as long as the window is up, and costs nothing at idle — which is where Murmure spends
99.9 % of its life. Superwhisper's own answer is the same shape: its Advanced pane carries a
**"Show in Dock" toggle** (observed, doc corpus), i.e. the policy is a runtime setting there too.

This is Q-B1 in §7 and it is the one blocking question, because T1 either flips the policy or it
does not and every text field in the lot depends on the answer.

---

## 3. Decisions, with their evidence

| # | Decision | Evidence | Where it can be revisited |
|---|---|---|---|
| D1 | **One resizable `Window` scene with a sidebar.** Not `Settings`, not two windows. | §2.1. The `Settings` scene cannot be opened without a private, version-dependent selector, and Murmure's menu is the only entry point. | if History ever wants to be open *beside* the settings, which is a two-window problem and nothing else |
| D2 | **`LSUIElement` stays; the activation policy flips to `.regular` while the window is open.** | §2.4. The window carries four multi-line text fields; ⌘V has to work, and the Edit menu is what makes it work. Superwhisper ships the same choice as a "Show in Dock" toggle. | Q-B1 — Louis's call, and T1 must observe the ⌘V behaviour either way |
| D3 | **History is the first sidebar section, and the window is named for the app.** | It is the section with a reason to be opened daily; the other five are opened when something changes. Spec §6 lists it fifth of six (§4.1). | — |
| D4 | **The accent is `NotchAppearance.accentHue` (292°), reused, not re-picked.** | Lot 3 D11 and the anti-goal in design notes §8. A window with a second accent would be a second interface. The hue itself is still a placeholder answering lot 3's Q-NB2. | Q-NB4 — one constant, both surfaces |
| D5 | **SQLite stays, via GRDB, pinned exactly.** MurmureCore's first dependency. | §5. FTS5 setup, schema migration and record mapping are the three parts that are fiddly by hand; hand-rolling the sqlite3 C API to avoid a dependency is the opposite of the simple general solution. `exactVersion`, for the reason `project.yml` already gives DynamicNotchKit. | Q-B2 — the alternative is priced in §5.3 |
| D6 | **`refinedText` is NULL when no refinement ran, never a copy of the raw transcript.** | Lot 2's no-op guard exists because "output identical to input is the documented failure mode of a too-small model". Storing a copy would make that indistinguishable after the fact from a mode that never refines, and the Raw/Refined lens would show two identical panes for `Voice`. | — |
| D7 | **The audio path is stored relative to `recordings/`, never absolute.** | The folder moves the day `Storage` changes, and an absolute path in a database row survives nothing. It is also the only form a test can resolve against a temporary directory. | — |
| D8 | **`outcome` is a stored value, not derived from `insertedCharacters > 0`.** | This is lot 3 D7 again, one layer down: `inserted`, `nothingHeard`, `failed` and `cancelled` are four different things, and the last two are not distinguishable from a character count. Collapsing them is the exact mistake lot 3 had to add a state to undo. | — |
| D9 | **History is two panes — list and detail — not the doc corpus's three.** | The corpus's third pane is a metadata inspector (observed) whose rows are largely things Murmure does not have: cloud voice model, separate-speakers, system-audio, tier, app version. What survives is about six rows, which fits under the transcript. The installed app has itself moved off three panes (design notes §1.3). | if the metadata grows past what fits |
| D10 | **The history row shows date · time · duration, against the installed app.** | Design notes §1.3, measured: the installed app's card "renders **only** the transcript excerpt. No timestamp, no duration, no mode name". That is wrong for Louis — his median is 29.7 s and 21.9 % run past 60 s, and two dictations about the same subject five minutes apart are told apart by *when* and *how long*. The doc corpus's own row is the better one: one truncated line of text, then a second line with date · time and a right-aligned duration. Take the corpus's row and the install's date-header grouping. | — |
| D11 | **Two lenses on a record — Raw and Refined — not the corpus's three.** | The corpus's switch is `Voice / Segments / AI` (observed). `Segments` needs WhisperKit's per-segment timings, which nothing stores and the spec never asked for. A record whose mode had no refiner shows **no switch at all** rather than a disabled one. | if a segment view ever earns its keep |
| D12 | **"Process again" in this lot means re-refine only, never re-transcribe.** | The raw transcript is already stored, so a re-refine is one Ollama call against a mode the user picks — cheap and useful (it is how a dictation refined by the wrong mode gets fixed). Re-transcribing needs a WhisperKit model load, a progress surface and a reachable engine from the History pane, which is `DictationController`'s whole surface area exported into a view. Spec §2 says "re-processing" without saying which. | Q-NB1 |
| D13 | **Vocabulary is ONE list, word → optional replacement — not two lists.** | Design notes §1.2, confirmed on the installed app: "one list serves both 'bias the recogniser' and 'fix this word afterwards'… worth keeping as one list, not two". It matches spec §5 exactly, and it means a term is taught once rather than entered twice. | — |
| D14 | **The modes list glyph is derived, not stored.** Microphone for a transcribe-only mode, sparkles for a refining one. | Design notes §6.4 wants `icon` on the mode schema and calls its absence "a gap in the spec". True — but the *useful* half of Superwhisper's row is the stage readout, which the notes also say: "one badge for STT-only, two for STT + refinement, so the daily-driver Voice mode is visually distinct". That is derivable from `llm.enabled` and costs no schema field, no migration and no picker. | Q-NB5 — if Louis wants per-mode icons it is a lot-2 schema change |
| D15 | **The menu keeps everything it shows today.** The window adds a surface; it removes none. | Lot 3 D14, unchanged and for the same reason: `modeProblems` survives across dictations by design (`AppState.swift:54-60`), and a warning that only exists in a window nobody has open is a warning nobody reads. The window gains a *second* home for them, in Modes, beside the file that is broken. | — |
| D16 | **No test may create or write anything under `~/Library/Application Support/Murmure/`.** Enforced by removing the ability, not by remembering. | §5.4. `StorageTests.testAppSupportDirectoryIsCreated` **already violates this today** — it calls `Storage.appSupportDirectory(subfolder: "recordings")`, which creates directories, in Louis's real folder. It is harmless while the folder exists and it stops being harmless the moment a test opens a database there. | — |
| D17 | *(no evidence — judgement)* **The window does not open at launch, ever.** Only the menu item opens it. | Murmure is a hotkey that pastes text. A window at launch would be a window at every login. Nothing measured says so; it is the register the whole app is in. | first use |
| D18 | *(no evidence — judgement)* **Dark only, as lot 3 shipped.** | Lot 3 Q-NB3, unresolved: "neither corpus ever showed light mode", and the installed app runs on `Auto`. The notch got away with it because black on a black cutout is theme-free. **A window does not get away with it** — this is the surface where the deferral starts to cost something, and the honest statement is that it is deferred again, not that it is solved. | Q-NB6 |

---

## 4. Where the spec is wrong, out of date, or contradicts itself

Reported rather than silently resolved. Every lot has found real errors here and this one is no
exception; items 4, 5 and 7 are **live defects in shipped code**, not documentation drift.

1. **§6's sidebar order is wrong.** `General · Modes · Models · Vocabulary · History · Advanced`
   buries the only section with a daily reason to be opened, and lists it as a peer of "Advanced" —
   as though the archive of everything Louis has dictated were a preference. See D3.

2. **§7's "History UI: three panes" is stale.** It describes the doc corpus, which is older than the
   installed app; the install has moved to a list with drill-in (design notes §1.3). And the third
   pane's contents do not survive the trip to Murmure — see D9.

3. **§7's "No auto-purge in V1; manual 'clear history' button only" is not a retention policy.**
   Measured on this machine, today: `recordings/` holds **98 files and 451 MB**, i.e. ~4.6 MB per
   dictation. At the rate of the real corpus — 1 469 dictations — that folder reaches **~6.8 GB**.
   A manual button is a perfectly good answer for the *text* (a few MB, and Louis will never want to
   delete it) and a bad one for the *audio*. Superwhisper's own Configuration carries a
   `Keep recordings for` popup (design notes §4). The two have to be separable. Q-B3.

4. **§5's vocabulary cannot be implemented without changing the transcription seam — and the same
   change fixes a live bug.** `Transcriber` is `transcribe(wav: URL) async throws -> String`
   (`DictationSession.swift:13-15`): no language, no initial prompt. `WhisperKitEngine` hard-codes
   `private static let decodeOptions = DecodingOptions(language: "fr")`
   (`WhisperKitEngine.swift:86`). So **`Mode.stt.language` and `Mode.stt.model` are decoded,
   validated with named errors, documented as hand-editable — and then ignored.** A mode file that
   says `"language": "en"` transcribes French, silently, with the model the engine chose. The code
   knows: `WhisperKitEngine.swift:84` reads *"Lot 2 owes this a per-mode `stt.language` seam
   (spec §5)"*. Lot 2 did not build it. Lot 4 must, because `initialPrompt` travels the same road.

5. **§5's text replacements do not exist and the spec does not say whose job they are.**
   "case-insensitive find→replace applied after transcription, before the LLM" — `finishRecording()`
   goes `transcriber.transcribe` → `refined(transcript)` with nothing in between
   (`DictationSession.swift:177-190`). The placement matters and the spec is right about it: before
   the refiner, which puts the step in `DictationSession` or behind `DictationRefining`, **not** in
   the engine. Note the consequence the spec does not state: the replacement runs on the raw
   transcript, so the *stored* raw transcript is post-replacement. Say which one is stored (see §5.2).

6. **§7's storage list has no room for the vocabulary or for the app's own settings.** It names
   `modes/`, `murmure.sqlite`, `recordings/`, `models/` and stops. Two new things need a home, and
   they should not get the same one: settings belong in `UserDefaults` (which `ModePreference`
   already uses, with an injectable domain — `AppState.swift:72`), and the vocabulary belongs in a
   hand-editable `vocabulary.json` beside `modes/`, for the reason the modes are JSON at all.

7. **§6's onboarding is a fourth window and is not in this lot.** "1. Microphone permission →
   2. Accessibility permission → 3. default STT model download with progress → trial dictation."
   Every piece it needs lands here — the permission checks, the model list with sizes and a delete
   action, the reachability probe — but the sequenced first-run flow itself is a separate window
   with a separate lifecycle. Deferred, deliberately, and named so it is not forgotten.

8. **§12's open item "Superwhisper UI screenshot pass happens at implementation start" is closed**
   and should be struck: both capture sets exist, and `docs/design/ui-design-notes.md` is the
   distillation.

9. **§6's own settings section calls the window "Settings window"** and then lists History inside
   it. The name and the contents disagree. See D3.

### What was dropped from Superwhisper's information architecture, and why

Their navigation is shaped by features Louis has permanently ruled out, so the structure is taken and
the feature set is not.

| Dropped | Why |
|---|---|
| **Meeting mode preset** (observed in their create-mode picker and their preset dropdown) | Spec §2: meeting mode is permanently out. Murmure's picker has four presets and no fifth. |
| **Speaker separation / `diarize`, system audio / `useSystemAudio`** (observed as rows in their history inspector and as keys in their on-disk modes) | Spec §2, permanently out. Design notes §8: "do not carry the schema keys 'just in case'." |
| **Activation by website** (observed: an `e.g. example.com` field and an "Add website" button in their mode's advanced screen) | No browser integration in scope (design notes §6). Murmure keeps app activation and drops the field entirely — not disabled, absent. |
| **Home / statistics dashboard** | Design notes §1: it exists to solve a retention problem Murmure does not have. It is also the section whose data is *cheapest once History exists*, so it is a later lot if Louis wants it, not a lost cause. |
| **Sound as its own section** | Theirs holds mic conditioning (auto-gain, silence removal, dynamic normalisation, mute-audio-while-recording) plus a three-way effects picker and a volume slider. Murmure has exactly two sounds (lot 3 T11) and no conditioning. Three rows in General, not a section. |
| **Licence / tier / trial footer, provider avatars, padlock overlays, "Create custom" model, API-key button** | Design notes §8: all of it exists to gate cloud features. Murmure has none. |
| **The `Cloud/Offline` column** in a models table | Everything is local. It collapses to size + one action that flips between download and delete. |
| **The `Voice / Segments / AI` three-way lens** | D11. |
| **A right-click menu on the recording pill** (observed: *Expand window / Open Settings… / Open History…*) | Murmure's notch card is `ignoresMouseEvents = true` at the window level and `allowsHitTesting(false)` in SwiftUI (`NotchController.swift:50-58`, `389`), deliberately, so that nothing it covers ever loses a click. It cannot take a right-click without giving that up. The menu-bar item is the entry point. |

---

## 5. Storage

### 5.1 Does SQLite still hold? Yes.

The spec's call was made before there was any data. There is now: 1 469 real dictations in the
corpus, 98 in Murmure's own folder in two days. Search is the feature — Louis dictates medium-length
technical French with English terms, and "where did I say that thing about the connector" is the
question History exists to answer. A file-per-dictation store means a linear scan over ten thousand
files; FTS5 means an index. SQLite holds.

### 5.2 The schema

One table, one FTS index. Every column below is something the code either already has or is named in
§5.4 as a change to make.

```sql
CREATE TABLE dictation (
  id                   INTEGER PRIMARY KEY,
  startedAt            TEXT    NOT NULL,   -- ISO 8601, UTC
  durationSeconds      REAL    NOT NULL,   -- of the recording, not of the pipeline
  outcome              TEXT    NOT NULL,   -- inserted | nothingHeard | failed | cancelled  (D8)
  modeKey              TEXT    NOT NULL,
  modeName             TEXT    NOT NULL,   -- denormalised on purpose, see below
  sttModel             TEXT    NOT NULL,
  llmModel             TEXT,               -- NULL when the mode had no refiner
  rawTranscript        TEXT,               -- NULL when nothing was transcribed
  refinedText          TEXT,               -- NULL when no refinement ran            (D6)
  insertedCharacters   INTEGER NOT NULL,
  targetBundleID       TEXT,
  targetAppName        TEXT,
  audioFilename        TEXT,               -- relative to recordings/                (D7)
  transcriptionSeconds REAL,
  refinementSeconds    REAL,
  failureMessage       TEXT                -- the message the notch showed
);

CREATE INDEX dictation_startedAt ON dictation(startedAt DESC);

CREATE VIRTUAL TABLE dictation_fts USING fts5(
  rawTranscript, refinedText, content='dictation', content_rowid='id',
  tokenize="unicode61 remove_diacritics 2"
);
```

Four points that are decisions and not defaults:

- **`modeName` sits beside `modeKey`.** Modes are hand-edited JSON files that can be renamed,
  rekeyed or deleted. A row that can only say `modeKey = "prompt"` for a file that no longer exists
  is a row that cannot be read. Superwhisper's own inspector shows the mode as a stored value, not
  as a link (observed).
- **`remove_diacritics 2`.** Louis dictates French. Searching for `cle` must find `clé`, and
  searching `réglé` must find `regle`. This is one tokenizer option and it is the difference between
  a search that works and one that requires the right accent.
- **`rawTranscript` is stored post-replacement**, because that is what the refiner was handed and
  therefore what the mode actually saw (§4.5). If Louis ever wants the pre-replacement text, that is
  a second column and a decision to take deliberately — not a thing to leave ambiguous.
- **`failureMessage`** exists so that a failed dictation is a readable row rather than a row that
  merely says it failed. Lot 3 T6 already keeps the message and the recovered text alive in
  `AppState`; this is where they stop evaporating.

Location: `~/Library/Application Support/Murmure/murmure.sqlite`, exactly as spec §7 says — a
sibling of `modes/`, `recordings/` and `models/`.

### 5.3 GRDB, and what it costs

`MurmureCore` has **zero dependencies** today (`Package.swift`), and that is worth something.
GRDB is the first, and it should be pinned `exactVersion:` for the reason `project.yml` already gives
DynamicNotchKit — a minor bump that changed migration or FTS behaviour would move the data layer
without a line of Murmure changing.

The alternative, priced honestly: `import SQLite3` is available with no dependency at all, and the
whole store is one table. What it costs is ~150–200 lines of C-API wrapper — prepared statements,
`sqlite3_finalize` on every path including the throwing ones, `SQLITE_BUSY` handling, and the FTS5
external-content triggers written by hand. That is the fiddly 20 % of the work, done once, badly,
by us. Louis's own doctrine is "privilégier les solutions générales et simples", and the general
simple solution here is the library everyone uses. Q-B2 all the same, because it is his dependency.

### 5.4 Nothing a test writes may land in the real folder

This is the hard constraint of the lot and it is **already being violated**:

```
MurmureCore/Tests/MurmureCoreTests/StorageTests.swift:6
    let url = try Storage.appSupportDirectory(subfolder: "recordings")
```

`Storage.appSupportDirectory` calls `createDirectory(withIntermediateDirectories: true)` on
`~/Library/Application Support/Murmure/<subfolder>` (`Storage.swift:5-12`). The test creates it. It
is harmless today only because the folder already exists and holds 451 MB of Louis's recordings —
and it stops being harmless the instant a test written in the same shape opens a database there.

Three rules, and T2 exists to make them mechanical rather than remembered:

1. **`Storage` splits in two.** A pure `url(subfolder:) -> URL` that computes and creates nothing,
   and an explicit `directory(subfolder:) throws -> URL` that creates. `StorageTests` asserts the
   *path* against the pure one and touches the disk nowhere.
2. **Every store takes its location as an init parameter, with no default.** The precedent is
   already in the repo and it is good: `ModeStore(directory:)` has no convenience initializer, and
   `ModeStoreTests` writes into `NSTemporaryDirectory()` with a comment saying exactly why
   (`ModeStoreTests.swift:11-12`). `HistoryStore(databaseURL:)` and `VocabularyStore(fileURL:)`
   follow it. A `HistoryStore()` that defaulted to the real path would compile at every call site
   and be wrong at exactly one — which is the argument `DictationRefining` already makes about
   defaults that hide a decision.
3. **The real path is resolved once, in `DictationController`**, and handed down — the same shape
   `modesDirectory` already has (`DictationController.swift:89-96`).

### 5.5 No backfill

The 98 orphaned WAVs get no history rows. Their filenames carry a timestamp
(`rec-2026-08-31T18-07-26.799Z.wav`) and the files carry a duration, but **the transcript exists
nowhere** — and design notes §1.3 is right that "the transcript is the identity of the row". A
backfill would produce 98 rows with a date, a duration and no identity. The empty-history state says
what happened instead (T9), and the folder is Louis's to delete.

---

## 6. Tasks

Each task ends with a commit. `swift test` in `MurmureCore/` must stay green — **356 `func test…`
declared before this lot** (counted statically, not run: the suite as it stands calls
`Storage.appSupportDirectory` and therefore touches Louis's real folder, which is what T2 fixes) —
plus what each task adds. The app builds with `xcodebuild`.

**Manual gates are Louis's, not an agent's** (lot 3 §5, unchanged). Launching Murmure registers a
global hotkey and pastes into whatever is focused. Every "eye" line below is a line he runs.

**On "MurmureCore proves".** Lot 3's plan wrote *"MurmureCore proves. Nothing"* for T1 and was
wrong — 21 tests later covered it. The estimates below are deliberately concrete, and a task that
finds more is not a task that misplanned.

---

### T1 — The window, the menu item, and what the accessory policy actually does

**Delivers.** A `Window` scene with a `NavigationSplitView`: the six sidebar sections of §2.2, each
with its tile, its tint and an empty pane. A `WindowController` (`@MainActor`, app target) that
fronts the one window rather than opening a second, calling `NSApp.activate()` before
`makeKeyAndOrderFront`. A menu item in `MurmureApp`'s `MenuBarExtra`, `⌘,`. The activation-policy
flip of D2, behind one function, so that reverting it is one line. Frame and selected section
restored across launches via `UserDefaults` — with the **injectable domain `AppState` already
uses** (`AppState.swift:72`), never `.standard` from a test.

**MurmureCore proves.** More than it looks. A `WindowSection` enum carrying order, title, SF Symbol
and the material/machinery split — pinned so that a section added later cannot silently land in the
wrong group or inherit a blank symbol, which is the guarantee `NotchCard.symbolName(for:)` already
makes for phases. The restoration codec: a stored section name that no longer exists resolves to
History rather than to nothing; a stored frame off every attached screen is refused. Roughly 12
tests.

**Only the eye proves.** Four things, and the third is the one that decides D2:
that the window appears in front and takes the first keystroke; that the menu item fronts the
existing window instead of opening a second; **that ⌘V pastes into a text field in the window**;
that closing the window does not quit Murmure and a dictation still works afterwards.

**Done when.** Louis confirms all four, and the answer to Q-B1 is recorded in this file.

---

### T2 — `Storage` loses the ability to write where a test must not

**Delivers.** The split of §5.4: `Storage.url(subfolder:)` pure, `Storage.directory(subfolder:)`
creating, every existing caller moved to the right one. `StorageTests` rewritten to assert the path
and create nothing.

**MurmureCore proves.** That `url(subfolder:)` returns the expected suffix and that calling it
leaves the filesystem untouched — asserted by pointing it at a subfolder name that does not exist
and checking it still does not. That `directory(subfolder:)` creates, against a temporary base.
About 6 tests.

**Only the eye proves.** Nothing. This one is fully closed by tests, and it is first because
everything after it writes.

---

### T3 — `HistoryRecord` and `HistoryStore`

**Delivers.** GRDB pinned in `Package.swift` and `project.yml`; the schema of §5.2 as a
`DatabaseMigrator` migration; `HistoryStore(databaseURL:)` with insert, fetch-page, search,
delete-one, clear-text, clear-audio. No convenience initializer (§5.4 rule 2).

**MurmureCore proves.** The bulk of the lot's testable surface, ~30 tests: a round-trip of every
column including the nullable ones; `refinedText` staying NULL for an unrefined dictation and never
becoming a copy (D6); an accent-insensitive and case-insensitive search hitting both the raw and the
refined column; a search term that appears only in the refined text still matching; ordering by
`startedAt` descending with a stable tie-break; the migration applied to an empty file and then
re-applied as a no-op; a relative `audioFilename` resolving against two different bases and never
against an absolute path; deleting a row leaving the WAV alone; `clear-audio` leaving the rows;
`clear-text` leaving the WAVs; the FTS index staying in step after a row is deleted; a database file
that is corrupt surfacing as a named error rather than a crash.

**Only the eye proves.** Nothing.

---

### T4 — A dictation writes a row

**Delivers.** The pipeline reports what it did. `DictationSession` keeps the raw transcript beside
the refined text rather than overwriting it (`finishRecording` currently keeps only
`lastTranscript = text`, `DictationSession.swift:189`); records the wall-clock spent transcribing
and refining; captures the frontmost application at **recording start**, not at insertion — the app
Louis was looking at when he spoke, by the same argument `activeMode` is resolved there
(`DictationSession.swift:110-118`). A `DictationRecording` protocol seam so the session stays
testable with no database, in the shape `DictationRefining` already established.

**MurmureCore proves.** ~18 tests. One record per dictation and never two; `outcome == .inserted`
with the right character count; the empty-transcript path producing `.nothingHeard` with a row, a
duration and no text; a failure producing a row carrying its message and its recovered text; a
`cancel()` producing `.cancelled` with the WAV path and no transcript — the WAV is kept
(lot 3 D8, and `DictationSession.swift` says lot 4 is what makes it recoverable, so this is that
promise being kept); a refinement that failed still storing the raw transcript.

**Expect the existing sequence assertions to need updating.** `DictationSessionTests` pins exact
state sequences; a new seam that the session calls on completion changes what a test double sees.
Updating them *is* the proof the record is really emitted — if they stay green untouched, the
change did not take. (Lot 3 T2 made the same call and was right.)

**Only the eye proves.** Dictate three times, open History, count three rows with the right modes.

---

### T5 — The History pane

**Delivers.** The two-pane surface of D9. Left: a search field in the section header (design notes
§1.4 — the header *is* the search field for a list section), muted date-group headers outside the
cards, and two-line rows — one truncated line of transcript, then date · time with a right-aligned
duration (D10). Selection is a ring, not a fill. Right: the transcript, a Raw/Refined lens when
there is a refinement to switch to (D11), a metadata block, and the actions — Copy, Reveal audio,
Play, Delete, Process again (re-refine only, D12).

An invented row, to fix the shape without touching real content:

```
  Aujourd'hui
  ┌────────────────────────────────────────────────────────────┐
  │ Ceci est une phrase inventée pour illustrer une ligne…     │
  │ 1 sept.  14:42                                      38 s   │
  └────────────────────────────────────────────────────────────┘
```

**MurmureCore proves.** More than a view usually can, because none of the below is drawing.
Date grouping against an **injected clock** — today, yesterday, and a date, with the boundary tested
at local midnight and not at UTC midnight. The row's preview string: single-line collapsed the way
`StatusPanelText.oneLine` already collapses a failure message, truncated at the tail. Duration
formatting across the range Louis actually produces — sub-minute (`38 s`), the 29.7 s median, and
the 478.9 s outlier that must read as `7 min 59 s` and not as `479 s`. The search query builder,
including what an empty query and a query of only punctuation do. Which lens a record offers.
The metadata rows a record yields, and that a record with no `llmModel` yields no language-model
row rather than an empty one. ~25 tests.

**Only the eye proves.** That a thousand rows scroll without stutter; that French with English
technical terms is legible at the chosen size; that search feels instant on the real database; that
a 400-word refined transcript is readable in the detail pane rather than a wall.

---

### Found in flight, and owed to the tasks that come after

Written down when it was found rather than left in a report, because each of these is a trap for a
specific later task and none of them is visible from the code that will hit it.

**For T5 — the Raw/Refined lens has a one-invisible-character trap.** `OllamaChat.verdict(on:)`
trims the model's answer (`OllamaChat.swift:328`), while the transcript reaches storage byte for
byte — lot 1 pins that deliberately, and its test fixture is literally `"  bonjour   Murmure\n"`.
So a transcript with whitespace at its edges and a refinement that changed nothing else differ
**only at the edges**: `refinedText` is stored, and the lens offers two panes that look identical.
T4 was right not to trim in `storedRefinement` — what is stored must stay exactly what was pasted —
so the fix belongs to T5 and it is a split: **the rule that decides whether to OFFER the lens
compares the two texts trimmed; the rule that decides what to STORE compares them exactly.**

**For T9 — three surfaces that now have nothing behind them.**

- `HistoryStore` names a corrupt database as an error, and no screen shows it.
- A dictation whose row failed to write is silent; the dictation itself still succeeded, which is
  the right priority, but the archive is then quietly incomplete.
- `DictationSession.cancel()` writes a `.cancelled` row and **has no caller in the app**. The path
  is tested and unreachable in real use — lot 3 T5 (the hover dashboard with Stop/Cancel) is what
  would reach it, and that task is blocked on `ignoresMouseEvents`. Either a later task gives cancel
  a caller or the row type is aspirational; say which rather than leaving it ambiguous.

**Nobody's task yet — the retention decision has no mechanism.** `clearText` and `clearAudio` exist
and have no caller, so the 30-day / 3-day rule Louis decided on 2026-09-01 is at present a sentence
in a document. It is deliberately not smuggled into T3 or T4; it needs its own task, with the
scheduling question answered (at launch? on a timer? on the window opening?) and a test that proves
a row older than the window is actually cleared while a younger one is not.

**Known and not guarded: the duration comes from `Date`.** An NTP correction mid-dictation writes a
wrong `durationSeconds`. A monotonic clock would fix it; T4 declined to add an untested guard, which
is the right call, and this is the note that stops it being forgotten.

---

### T6 — Vocabulary, and the transcription seam that makes it possible

**Delivers.** The seam first, then the feature.

- `Transcriber` becomes `transcribe(wav:language:initialPrompt:)`. `WhisperKitEngine` stops
  hard-coding `DecodingOptions(language: "fr")` and builds its options per dictation. **This closes
  §4.4** — `Mode.stt.language` starts being honoured for the first time, which is a behaviour change
  and must be called out in the commit: a hand-edited mode that says `"en"` will now do something.
  The default stays `"fr"`, and `WhisperKitEngine.swift:63-85`'s measured argument for pinning it
  stays true and stays in the file.
- The find→replace step, placed **after transcription and before the refiner** (§4.5), in
  `DictationSession`.
- `VocabularyStore(fileURL:)` over a hand-editable `vocabulary.json` beside `modes/` (§4.6).
- The pane: one input row committing two ways (a term, or a term and its replacement), a flat
  alphabetical two-column list with no card and no dividers, delete revealed on hover (design notes
  §1.2).

**MurmureCore proves.** ~22 tests. The initial-prompt string built from N terms, and what happens at
Whisper's 224-token prompt budget — terms are dropped, deterministically, from the end, and the
rule is stated rather than discovered. Replacements: case-insensitive matching that preserves the
replacement's own casing; whether a replacement applies inside a longer word (decide and pin it —
a term like `DCG` must not fire inside `ADCGX`); that no replacement is applied to the output of
another, so ordering cannot change the result; that a term with no replacement contributes to the
prompt and nothing else; that the empty vocabulary produces `nil` and not an empty prompt string.
Round-trip of the store, and a malformed `vocabulary.json` reported and skipped rather than fatal —
the shape `ModeStore` already uses.

**Only the eye proves.** Dictate a term Whisper currently mishears, add it, dictate it again.

---

### T7 — Modes: the list, the editor, the advanced screen

**Delivers.** Three surfaces, in the ladder the doc corpus shows and the notes endorse
(basic → advanced):

- **The list.** One card per mode: the derived glyph (D14), the name, a small dot on the mode that
  is currently active, and a trailing stage readout — one badge for a transcribe-only mode, two for
  a refining one. A `+` to create, from a preset picker whose entries are Murmure's four built-ins
  plus Custom, and no Meeting.
- **The editor**, as an inline in-place expansion of the row with a disclosure chevron (observed in
  the doc corpus; the installed app was never captured, design notes §5). Name, language,
  instructions, the two model fields.
- **An Advanced sub-screen**, pushed over the pane with a back chevron and the sidebar left in
  place (observed): auto-activation apps, the context trio, `simulateKeypresses`, and the `api`
  discriminator.

Plus a "Reveal modes folder" button — design notes §6 closes on exactly this: Application Support is
more correct than their `~/Documents`, "but it does hide them; a 'Reveal modes folder' button
somewhere in Settings would recover the affordance."

**MurmureCore proves.** ~20 tests, most of them already half-written as `ModeValidationError`.
That each of the ten validation cases maps to the field it should be shown against, so an error
appears under the input that caused it rather than in a banner. That saving from the editor writes
JSON `ModeStore.loadAll()` reads back identically — the round-trip is the whole contract, because
the file is also hand-edited. That renaming a mode's *name* does not move its file and renaming its
*key* does, and that the old file is not left orphaned. That the stage-badge count is 1 for
`llm.enabled == false` and 2 otherwise. That an `api: .s1` mode refuses prose in `instructions`
before it can be saved — `Mode.swift:225-227` already refuses it, and the editor must surface that
refusal rather than let it fail at dictation time, because the measured consequence is Superwhisper's
words appearing inside Louis's text.

**Only the eye proves.** That a mode edited in the window and a mode edited in a text editor read as
the same object; that the advanced screen pushes and pops as a slide and not as a sheet.

---

### T8 — Models, General, Advanced

**Delivers.** The three machinery sections.

- **Models.** A table, not a card stack — design notes §1.1 calls this "the single most transferable
  new idea" and it is right: name, a type glyph (speech vs language model, drawn not written), size
  on disk, and **one action column that flips between download and delete**. The Whisper models come
  from `models/` (1.5 GB there today); the Ollama side is a reachability probe reusing lot 2's
  `OllamaFailure` classification, so "Ollama isn't running" and "the model isn't pulled" stay two
  different sentences.
- **General.** The hotkey shown as keycap chips (18 × 18 pt for a glyph, wider for a word key, one
  chip per key, never a concatenated string — design notes §2). **Displayed, not recorded**:
  capturing a new binding is a second hotkey lifecycle and belongs with push-to-talk in a hotkeys
  lot. Microphone picker, launch on login, the two sound toggles from lot 3 T11.
- **Advanced.** Paste behaviour, restore clipboard after paste, simulate keypresses — the exact card
  the doc corpus shows (observed) and the exact three spec §6 asks for. Plus reveal-folder buttons
  and the two clear-history actions of Q-B3.

**MurmureCore proves.** ~15 tests. The settings model's round-trip through an injected `UserDefaults`
domain. The keycap decomposition of a `KeyCombo` into chips — `KeyCombo` already exists and is
already tested, so this is a rendering rule over it. The model-list rows derived from a directory
listing, including a partially-downloaded model that must not read as installed. The Ollama probe's
outcome classification. The clear-history confirmation policy: which of the two actions needs one,
and what each says it will destroy.

**Only the eye proves.** That a toggle flipped here changes the next dictation; that a model deleted
here is gone and the app says so before the next recording rather than during it.

---

### T9 — The empty states, the broken states, and the warnings that finally have a home

**Delivers.** Every path where there is nothing to show or something is wrong:
an empty history (and it says the 98 orphaned recordings exist, §5.5, rather than implying nothing
ever happened); an empty vocabulary; a database that will not open; a row whose WAV has been deleted
underneath it — Play and Reveal disabled, the text still there, because the text is the row; a
`vocabulary.json` that will not parse; and **`AppState.modeProblems` shown in the Modes pane, beside
the file that is broken**. That last one is the payoff of D15: the menu keeps the line, and the
window is where it can finally point at something.

**MurmureCore proves.** ~10 tests: which message each condition produces, and that a message naming
a file names the file. That a `HistoryStore` whose database will not open surfaces a named error and
the app still dictates — a broken archive must not cost a dictation, which is the same rule §9 of
the spec applies to the refiner.

**Only the eye proves.** That a corrupt database does not take the app down, and that the empty
history does not look like a bug.

---

## 7. Open questions

Every one is phrased so that a yes/no or a pick-one answers it.

### Answered, 2026-09-01

Louis handed the remaining calls over rather than answering them one by one ("tu es le chef
d'orchestre… si tu as besoin de moi pour valider quoi que ce soit tu reviens vers moi"), so these are
taken here and written down where the work can see them. Each is reversible; the two that were NOT
taken are held back deliberately, because they are matters of taste and this user has shown he has
opinions about them.

| | Answer | Why it was taken rather than asked |
|---|---|---|
| **Q-B1** | **Yes** — `.regular` while the window is open, back to accessory when it closes. | It is what makes ⌘V and ⌘Z work in the mode-instructions and vocabulary fields; the alternative is a text editor you cannot paste into. Behind one function (D2), so a bad result at T1's eye-gate reverts in a line. |
| **Q-B2** | **GRDB**, `exactVersion:`. | §5.3 already priced the alternative: ~200 lines of C-API wrapper and hand-written FTS5 triggers, written once, badly, by us. "Privilégier les solutions générales et simples" is his own rule and it points here. |
| **Q-B3** | **Already answered by Louis on 2026-09-01** — audio 3 days, text 30 days. See the retention section at the end of this file; it was never open. |
| **Q-NB1** | **Re-refine only.** | D12's recommendation. Re-transcribing needs the WAV, which after 3 days is gone — so the expensive variant is the one that stops working. |
| **Q-NB3** | **`vocabulary.json` beside `modes/`.** | Consistency with the modes, and it stays editable in Zed. A vocabulary is tens of entries, not thousands; the searchability the database would buy has no use to serve. |
| **Q-NB7** | **Left alone** (§5.5). | Their transcript exists nowhere, so a backfill produces rows with a date and no identity. |

**Deliberately still open, to be put to Louis when T1 lands, together:** **Q-NB4** (the window's
accent hue) and **Q-NB6** (light mode). Both are appearance, on the surface he will look at most, and
lot 3 showed that guessing his visual taste costs a rebuild.

**Still genuinely open and nobody's to take yet:** Q-NB2 (waveform scrubber) and Q-NB5 (per-mode icon
field) — both wait until there is a pane to judge them in.

**Blocking — T1 cannot finish without an answer**

- **Q-B1 (yes/no).** While the window is open, should Murmure become a normal app — Dock icon,
  ⌘Tab entry, a real menu bar — and go back to being invisible when it closes? It is what guarantees
  ⌘V and ⌘Z work in the mode-instructions and vocabulary fields. *Recommendation: yes.* (D2)
- **Q-B2 (pick one).** History storage: **GRDB**, pinned, as MurmureCore's first dependency — or
  hand-written SQLite3 with no dependency at all? *Recommendation: GRDB.* (D5, §5.3)
- **Q-B3 (pick one).** How long is the **audio** kept: forever (~6.8 GB at your measured rate), 30
  days, 7 days, or not at all — delete the WAV as soon as the transcript is stored? The text rows
  are kept forever in every case. *No recommendation: this is a trade between disk and being able to
  hear what Whisper misheard, and only you know which you want.* (§4.3)

**Non-blocking**

- **Q-NB1 (pick one).** "Process again": re-refine only, re-refine and re-transcribe, or neither in
  this lot? *Recommendation: re-refine only.* (D12)
- **Q-NB2 (yes/no).** Does a history row need an audio **waveform scrubber**, or is a play button
  and a plain position slider enough? The scrubber is real work — a 478 s recording has to be
  downsampled and drawn — with no payoff this plan can name.
- **Q-NB3 (yes/no).** Vocabulary as a hand-editable `vocabulary.json` beside `modes/`, the way the
  modes are? The alternative is a table in the database, which is searchable and which you cannot
  edit in Zed.
- **Q-NB4 (yes/no).** Keep the notch's violet 292° as the window's accent? Lot 3's Q-NB2 left the
  hue open and called it a placeholder. The window is where you will see it most, so this is the
  moment to change it if it is going to change. (D4)
- **Q-NB5 (yes/no).** Is a derived glyph enough for the modes list — microphone for transcribe-only,
  sparkles for refining — or do you want a per-mode `icon` field in the JSON? The field costs a
  schema change and a migration in lot 2's territory. (D14, design notes §6.4)
- **Q-NB6 (yes/no).** Light mode in this lot, or dark-only again? The notch got away with dark-only
  because it is black on a black cutout. A window does not. (D18)
- **Q-NB7 (yes/no).** Should the 98 orphaned recordings be offered a "transcribe these" action
  somewhere, or simply left as files for you to delete? *Recommendation: left alone; §5.5.*

---

## 8. What could not be determined

Stated rather than filled in, because a gap presented as an observation is worse than a gap.

**About Superwhisper's interface**

- **The installed app's mode editor.** Never captured (design notes §5 says so in as many words:
  "there is **no capture of the installed mode editor**"). Everything T7 takes about the editor comes
  from the doc corpus, which is older than the install and which the install contradicts elsewhere —
  their vocabulary input, for one, has a completely different commit affordance in the two corpora.
- **The installed app's History detail view.** Never captured (design notes §9). What a card opens
  into, and therefore every piece of per-dictation metadata the *current* app shows, is unknown. The
  doc corpus's inspector is the only reference and it is stale.
- **Whether History is a pane or a separate window in the installed app.** The doc corpus is
  unambiguous — the sidebar row carries an external-link ↗ and the History window has three traffic
  lights where the settings window has two — but design notes §1.4 describes the installed History
  as a pane whose search field lives in the shared window header. Both readings are in evidence.
  **I did not re-open the installed History captures to settle it**, because they contain Louis's
  real dictations, and the answer does not change D1.
- **The mode switcher overlay in the install.** Never captured. The doc corpus shows a card of rows,
  each a ⌘-number keycap, a mode name, an optional star and a trailing radio circle (observed);
  whether the install still looks like that is unknown. It does not matter here — Murmure has no
  switcher overlay in this lot.
- **How their search behaves.** No capture shows a search in progress. Prefix or substring, token or
  whole-string, whether it folds accents, whether it searches the raw text or the refined one,
  whether it filters the list or highlights within it — none of it is observable. Every search
  decision in T3 and T5 is Murmure's own.
- **Whether their history list paginates.** No capture shows a large history scrolled to its end.
- **Whether they confirm a delete**, and what the confirmation says.
- **Whether their window restores its size and its section across launches.**
- **Light mode.** Design notes §7: neither corpus ever showed it, every `--light.png` in the doc
  corpus is an Open-Graph logo card, and the install runs on `Auto`. There is nothing to study.
- **Configuration below `Keep recordings for`** (design notes §9). The capture ends mid-section.

**About Murmure**

- **Whether ⌘V works in a text field in an accessory app on macOS 26.** This is a fact about our own
  app and it cannot be settled without launching Murmure, which this lot's agents may not do. T1
  observes it; Q-B1 is the mitigation if the answer is no.
- **How fast FTS5 is on ten thousand rows of French.** Nothing here is measured. The design does not
  depend on it — SQLite indexes far larger corpora — but the claim "search feels instant" in T5 is a
  gate to run, not a fact already established.
- **How much of `refinementSeconds` is worth showing.** Lot 2 measured 19 s median and 57.5 s worst
  on the 12 B model, and lot 2's own notes measured 0.38 s median on `s1-mini`. Whether that number
  belongs in the detail pane, or only exists so that a slow model can be caught, is a use question.

---

## 9. Technical risks

| Risk | Why it is real | What to do |
|---|---|---|
| **A test writes into Louis's Application Support** | It happens today (`StorageTests.swift:6`, §5.4), and this is the lot that adds a database and 451 MB of audio to the same folder. A test that opened `murmure.sqlite` there would run migrations against his real archive. | T2 removes the ability rather than the habit: `Storage` splits, every store takes an injected URL with no default, `ModeStoreTests`' temp-directory pattern is the template |
| **⌘V does not work in the window's text fields** | §2.4. An accessory app draws no menu bar and the editing key equivalents are dispatched through it. Unverifiable without launching the app. | T1's third eye-gate. If it fails, D2's policy flip is the fix and it is one function |
| **The window steals focus from a dictation in flight** | The whole app is built on `NSWorkspace.frontmostApplication` being the target. Making Murmure `.regular` and key means Murmure *is* frontmost, and a hotkey pressed with the window focused would insert into the window. | Decide in T1 and pin it: either the hotkey is refused while Murmure is key, or the target app is captured at recording start and honoured regardless — T4 needs the second one anyway |
| **Mode files edited in two places at once** | `ModeStore` reads and writes JSON; so will the editor; and Louis edits the same files by hand. A window holding a stale mode in an editor will overwrite a hand edit on save. | T7: re-read on pane appearance the way the menu already does (`DictationController.refreshModes()`), and compare modification dates before writing. A silent overwrite of a hand-edited prompt is the one data loss in this lot that cannot be undone |
| **The `stt.language` seam changes behaviour** | T6 makes a field that has been ignored since lot 2 start working. A mode file already on disk that says something other than `"fr"` will change what it does, with no warning. | Check the four files on disk before shipping T6 and say in the commit message what changed. All four are built-ins today, so the blast radius is knowable |
| **GRDB's first migration runs against a file that already exists** | It will not on this machine — there is no `murmure.sqlite` — but the migration must be written as though it will, because the second one certainly will. | `DatabaseMigrator`, registered migrations, a test that applies them to an empty file and then re-applies them (T3) |
| **A 400-word refined transcript in a two-line row** | Louis's median is 29.7 s and 21.9 % run past 60 s. Truncation is the normal case, not the edge. | T5 pins the preview rule as a pure function with tests, the way `StatusPanelText` already collapses a failure message |
| **`recordings/` grows without a policy** | 4.6 MB per dictation, measured. Nothing deletes anything. | Q-B3, and T8 ships whichever answer he gives |
| **Six sections is five panes of scope creep** | Every settings pane invites one more row. | The sections are fixed in §2.2 and the drop list in §4 is explicit. A row not named in T8 is a row for a later lot |

---

## 10. Acceptance — the recipe only Louis can run

Unit tests close T2, T3, T4 and the pure parts of every other task. Everything else is this list, and
no task above is done until its line here is reported observed (spec §11, and Louis's own doctrine:
unit tests alone never close a feature).

1. Open the window from the menu. It comes to the front and takes the first keystroke.
2. Click Xcode, then the menu-bar glyph again. The **same** window comes back — not a second one.
3. Paste into the vocabulary field with ⌘V. (The gate that decides Q-B1.)
4. Close the window. Murmure is still running and a dictation still works.
5. Dictate three times through different modes. Open History: three rows, right modes, right
   durations, newest first.
6. Search for a word you said in one of them. It is the only row left.
7. Open a row: the raw transcript and the refined text are both there and are different. Copy the
   refined text and paste it somewhere.
8. Press "Process again" with a different mode. The row updates; nothing is inserted anywhere.
9. Delete a row. The WAV is still on disk (or is not, per Q-B3 — whichever was decided).
10. Add a term to the vocabulary that Whisper currently gets wrong. Dictate it. It is right.
11. Add a replacement. Dictate the term. The replacement lands, and it landed **before** the refiner
    saw it (check with a refining mode).
12. Edit a mode's instructions in the window, then open the same file in a text editor. They agree.
13. Edit the file by hand, reopen the window. It shows the hand edit and does not overwrite it.
14. Break a mode file on purpose. The Modes pane names the file and says what is wrong with it, and
    the menu still says so too.
15. Delete a Whisper model in the Models pane. The next dictation says the model is missing before
    it starts recording, not after.
16. Dictate with the window open and focused. The text lands in the app you meant, not in Murmure.
17. Resize the window, quit, relaunch. It comes back the size and section you left it.

---

## Retention — decided by Louis, 2026-09-01

Supersedes spec §7's "no auto-purge, manual clear only", which was not a policy: measured at
461 MB for 99 recordings (~4.6 MB each), the corpus's 1 469 dictations project to **~6.8 GB**.

**Three tiers, and the third is what makes the second affordable.**

1. **Audio: deleted after 3 days.** His words: *"je vois même pas de cas où ce soit intéressant de
   le garder"*. The WAV is not the recovery path — a failed paste is recovered from the text
   (lot 3 T6), not the audio. Three days covers the only real case: a transcription that produced
   garbage and has to be re-run.
2. **Text (raw + refined): deleted after 30 days.** Dictations carry client and internal work
   content, so a bounded window is a privacy property, not only a disk one.
3. **Derived vocabulary: kept indefinitely.** This tier exists because of tier 2. Louis asked
   whether anything could be learned from the accumulated text. Fine-tuning cannot: the only pairs
   available are raw transcript → the model's *own* refined output, which is not a human
   correction and training on it degrades rather than improves. What does work is Whisper's
   `initialPrompt` (T6): recurring technical terms mined from history, fed back as context.
   Because the terms are **derived** — a word list, no sentences, no client content — they survive
   the 30-day purge that the text does not, and the vocabulary keeps improving from a corpus that
   is continuously forgotten. The extraction must therefore run **before** a row expires, not over
   whatever happens to remain.

**Consequences for the schema (T3):** rows need an expiry the purge can index; audio and text
expire on different clocks, so the WAV path must be nullable on a row whose text is still live;
the vocabulary table is not a view over history and must outlive it.

**Deliberately not built:** any fine-tuning or model-adaptation path. Recorded so it is not
re-proposed as an oversight.
