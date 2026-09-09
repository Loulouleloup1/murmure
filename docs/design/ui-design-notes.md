# Superwhisper UI — design-language reference for Murmure

**Primary subject: the app as actually installed on this Mac** (captured 2026-08-31, settings window
750×500 pt, dark appearance, Louis's own configuration). A secondary section at the end keeps what
only exists in Superwhisper's public documentation — that corpus is **older and less complete than the
shipping app**, and several things it shows are contradicted by the install.

Murmure is a from-scratch reimplementation. Everything here is behaviour and information
architecture. No asset, icon, glyph, brand colour or copy string is to be reproduced.

## Provenance and method

| Source | What it is | Confidence |
|---|---|---|
| `docs/design/superwhisper-local/*.png` (19 unique) | Installed app, 1500×1000 px = 750×500 pt @2× | **Observed** |
| `docs/design/superwhisper-local/settings--untitled-610.png` | The Mini recording window, 480×320 px = 240×160 pt @2× | **Observed** |
| `~/Documents/superwhisper/modes/*.json` (2 files) | The app's on-disk mode definitions | **Observed** |
| `docs/design/superwhisper-ui/*.png` (74) | Superwhisper's own doc screenshots, older | **Docs-only — may be stale** |

Colours below were **sampled from the PNGs** (sRGB) and geometry **measured in pixels then halved**
(the captures are @2×). Font sizes are **derived** from measured cap/ascender heights assuming an
SF-Pro cap ratio of ~0.70 — treat those as ±1 pt. Anything else is labelled *inferred*.

`settings--untitled-65.png` is a byte-for-byte duplicate of `section-home.png`.
`section-sound-scroll1/2.png` are identical to `section-sound.png` (the Sound pane does not scroll).

---

## 1. Information architecture

### The seven sidebar sections

The sidebar is a fixed rail, **184 pt wide** (measured to the 1 pt `#505050` divider at x = 184 pt),
inside the same window as the content pane. Seven items, in four spacing groups — the row pitch is
35 pt inside a group and 45 pt across a group boundary (measured from icon-tile tops):

```
  Home                     ← group 1   coloured icon
  ─── 10 pt extra ───
  Modes                    ← group 2   coloured icon
  Vocabulary                                coloured icon
  ─── 10 pt extra ───
  Configuration            ← group 3   grey icon
  Sound                                     grey icon
  Models library                            grey icon
  ─── 10 pt extra ───
  History                  ← group 4   coloured icon
```

There are no divider rules — grouping is purely by that extra 10 pt of space, plus the icon-colour
split described in §2.

**What each screen is actually for:**

- **Home** — a *stats dashboard*, not a settings page. A period picker (`All time`, a popup),
  then a four-column stats strip (average WPM · total words · apps used · time saved, the last with
  a small gear to configure how "time saved" is computed), then a "Get started" checklist of four
  onboarding tasks (icon + bold title + muted one-liner; the first row carries a trailing keycap chip
  showing the Toggle-Recording binding), then a "What's new?" changelog card — date gutter on the
  left, release title, a truncated one-line blurb, and a blue "Try it now"-style link per entry,
  with a "View all changes" link in the section header.
- **Modes** — the mode list. §5.
- **Vocabulary** — a single add-field plus a flat alphabetical two-column list. §1.2.
- **Configuration** — appearance, recording-window chrome, keyboard shortcuts, app lifecycle. §4.
- **Sound** — mic conditioning (auto-gain, silence removal, dynamic normalisation, what to do with
  audio playback while recording) and sound effects (a 3-way picker + a volume slider).
- **Models library** — a *model catalogue*, browsable and searchable. §1.1.
- **History** — the archive of past dictations. §1.3.

### Two sections the documentation never showed

**Home (stats dashboard) and Models library do not exist anywhere in the 74 documentation
screenshots.** The doc corpus jumps straight from settings chrome to Modes/Vocabulary/History. Both
are meaningful additions:

- Home turns the app's first screen into a *retention/value* surface (words dictated, time saved) with
  onboarding tasks attached. Murmure has no retention problem to solve, but "words dictated / time
  saved" is cheap to compute from the History table and is genuinely satisfying. Optional scope.
- Models library is the single most transferable new idea. §1.1.

### 1.1 Models library — the surface Murmure's spec calls "Models"

This is a **data table**, not a settings card stack — the only table in the app. Layout:

- Window header row becomes a search field (`Search models`, magnifier at the left) plus a filter
  glyph at the far right.
- Below it: an `All providers` popup filter (left) and a key-with-plus button (right, for adding an
  API key — irrelevant to Murmure).
- Column headers, muted ~11 pt: `Model name` (sortable, caret indicates direction) · `Type` ·
  `Speed / Accuracy` · `Cloud/Offline`.
- Each row: **leading state glyph** (a filled ★ for favourited, a grey padlock for tier-locked —
  locked rows also dim their name text), **provider avatar** (rounded-square tile, brand-coloured,
  ~18 pt, with a padlock composited on top when the model is locked), **model name**, optional small
  uppercase badge chip (`EN`, `NEW`).
- `Type` renders as a glyph, not a word: a stacked-lines mark for language models, a waveform mark for
  voice models. Two model families, one column, zero text.
- `Speed / Accuracy` is a **6-segment meter** — filled segments = rating. One column carrying two
  correlated qualities is a compression trick worth stealing.
- `Cloud/Offline` is a *single column doing three jobs*: download size + a circular ⬇ button for a
  local model not yet downloaded; a 🗑 button when it is downloaded (the only visible "installed"
  signal); a plain cloud glyph for cloud-only models.

For Murmure this maps almost one-to-one onto the WhisperKit model list plus the Ollama/LM Studio
roster: name, type glyph (STT vs LLM), a quality/speed meter, size, and one action column that flips
between download / delete. The cloud/local distinction collapses to nothing (everything is local), and
the star/lock columns go away entirely.

### 1.2 Vocabulary

Header bar carries an export/download glyph (top-right). One full-width input row: placeholder
`New word or replacement`, with **two inline submit affordances rendered as label + keycap chip** —
"Add word ⏎" and "Replace with… ⌘⏎". One field, two commit gestures, no buttons.

Below it, a flat list with **no card and no dividers**: left column = the word; if a replacement
exists, an arrow chip (18 pt rounded square) then the replacement in a second column. Entries with no
replacement occupy only the left column. Sorted alphabetically, case-insensitive. Hovering a row
paints a full-width rounded-rect highlight and reveals an ✕ delete button at the right edge — the
delete affordance is **hover-only**.

This confirms the doc-derived reading: vocabulary is modelled as a *two-sided* word → replacement
table where the replacement is optional, i.e. one list serves both "bias the recogniser" and
"fix this word afterwards". That matches Murmure's spec §5 exactly (initial-prompt hints +
find→replace) and is worth keeping as **one list, not two**.

**Divergence (2026-09-05), on Louis's own request:** Murmure's Vocabulary pane now departs from
the installed app's layout above on three points, because the installed app's own affordances (a
keycap hint, no buttons) tested as too plain and too easy to miss for a not-very-savvy user. Rows
carry an **always-on card** (History's convention, §1.3) rather than a hover-only fill, with an
8 pt gap between rows; a replacement's arrow is a **plain glyph**, not a filled chip (a filled chip
would vanish against the row's own now-permanent card fill); and each input row carries a
**visible "Add" button** beside it (`.bordered`, `.controlSize(.small)` — the same style
`GeneralPaneView`'s Record button uses) in addition to Enter, rather than Enter/⌘-Enter alone.

### 1.3 History — layout only

*(Louis's real dictated content is visible in this capture. Layout only below; nothing about the
content is recorded here.)*

- Window header row becomes a search field (`Search history`), same slot and treatment as Models
  library.
- Content is a **single column**, not the three-pane window the documentation shows.
- Entries are grouped under a muted, small, left-aligned **date header** (`Today`), sitting outside
  and above the cards.
- Each entry is a **full-width rounded-rect card**, `#4B4B4B` on the `#3C3C3C` pane, radius ~16 pt,
  **~64 pt tall — exactly two lines of ~13 pt text plus padding**, uniform for every entry, with the
  second line ellipsis-truncated.
- The card renders **only the transcript excerpt**. No timestamp, no duration, no mode name, no
  model, no icon, no trailing action. Metadata is entirely deferred to the (uncaptured) detail view.
- Cards are separated by an 8 pt gap; no dividers. An overlay scrollbar appears at the right edge.
- Density: ~5.5 cards visible in a 500 pt-tall window.

The IA point: **the transcript is the identity of the row.** Nothing competes with it. Murmure's
spec §7 asks for a three-pane History; the installed app has moved to list-then-drill-in. That is a
real, recent divergence from the documentation and is worth surfacing to Louis as a choice
(list + drill-in is markedly cheaper to build than three synchronised panes).

### 1.4 Window shell

- Window is **750 × 500 pt**, with only **red and yellow traffic lights — no green**, i.e. not
  zoomable/resizable. Standard system window corner radius (measured ~13 pt at the top-left).
- A **46 pt header row** spans the content pane, closed by a 1 pt `#505050` hairline. Its contents are
  **per-section**, which makes it a contextual toolbar rather than a titlebar:

  | Section | Header contents |
  |---|---|
  | Home, Modes, Configuration, Sound | sidebar-collapse glyph (left) · input-device name + headphone glyph (right) |
  | Vocabulary | sidebar-collapse glyph (left) · export glyph (right) |
  | Models library | search field (left) · filter glyph (right) |
  | History | search field (left) |

  Pinning the **microphone selector** into the header of every non-list section is a good call: the
  one setting you might need mid-session never requires navigation.
- **Only Modes carries a page title.** Home, Configuration, Sound, Vocabulary, Models library and
  History have no page heading at all — they open straight onto a period picker, a section header, an
  input field, a filter row or a date header. And the Modes title is followed by a small ⓘ glyph, not
  by the explanatory paragraph the documentation shows. **The installed app has deleted the
  page-level description prose entirely.**
- Sidebar footer: a muted trial-status line and a pill-shaped account/tier button. Murmure has no
  licence — this slot simply does not exist for us.

---

## 2. Visual system

### Surface palette (sampled)

| Token | Value | Where |
|---|---|---|
| Window / pane background | `#3C3C3C` | sidebar **and** content pane — identical, no split |
| Raised group card | `#4B4B4B` | Configuration cards, History cards, hover fills |
| Mode row card | `#4A4A4A` | Modes list rows, sidebar grey icon tiles |
| **Recessed** card | `#363636` | Home stats strip only |
| Hairline divider | `#505050`, 1 pt | under the header row; between rows inside a card |
| Selected sidebar row / keycap chip | `#5B5B5B` (subtle vertical gradient `#5F`→`#5B`) | |
| Accent blue | `#3C7FF5` (toggles, slider fill, selected segment), `#3478F6` (sidebar tiles) | |
| Mini pill fill / stroke | `#242423` / `#525251` | the recording window |

Note the two-direction elevation: most grouped content is a **lighter** card on the pane, but the Home
stats strip is **darker** — a deliberate recessed "readout" treatment for a non-interactive band of
numbers. Worth copying for a stats strip; do not generalise it.

Everything else is monochrome. The only non-blue colours in the whole chrome are the sidebar icon
tints, a green mode-active dot, and third-party provider brand colours in the Models library.

### Corner radii (measured)

| Element | Radius |
|---|---|
| History card | ~16 pt |
| Home stats card | ~15 pt |
| Mode row | ~14 pt |
| Selected sidebar row | ~11 pt |
| Icon tiles, keycap chips | ~5 pt *(estimated, too small to measure cleanly)* |
| Mini recording pill | full (4 pt on an 8 pt height) |

Nothing is square-cornered. Three tiers: large surfaces ~14–16 pt, interactive rows ~10–11 pt,
chips ~5 pt.

### The sidebar's two icon families — coloured vs monochrome

Every sidebar item has an **18 pt rounded-square tile** with a white glyph. The tint splits them:

| Coloured | Grey `#4A4A4A` |
|---|---|
| Home `#FC8E57` (orange) | Configuration |
| Modes `#3478F6` (blue) | Sound |
| Vocabulary `#3478F6` (blue) | Models library |
| History `#7675E4` (indigo) | |

The split is **exactly the middle spacing group**. Read (*inferred*): **coloured = your material —
your stats, your modes, your vocabulary, your dictations; grey = the app's machinery — how it behaves,
how it sounds, what engines it has on disk.** The colour is doing what the missing divider rules would
have done, one level coarser than the spacing groups.

That is a genuinely useful, cheap device for Murmure, whose settings surface will be smaller: tint the
two or three sections that hold the user's own material, leave the configuration sections neutral,
and you can drop headings and dividers entirely.

### Typography — a two-size scale, flatter than the documentation suggests

Measured cap/ascender heights → derived sizes:

| Role | Cap height | Derived size | Weight |
|---|---|---|---|
| Sidebar label, row label, page title, card body, stat number | 10 pt | **~13–14 pt** | regular; semibold for titles and stat numbers |
| Section header (`Appearance`, `Get started`, `Keyboard Shortcuts`) | ~8.5 pt | **~13 pt** | semibold, muted grey |
| Row subtitle, stat caption, column header, date header | ascender ~7.5 pt | **~11–12 pt** | regular, muted grey |

There is **no display size anywhere**. "Modes", the only page title in the app, measures the same cap
height as the "Home" sidebar label and as a `Theme` row label — it is body size, semibold. The
documentation-derived notes claimed a 22–24 pt page title; the installed app does not have one.
The whole window runs on **two sizes and a muted/bright contrast**, which is the main reason it reads
as dense-but-calm at 750×500.

Text colours: bright `#EEE`-ish for primary, ~`#9B9B9B` for muted. Locked/unavailable rows are dimmed
by lowering the text colour, not by dimming the whole row.

### Spacing rhythm (measured)

- Content pane horizontal padding: **24 pt** (Home) / ~20 pt (History, allowing a scrollbar gutter).
- Header row height: **46 pt**.
- Sidebar row pitch: **35 pt** within a group, **45 pt** across a boundary; selected row highlight is
  **70 × 35 pt** inset ~12 pt from the rail edges.
- Mode rows: **51 pt** tall, **8 pt** gap between rows.
- History cards: **64 pt** tall, **8 pt** gap.
- Group cards use internal hairline dividers between rows; separate cards use an ~8–16 pt gap plus a
  section header above.

### Controls

- **Toggle** — pill switch, measured **~44 × 20 pt** (wider than the 38 × 22 macOS standard, so
  likely custom-drawn). Blue `#3C7FF5` on, grey off, white knob.
- **Segmented picker** — measured **~194 × 24 pt** overall, three equal ~64 pt segments; the selected
  segment gets a **solid blue fill with white text**, unselected are transparent on the `#5B5B5B`
  track. (`Simple / Classic / Off` on Sound.)
- **Image-tile picker** — used where the choice is visual (Theme: Auto/Light/Dark; Recording window:
  Classic/Mini/None). Each option is a preview thumbnail with a caption below; the selected one gets a
  **2 pt blue ring**, not a fill. A "None" option is drawn as an eye-with-slash glyph rather than an
  empty tile. This is the pattern Murmure should use for notch / pill / classic overlay.
- **Popup button** — grey `#5B5B5B` capsule with a trailing up/down chevron pair (`Pause`, `Forever`,
  `All providers`).
- **Slider** — blue fill left of the knob, tick marks below, glyph bookends (mute / full volume).
- **Keycap chips** — **18 × 18 pt** rounded squares for a single glyph, growing horizontally for word
  keys (`esc` measures 30 × 18 pt). One chip per key, never a concatenated string. Fill `#5B5B5B`.
  Used in three places: shortcut rows, the inline submit hints on Vocabulary, and the "Change active
  mode" hint at the bottom of the Modes pane.
- **Inline help** — a small `?`-in-circle glyph immediately after a row label. Present on almost every
  toggle row. There is no per-row explanatory paragraph anywhere.
- **Reset affordance** — shortcut rows show a small circular-arrow glyph to the left of the keycaps.
- **Hover** — a full-width rounded-rect fill plus revealed destructive actions (Vocabulary ✕, Models
  library row highlight). Nothing destructive is visible at rest.

---

## 3. The recording window — Configuration → Classic / Mini / None

Configuration offers three chromes for the in-progress recording, as an image-tile picker.
**Louis has Mini selected, with "Always show" ON.**

From the picker's preview thumbnails (these are illustrations rendered by the app, not live captures):

- **Classic** — a wide black rounded-rect with a dense many-bar waveform filling the upper area and a
  lighter grey control strip along the bottom edge. This matches the two-row stage/control bar the
  documentation describes.
- **Mini** — a black pill containing ~9 centred white amplitude bars. **Nothing else**: no text, no
  mode name, no buttons, no shortcut hints.
- **None** — eye-with-slash. No recording chrome at all.

### The Mini window, measured

From `settings--untitled-610.png`, a capture of the live window:

- The window canvas is 240 × 160 pt and is **fully transparent** except for the pill. The pill sits at
  the **top-centre** of that canvas; the ~130 pt of transparency below it is presumably headroom for
  the window to grow downward (*inferred* — no live recording capture exists to confirm).
- The pill measures **45 × 8 pt** (90 × 16 px @2×), **fully rounded** (radius 4 pt = half its height),
  fill `#242423`, with a **1 pt `#525251` stroke**.
- **At idle it is completely empty** — no glyph, no dot, no text. It is a small dark bar, roughly the
  proportions of an iPhone home indicator, and that is the entire idle UI.
- Because "Always show" is on, that bar is on screen permanently.

**Important gap:** the only capture we have is the **idle** state. There is no capture of the Mini
window while recording, processing, or after insertion. The Mini preview tile implies the recording
state is a *taller* pill with waveform bars (the tile's pill is roughly 3:1 where the idle pill is
5.6:1), but that is an illustration and the growth ratio should not be treated as measured.

### Relation to Murmure's notch state model (spec §6)

The spec's states: `idle → recording → processing → done → hover → paste-failure`, all as one
continuously morphing surface.

**What Mini does that our notch must also do**

1. **Idle is inert and near-invisible.** A dark, contentless bar with a hairline stroke. It reads as
   part of the hardware, not as an app window. That is precisely the register the notch needs at rest,
   and it is achieved with zero information — no icon, no dot, no name.
2. **The waveform IS the recording signal.** No label, no timer, no red dot, no "Recording…" string.
   This validates the spec's "waveform wings on both sides" as sufficient on its own. Do not add a
   status word to the collapsed recording state.
3. **Shape change carries the state change.** Idle→recording is a *geometry* transition (a thin bar
   grows into a pill with content), not a colour swap. That is exactly the spec's "morphing, never a
   window glued to the notch" instruction, and it means the animation is the state machine's only
   visible output at the collapsed size.
4. **Ship an "always show" toggle.** On a no-notch display Murmure's pill has no hardware anchor;
   Superwhisper's `Always show` is the exact control needed to choose between "resting pill always
   present" and "appears only while recording". Cheap, and it is a real user preference.

**What Mini does that we should NOT copy**

1. **Three separately-designed recording chromes.** Superwhisper needs Classic *and* Mini because it
   has no anchor and no morphing; Murmure's spec already commits to one component that morphs. Build
   one surface with a notch / pill / bottom-overlay *placement* choice, not three chromes.
2. **Zero controls in the collapsed state.** Mini has no Stop and no Cancel — cancelling depends
   entirely on the `esc` shortcut, and there is no visible way to discover it. Murmure's hover state
   must fix that, not inherit it.
3. **An always-on idle artefact by default.** With a physical notch the resting affordance already
   exists; drawing a second permanent pill under it would be redundant. Default the toggle off on
   notch hardware (*recommendation, not observation*).
4. **The Classic bar's permanently-rendered control strip** (Stop / Cancel labels plus their shortcut
   chips visible for the entire recording). The spec's hover-reveal is better and quieter.

**What Murmure has to solve that Mini does not solve at all**

- **Processing and done.** Mini has no observed processing or completion state. The spec's blue pulse,
  green flash, and *retraction into the notch replacing the macOS notification* are entirely our
  design — there is nothing to study here.
- **Paste failure.** No analogue anywhere in the installed app. A collapsed surface that has to expand
  into a panel holding recoverable text with Re-paste / Copy is a state Superwhisper never renders.
- **Hover as a dashboard.** Mini shows no mode name at all; Superwhisper solves mode identity with a
  global `⌥⇧K` switcher overlay instead of putting it in the recording chrome. If Murmure wants mode +
  elapsed time + Stop/Cancel + History/Settings on hover, the *content* reference is the Classic bar
  (left = identity/status/mode, right = Stop then Cancel), but the *reveal* mechanic is ours.
- **Notch geometry.** Content split around a physical cutout into two wings, degrading to a
  centred pill on external displays. Mini is a single free-floating rectangle with no such constraint.
- **State count.** Mini is effectively a 2-state component. Murmure's is a 6-state one. The morphing
  budget, animation timing, and layout stability across six states is the actual hard problem, and the
  installed app offers no evidence on it.

---

## 4. Keyboard shortcuts — as configured on this machine

Read directly off Configuration → Keyboard Shortcuts. Each row: bold label (~13 pt) + muted
description (~11 pt) on the left; a reset glyph then keycap chips on the right; unset rows show a
dimmed `Record shortcut` placeholder in the value slot.

| Action | Description shown | Binding |
|---|---|---|
| Toggle Recording | starts and stops recordings | **`⌥` alone** (modifier-only) |
| Cancel Recording | discards the active recording | **`esc`** |
| Change mode | activates the mode switcher | **`⌥` `⇧` `K`** |
| Push to Talk | hold to record, release when done | **unset** |
| Mouse shortcut | tap to toggle, or hold and release when done | **unset** |

The `⌥⇧K` binding is echoed as a hint strip pinned to the bottom of the Modes pane ("`⌥` `⇧` `K`
Change active mode").

**Divergences from the Murmure spec — decisions for Louis, not changes:**

1. **The spec names Fn and Right ⌘ as its modifier-only examples (§4); Louis actually runs plain `⌥`.**
   Same mechanism (`NSEvent` global monitor), different key. Worth confirming which modifier Murmure
   should default to — `⌥` is already muscle memory, but it is also a live modifier in most apps, so
   the tap-vs-hold discrimination has to be right.
2. **The spec defines no default bindings at all.** Superwhisper's shipping set is a reasonable
   starting point: toggle on a bare modifier, `esc` to cancel, a chord for the mode switcher, push-to-talk
   and mouse shortcut left unset.
3. **Superwhisper has no per-mode hotkey.** Mode selection is a *global* switcher action (`Change
   mode`), and the on-disk mode files carry no hotkey key at all. Murmure's spec §5 puts
   `"hotkey": null` in the mode JSON. Two coherent models — per-mode hotkeys, or one switcher — and
   the installed app is evidence that the switcher scales better once you have more than a couple of
   modes. Louis's call.
4. **`Mouse shortcut` is a binding class the spec does not mention** (a mouse button as the
   record trigger, tap-to-toggle or hold-to-talk). Flag as optional scope.

Configuration also holds, further down: Update application (`Check for Updates…` button), Automatically
check for updates (on), Launch on login (on), Error logging (off), and `Keep recordings for` (a popup,
set to `Forever`). The capture ends there; **there may be further rows below that were not captured.**

---

## 5. Modes

Only the **list** was captured. There is **no capture of the installed mode editor**, so everything
about the editor in §7 below is documentation-derived and possibly stale.

### The list

- Page header: `Modes` + ⓘ glyph on the left, a grey `+ Create mode` button on the right. Note the CTA
  is **grey, not blue** — the accent is reserved for state (toggles, selection), not for buttons.
- Two rows, one per file in `~/Documents/superwhisper/modes/`, each a 51 pt `#4A4A4A` card with a
  ~14 pt radius, separated by an 8 pt gap. No expansion chevron is visible.
- Row content, left to right: **a monochrome glyph** (a microphone for the built-in voice mode; a
  laptop for the custom mode — which matches that mode's `iconName` field on disk, so **the glyph is
  driven by the mode file**), the **mode name**, and — on the active mode only — a **small green dot
  immediately after the name**. That dot is the entire active-mode indicator: no highlight, no
  checkmark, no border.
- Trailing, right-aligned: a lighter rounded-rect container holding **one small tile per model stage
  the mode uses**, each tile being the **provider's avatar**:
  - the transcription-only mode shows **one** tile (its STT provider);
  - the LLM-refining mode shows **two** tiles (STT provider + language-model provider).
  - A **padlock is composited onto the avatar** when that model is not available on the current tier —
    confirmed by the Models library, where the same avatars appear with the same padlock overlay on
    every locked row. *(Inferred from the correspondence between the two screens, not from a label.)*

  So the trailing icons are a **provenance-and-availability readout: how many model stages this mode
  runs, who provides each, and whether you can actually use them.** That is a genuinely good row
  design — at a glance you can tell a transcribe-only mode from a refining one without opening it.

  For Murmure the availability half collapses (everything is local) but the **stage-count half is
  worth keeping**: one badge for STT-only, two for STT + refinement, so the daily-driver Voice mode is
  visually distinct from Prompt/Message/Email in the list.

### Switching modes

Two mechanisms observed: the global `⌥⇧K` "mode switcher" (an overlay not captured), and the list
itself. The switcher is advertised **in the Modes pane footer**, as a centred keycap-chips + label
strip — a nice, low-cost way to teach a shortcut at the exact place the user is thinking about it.

### The editor's transparency blocks -- shipped 2026-09-05

Three additions to the inline editor, none of them in the documentation corpus above (there is no
capture of the installed editor at all, per this section's opening line) -- built from Louis's own
request: modes have to be readable and fully editable, prompt-engineering included.

- **"What the refiner receives."** A read-only, monospaced, scrollable block under Instructions,
  built by `RefinementPreview.render(mode:)` (`MurmureCore`) from the SAME assembler
  (`SystemTurnAssembly.assemble`) `RefinementRequest.systemTurn` calls for the real request -- so
  the preview can never show a system turn a dictation would not actually send. For `api: .chat` it
  shows the exact system turn (instructions, the context preamble, one placeholder per enabled
  toggle) and the transcript's own turn; for `api: .s1` it shows the fixed s1-mini system prompt
  (labelled as fixed by the model card), the control line, and the transcript; with the refiner off
  it says plainly that nothing is sent.
- **A description under each context toggle.** `ContextSource.description` (`MurmureCore`) says
  what is captured, when (at recording start), and how the refiner sees it. Under `api: .s1` the
  shared reason (`ContextSource.s1DisabledReason`) explains why the three toggles stay disabled --
  s1's system turn is fixed by the model card rather than absent (it exists: `OllamaS1.conversation`
  writes one, and the preview's own "System prompt" block shows it), so there is nowhere for a mode
  to put context in it -- and names the escape hatch (switch to `chat`). This is the direct answer
  to "it does not seem to work with s1": it is by design, stated where the toggles are.
- **The Icon field.** `Mode.symbol` (an optional SF Symbol name, nil-safe for every mode file
  written before it existed) plus a twelve-tile grid -- a "Default" tile, drawn with the mode's
  own stage glyph and clearing `symbol` back to nil, ahead of `ModeSymbol.library`'s eleven --
  drawn with the same tile `MainWindowView`'s sidebar rows use -- the accent for the selected
  tile, the neutral machinery tile otherwise. The chosen glyph is what `Mode.symbolName` now
  returns everywhere a mode is drawn (Modes list, the window header); nil falls back to the stage
  default it always had (§5's own microphone/sparkles split), and the Default tile is how a mode
  gets back to that fallback once something else has been picked.

Also reordered per Louis's ask ("I want to see all of it"): Name, Icon, Language (now a picker over
WhisperKit's own language table rather than free text), Speech model, the whole refiner block
(enabled, API, model together -- `api` moved out of Advanced), Instructions, the preview, then
Context.

### The Shortcut field -- shipped 2026-09-05

Backlog §7's own closing sentence: `Mode.hotkey` was wired underneath (`HotkeyAssignments.resolve`,
`ModeHotkeyPress`) with no editor field to set one from -- the only way to give a mode its own
shortcut was hand-editing its JSON file. `ModesPaneView.shortcutRow`, between Language and Speech
model, is that field.

A chip row (or "None") plus Record and Clear, recorded through the exact same `HotkeyRecordingSession`
General's own Record button uses for the toggle -- same rules (⌃⌥⇧⌘ required except F-keys, Escape
always refused, a single modifier tapped alone is legal), same release/restore discipline: every
live binding, not the toggle alone, is released for the length of the recording
(`DictationController.releaseToggleHotkey()`) and restored on every exit -- accepted, refused,
Cancel, the pane disappearing, or the model itself deallocating. `GeneralPaneModel` could not be
touched to share that discipline as one helper (it was mid-review elsewhere at the time), so
`ModesPaneModel` mirrors it rather than reusing it.

Below the row, the conflict or refusal sentence `HotkeyAssignments.resolve` would produce for the
combo just typed -- checked against the live toggle and every other mode, with the draft's own
hotkey substituted in -- so a clash is visible before Save ever runs the same resolution for real.

Two independent local-monitor recorders now exist (General's toggle, Modes' per-mode shortcut),
each releasing and restoring every live binding around its own capture window, and neither knows
the other exists. That is safe only because the two can never both be recording at once: `Murmure`
shows exactly one section at a time, from one `switch` in `MainWindowView`, so leaving General's
pane tears its monitor down (`.onDisappear`) before Modes' pane -- and its own monitor -- can ever
appear. Two recorders on screen together would each try to release and restore the same bindings
independently, racing each other.

### Drafting a mode with help -- shipped 2026-09-05

A second button in the footer, beside "+ New mode": **"Draft with help"** (`wand.and.stars`, the
same grey chip styling, `Color(role: .cardBackground)`). Opens a sheet (`ModeDraftSheetView`),
fixed-width (`WindowLayout.draftSheetWidth`, wider than the Inspect sheet -- a conversation bubble
holding a fenced JSON mode needs the room a candidate list's one-line rows do not):

- A model picker over chat-capable Ollama models only (`ChatModelFilter.isChatCapable`) -- the
  s1-mini model and the two embedding models never appear in it.
- A scrolling conversation log, user/assistant bubbles on the existing palette
  (`.selection`/`.cardBackground`), rounded font for prose and a monospaced one for whatever falls
  inside a fenced code block -- purely cosmetic splitting, done in the view, never consulted by the
  extractor itself.
- A text field + Send, streaming the reply token by token as it arrives.
- **"Use this draft"**, enabled only once the last reply's fenced block extracts and validates
  cleanly (`ModeDraftExtraction`, `MurmureCore`) -- pressing it closes the sheet and opens the
  ordinary inline editor on the candidate, prefilled, exactly the way a preset does. Nothing here
  writes a file: the model never sees `ModeStore`.

Notices under the log, plain sentences rather than a second alert vocabulary: a truncation-turns
count when the conversation outgrew its character budget, a "cut off before the end" note when
`num_predict` stopped the reply mid-sentence, and whatever ``ModeDraftProblem`` the last reply
failed on (most often "no fenced block yet" -- a clarifying question, not an error).

Nothing about this sheet reaches Ollama on its own appearance: the model listing and the installed
speech models it shows are the same snapshot `ModesPaneModel` already loaded for its own pickers.
See `docs/plans/2026-09-backlog.md` §8 for the model-gating rule, the extraction contract, and the
two real conversations this was verified against.

### Home statistics pane -- shipped 2026-09-09

Murmure's actual Home, replacing the onboarding-checklist/changelog idea sketched under §1 above
with the stats-only reading of Superwhisper's reference: a vertical scroll of cards on
`Color(role: .paneBackground)`, cards themselves on `Color(role: .cardBackground)` with the usual
hairline. A period picker (segmented control -- 7 days, 30 days, 12 months, All time) sits opposite
the pane title in the top row and persists across launches.

**The card grid, in row order.** Row 1: four `StatCard`s side by side -- Average WPM, Words,
Applications, Time saved -- each a big figure with a small label underneath; the Time saved card
carries a small gear button. Row 2: the heatmap, full width, one card. Row 3: two cards side by
side, Hour profile and Streak. Row 4: two cards side by side, Records and Top applications.

**The period rule.** The four figures in row 1 and the Top applications card follow the period
picker. Two cards never do: the heatmap always covers the last 52 weeks ending today regardless of
the picker, and the Streak and Records cards are always computed over all time. Both cards say so
in their own caption, next to the figures, rather than leaving the period picker to imply a scope
it does not have for them.

**The heatmap rule.** 52 columns by 7 rows, Monday at the top rather than Sunday, month initials
along the bottom axis. Each cell is one of five accent levels: level 0 (no dictation that day) is
the lightest fill; levels 1 to 4 are the four quartiles of words relative to the busiest day inside
the 52-week window, and a day with dictations but no counted words (a row whose text was purged
before the word-count migration, or genuinely zero words) also sits at level 1. No hover tooltip in
this version.

**The typing-baseline popover.** The gear on the Time saved card opens a popover: a sentence naming
what it configures ("Typing speed used for the comparison"), a stepper and slider bound to the same
value, and a closing sentence stating the formula in words -- time to type the words at that speed,
minus time actually spent speaking. Changing the value recomputes Time saved immediately, in the
same popover session.

**The empty state and the error state.** When no counting dictation exists anywhere in the table,
the whole pane collapses to a single centred `ContentUnavailableView` ("No dictation yet", one line
of guidance) rather than a grid of cards showing zeroes. When the archive itself cannot be read,
the pane shows a second, distinct `ContentUnavailableView` ("Statistics unavailable") naming the
error -- `HomePaneModel` keeps "nothing recorded yet" and "the archive could not be read" as two
separate published properties precisely so the pane can tell them apart rather than collapsing both
into the same blank card grid.

---

## 6. On-disk mode schema vs the Murmure spec

`~/Documents/superwhisper/modes/` holds one JSON file per mode, named after the display name
(`voice to text.json`, `local.json`), with a `key` field duplicating that filename. Both files are
**flat** — no nesting at all — and carry `"version": 1`.

Keys observed, with types:

| Key | Type | Role |
|---|---|---|
| `key`, `name`, `description` | string | identity; `description` empty in both files |
| `version` | int | **schema version** |
| `type` | string | `"voice"` or `"custom"` — the discriminator that decides whether an LLM stage runs |
| `iconName` | string | drives the list glyph (`"macbook"`); empty on the built-in |
| `language` | string | `"fr"` / `"en"` |
| `translateToEnglish` | bool | |
| `voiceModelID` | string | STT model id (`"medium"`, `"sv-1"`) |
| `languageModelID` | string | LLM model id (`"sl-1"`); **empty string** on the transcribe-only mode |
| `prompt` | string | the LLM instruction (not reproduced here) |
| `promptExamples` | array | few-shot examples; empty in both |
| `tone` | string | `"semi-formal"` — **present only in the custom mode**, absent from the voice mode |
| `contextFromActiveApplication` / `contextFromClipboard` / `contextFromSelection` | bool | three independent context sources |
| `contextTemplate` | string | the **template into which captured context is interpolated** before the prompt |
| `activationApps`, `activationSites` | array | auto-activation scoping (apps and websites) |
| `autocapitalizeInsert`, `literalPunctuation` | bool | post-transcription text shaping |
| `realtimeOutput` | bool | stream partial text |
| `script`, `scriptEnabled` | string / bool | a per-mode script hook |
| `diarize`, `useSystemAudio` | bool | meeting features |

### Concrete divergences worth adopting

1. **`version` on every mode file.** Murmure's spec commits to testing "mode JSON parsing/migration"
   (§11) but the schema in §5 has no version field. Add one now — it is free before the first mode
   file exists and expensive after.
2. **`contextTemplate` — the biggest one.** Superwhisper stores *how* captured context is injected as
   a per-mode string template, not as hardcoded logic in the refiner. Murmure's spec has only three
   booleans and buries assembly in the Refiner. Making the template data lets prompt assembly be unit-
   tested against a fixture and lets Louis retune context framing without a rebuild. **Adopt.**
3. **`promptExamples` as a first-class array** alongside `prompt`. Murmure has only `instructions`.
   Few-shot pairs are exactly what a small local refiner needs to hold a register (Slack vs email vs
   prompt-to-Claude), and the benchmark work in spec §10 will produce good candidate pairs for free.
   **Adopt** — even if empty in V1, define the key.
4. **`iconName` per mode.** Murmure's spec §6 promises a "mode colour dot" in the notch and a mode
   switcher, but the §5 schema has no icon or colour field to feed either. **This is a gap in the spec,
   not just an idea to borrow** — add `icon` (SF Symbol name) and/or `color`.
5. **A `type` discriminator rather than an `llm.enabled` boolean.** Superwhisper makes "no refinement"
   a *kind of mode*, and an empty `languageModelID` follows from it. Murmure's `llm.enabled` allows the
   inconsistent state `enabled: false` with a model still configured. Minor, but a discriminator makes
   the invalid state unrepresentable. Consider.
6. **`literalPunctuation`.** Dictating code and prompts into Claude Code is Murmure's primary use case,
   and spoken punctuation commands ("open paren", "backtick") are exactly where a per-mode literal flag
   earns its place. Not in the spec. Worth adding to the Voice mode.
7. **`realtimeOutput` per mode.** Murmure's `TranscriptionEngine` protocol already has a streaming
   variant (spec §4); making it a per-mode switch rather than a global one costs nothing.
8. **`script` / `scriptEnabled`.** A per-mode post-processing hook. Not in Murmure's spec; genuinely
   cheap and very much in the spirit of a personal tool. Optional.
9. **Optional keys are genuinely optional.** `tone` exists in one file and not the other, so the
   decoder must tolerate absent keys rather than requiring the full set. Murmure's parser should decode
   with defaults, and its migration tests should cover a file missing keys the current version knows.

**Do not adopt:** `diarize` and `useSystemAudio` (meeting features, permanently out of scope per spec
§2), and `activationSites` (no browser integration in scope). **Keep Murmure's own additions:** nested
`stt`/`llm` objects (better for hand-editing than eight flat `*ModelID` keys), `llm.endpoint` (needed —
Superwhisper resolves models through a hosted registry and so has no endpoint field), and
`simulateKeypresses` per mode (Superwhisper has no per-mode equivalent).

Also worth noting: Superwhisper stores modes in `~/Documents/superwhisper/`, i.e. **in the user's
Documents folder, not in Application Support** — hand-editable and visible by design. Murmure's spec
puts them in `~/Library/Application Support/Murmure/modes/`. That is more correct macOS practice, but
it does hide them; a "Reveal modes folder" button somewhere in Settings would recover the affordance.

---

## 7. Documentation-only material — older, may be stale

Everything below comes **only** from `docs/design/superwhisper-ui/` (74 doc screenshots, all
dark-mode; many carry the doc team's own numbered callouts overlaid). Where the installed app
contradicts it, the install wins. Kept because these surfaces were not captured on this machine.

- **Menu-bar item and its menu.** Not captured on this machine. The docs show a conventional macOS
  status menu tiered as: frequent actions (Start/Stop Recording, Transcribe File…, History…,
  Settings…, the two most-used carrying shortcuts) → divider → fly-out submenus for Input Device and
  Select Mode → divider → version (disabled), Check for Updates…, Quit. The tiering is the reusable
  idea. Murmure's spec §6 already describes an equivalent.
- **Mode editor.** Not captured on this machine. The docs show an inline, in-place expansion of a mode
  row with: Preset dropdown (re-entry into the same template picker used at creation) → Language →
  Custom-instructions textarea → two model chips side by side → a pushed "Advanced settings"
  sub-screen holding app/website activation scoping, a Prompt-Context checkbox trio, and a
  "Use Examples" block of paired spoken-input/AI-output textareas with an add button. The
  **basic → advanced ladder** is the transferable shape. Treat the field list as indicative: the
  on-disk schema in §6 is the authoritative statement of what a mode actually holds.
- **Create-mode template picker** with a single "Recommended" badge on one row.
- **Three-pane History** (list / transcript + audio scrubber / metadata inspector) with a
  Voice / Segments / AI segmented lens switch and a right-click menu of Process again · Report issue ·
  Delete. **The installed app no longer looks like this** (§1.3) — single-column card list with date
  headers. The *lens switch* idea (one recording, raw vs refined) still generalises to Murmure; the
  three-pane layout should not be assumed.
- **The full Classic recording bar** — near-black waveform stage over a slightly lighter control strip
  split by a hairline; left = status dot + mode name + shortcut chip, right = Stop + shortcut, divider,
  Cancel + `esc`. This is the content reference for Murmure's hover state (§3). The installed app's
  Configuration preview tile is consistent with it, so this one has probably not gone stale.
- The docs corpus contains no genuine light-mode window chrome — every `--light.png` is an
  Open-Graph logo card. **Nothing in either corpus tells us how this app looks in light mode**, and the
  installed app's Theme setting is on `Auto`. Murmure's own light palette is undesigned territory.

---

## 8. Anti-goals

- **No brand assets.** Not the triangular wordmark, not the logo gradient, not the app icon, not the
  Superwhisper-owned padlock provider avatar.
- **No sampled brand colours.** The blues, the orange, the indigo above are recorded so the *structure*
  (accent reserved for state, tints reserved for one icon group) can be reproduced — Murmure picks its
  own hues. Third-party provider brand colours in the Models library are doubly out: they are other
  companies' marks, and Murmure has no providers to badge.
- **No copy strings.** Every label quoted here is quoted to identify a control, not to be reused.
  Describe the same function in Murmure's own words.
- **No licence / tier / trial surface.** The sidebar footer, the padlock overlays, the locked-and-dimmed
  Models rows, the key-add button — all of it exists to gate cloud features. Murmure has none.
- **No cloud/local distinction to render.** Murmure's Models section has one kind of model. The
  `Cloud/Offline` column collapses to a size + download/delete action column.
- **No meeting features.** `diarize`, `useSystemAudio`, speaker separation, a Meeting preset — spec §2
  puts these permanently out of scope. Do not carry the schema keys "just in case".
- **No prompt text.** The `prompt` fields in the mode files are Superwhisper's product; Murmure writes
  its own, informed by the benchmark in spec §10.

---

## 9. What could not be determined

- **The Mini window while recording, processing, or completing.** Only the idle state was captured.
  The recording appearance is known only from the Configuration picker's illustration.
- **The installed mode editor.** No capture. Only the list exists (§5).
- **The mode switcher overlay** (`⌥⇧K`). No capture.
- **The History detail view.** Only the list was captured; what a card opens into is unknown, and with
  it every piece of per-recording metadata (models used, timings, prompt).
- **The menu-bar item and its menu.** Not captured on this machine.
- **Configuration below `Keep recordings for`.** The last capture ends mid-section; there may be more
  rows.
- **Light mode.** Never observed in either corpus.
- **Whether `Always show` also keeps the Classic bar on screen**, or is Mini-specific. The toggle sits
  below the Classic/Mini/None picker, inside the same card, which suggests it applies to whichever is
  selected (*inferred*).
- **Exact corner radii below ~8 pt** (icon tiles, keycap chips) — too small to measure reliably at 2×;
  the ~5 pt figures are estimates.
- **Whether the sidebar and content pane really share one background** or differ by a translucency
  layer that flattened to the same value in this capture. Both sampled `#3C3C3C` exactly.
