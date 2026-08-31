# Superwhisper UI — Design-Language Reference for Murmure

Source: Superwhisper's own documentation screenshots (marketing/help-centre captures, several
annotated with numbered callouts and arrows added by their doc team — those callouts are not
part of the real app chrome, they're doc annotations overlaid on real screenshots).

This document describes and measures what makes the interface work. It does not reproduce any
asset, icon, exact colour, or copy string — all measurements below are visual estimates from
screenshots, not extracted values, and are flagged as such.

## Files inspected (22 of 74)

- `interface-menu-bar--interface-menu-bar.png` — menu-bar icon + dropdown menu
- `interface-menu-bar--dark.png` — menu-bar icon alone (logo card, low signal)
- `interface-rec-window--interface-rec-window-001.png` — full recording bar, two-row layout
- `interface-rec-window--interface-rec-window-002.png` — same, with expand/collapse affordance highlighted
- `interface-rec-window--interface-rec-window-004.png` — waveform region highlighted
- `interface-rec-window--interface-rec-window-005.png` — status dot highlighted
- `interface-rec-window--interface-rec-window-006.png` — collapsed mini pill, 3-icon layout (numbered 1/2/3)
- `interface-rec-window--interface-rec-window-007/008/009.png` — same bar, different control highlighted (scan icon, Stop, Cancel/Esc)
- `interface-rec-window--interface-rec-window-010.png` — result panel, same control row reused
- `interface-rec-window--interface-rec-window-011.png` — two micro-pill states: idle vs. actively recording (red ring)
- `interface-rec-window--interface-rec-window-012.png` — logo card (low signal)
- `interface-rec-window--light.png` — logo card, not an actual light-theme window
- `settings-overview--dark.png`, `settings-overview--light.png` — logo cards only, no shell content
- `settings-advanced--settings-advanced-001.png` — sidebar nav + shortcuts list + Advanced entry point
- `settings-advanced--settings-advanced-002.png` — two-row toggle group (Dock/menu-bar behaviour)
- `settings-advanced--settings-advanced-005.png` — four-row toggle group (paste/clipboard behaviour), some rows gated by an icon
- `settings-advanced--settings-advanced-007.png` — single toggle row with a gating icon (experimental flag)
- `settings-shortcuts--settings-shortcuts.png` — full window chrome, sidebar, shortcuts content pane
- `settings-sound--settings-sound-001.png` — full window chrome, grouped rows incl. a slider row
- `modes-modes--modes-001.png` — modes list + "create mode" template picker (icon + label + optional "Recommended" tag)
- `modes-modes--modes-003.png` — mode editor, voice-model dropdown expanded (per-model cloud/local icon)
- `modes-modes--modes-005.png` — mode editor, language-model dropdown expanded + "Activate when using" app/website triggers
- `modes-custom--modes-custom-001.png` — mode-type picker inline in a collapsed mode row, "Custom instructions" textarea
- `modes-custom--modes-custom-003.png` — "Prompt Context" checkbox group (Application/Copied text/Selected text)
- `modes-custom--modes-custom-004.png` — "Use Examples" paired-input block (spoken input → AI output) with an "Add Example" CTA
- `modes-super--modes-super-001.png` — preset dropdown open over a mode row, "Recommended" badge pattern
- `modes-switching-modes--modes-switching-001.png` — deep-link / URL-scheme automation card (Shortcuts-app style)
- `modes-switching-modes--modes-switching-004.png` — keyboard-shortcut recorder row (multi-key capsule)
- `interface-history--interface-history-001.png` — full three-pane History window
- `interface-history--interface-history-005.png` — right-click context menu on a history row
- `interface-history--interface-history-009.png` — toolbar icon callouts (copy / open-folder / Voice / Segments / AI tab switch)
- `interface-vocabulary--interface-vocabulary-001.png` — Vocabulary pane, input row + two-button pattern

Screenshots suffixed `--light.png` / `--dark.png` that I did not list above are, on inspection,
just the app's logo/icon card used as an Open-Graph image for that doc page — they carry no
layout information and were not analysed further. I'm noting this explicitly rather than
guessing at a "light mode" I never actually saw: **every real screenshot in this set is dark-mode
only**; I found no genuine light-theme window chrome among the 74 files, so anything said about
light-mode below is an inference from standard macOS conventions, not an observation.

---

## 1. Overall design language

- **Window chrome**: standard macOS traffic-light window (red/yellow dots visible, no green —
  suggesting the app disables/hides the zoom control) on a plain rounded-rect dark panel. No
  visible titlebar text or toolbar; the traffic lights float directly on the content background.
  Estimate: outer window corner radius ~14-16pt.
- **Recording bar / floating HUD**: a separate, much smaller floating panel, entirely independent
  of window chrome (no traffic lights) — near-black (`~#0a0a0a`-ish, estimated, not sampled),
  pill/rounded-rect with a large corner radius (looks like ~18-20pt on the outer bar, full pill
  radius on the collapsed mini state). It sits in two visually distinct rows: a taller dark-black
  "stage" row (waveform) and a shorter, slightly lighter-grey "control" row (button labels), split
  by a thin 1px hairline. That two-tone stacking (near-black stage over dark-grey control strip)
  is a consistent motif — also seen reused verbatim for the "result panel" state.
  Suggests a subtle two-layer material (control row very slightly lighter than the stage), not a
  single flat fill — most consistent with a translucent/vibrancy panel over the desktop, though
  no screenshot shows desktop content bleeding through so this is inferred, not confirmed.
- **Corner radii, general**: three radius tiers observed — full-pill (collapsed mini indicator,
  toggle switches, keycap capsules), large-rounded-rect (~16-20pt, the recording bar, settings
  row-groups, mode-editor cards), and small-rounded-rect (~6-8pt, individual keycap glyphs,
  icon swatches, small buttons like "Add App"). Nothing is sharp-cornered.
- **Density**: generous padding throughout — settings rows read as ~14-18pt vertical padding
  per row, ~20-24pt horizontal, with hairline dividers (not full card gaps) between rows inside
  the same group card. Section-to-section spacing (e.g. "Application" group to "Advanced
  settings" button) is roughly 2-3x a single row's internal padding — a clear grouping signal
  independent of the divider lines.
  Row groups themselves are wrapped in a slightly lighter rounded-rect "card" than the window
  background, which is what visually separates one logical group ("Microphone", "Sound Effects")
  from the next without needing a heading rule.
  Overall the density is closer to macOS System Settings than to a dense developer-tool table:
  comfortable tap/click targets, not compact rows.
- **Typography scale**: at least four sizes in play — a large semi-bold page title ("Modes",
  "Vocabulary", ~22-24pt estimated), a smaller regular-weight description paragraph under it
  (~13-14pt, muted grey), row-label text at a "body" size (~14-15pt, brighter white), and a
  smaller secondary/help line under some labels (~11-12pt, muted grey) — e.g. "Discards the
  active recording" under "Cancel Recording". Sidebar nav items sit at roughly the same size as
  row labels, medium weight when active. All text observed is left-aligned; numeric/value text in
  rows (e.g. history detail values) is right-aligned against its label — a classic key/value row
  pattern.
- **Colour**: this is a near-monochrome dark UI — blacks, near-blacks and greys make up
  ~95% of every surface. The one recurring accent is a blue (used for: primary CTA buttons like
  "Create mode" / "Add website" / "Add Example", active/on toggle switches, active tab pills,
  selected-row highlight ring in History, and hyperlink-styled text like "Text" in the URL-scheme
  card). A second colour appears only functionally: green for an "active/selected" checkmark badge
  in a dropdown list and for a small "●" status dot next to an active mode; red only appears as a
  recording/live indicator ring around the mic glyph in the mini state. I am not recording any hex
  value — Murmure should pick its own accent, not sample this one.
  Icon glyphware for third-party model providers carries its own brand colour (a green leaf-like
  mark, a red/orange swoosh, a teal atom) purely as an identity chip inside dropdown rows — that's
  provider branding, explicitly not something to copy since Murmure is 100% local and has no
  provider roster to render.
- **Iconography style**: simple, thin/regular-weight line icons at small size (~16-18pt) sitting
  inside a small rounded-square coloured swatch (~28x28pt) for sidebar/nav items (Home, Modes,
  Vocabulary, Configuration, Sound, History each get their own tinted square icon) — this reads as
  a standard SF-Symbols-in-a-tinted-tile pattern, consistent with native macOS System Settings
  sidebar conventions post-Ventura. Inline row icons (help "?" circles, gear, speaker) are
  monochrome/template-style, no swatch. A recurring small "atom" glyph gates a couple of advanced
  toggles — read as an "experimental feature" marker, not a settings icon per se.
- **Keyboard-shortcut chips**: shortcuts are rendered as a row of small individual keycap
  capsules (one glyph per capsule: ⌥, ⌘, ⌃, a letter/number), each its own small rounded-rect
  with a subtle border/fill distinct from the row background — not a single string like "⌥⌘⌃0".
  This is the same visual language macOS itself uses in System Settings > Keyboard Shortcuts.
- **State via colour + icon, not shape**: toggles are standard iOS/macOS pill switches (grey =
  off, blue = on); a lock/disable state on some rows is signalled by a small icon (atom, cloud)
  to the immediate left of the toggle rather than by dimming the whole row.

## 2. Per surface

### 2.1 Recording window (floating HUD, in-progress dictation)

Two-row floating capsule, roughly 3-4x wider than tall:
- **Top/stage row** (near-black): centred waveform visualisation, amplitude-modulated vertical
  bars (denser/taller bars = louder audio, sparse dotted bars = near-silence) — this is a classic
  live-amplitude waveform, not a static icon. A small "scan"/brackets glyph sits pinned to the
  left edge of this row (looks like a screen-context / OCR affordance). A small collapse
  (inward-arrows) glyph sits pinned to the top-right corner of this same row.
- **Bottom/control row** (dark grey, visually one shade lighter): left-aligned status — a small
  coloured dot (blue while listening) + a text label ("Voice", i.e. current mode name) + its
  keyboard-shortcut capsule immediately after the label. Right-aligned: a "Stop" text action with
  its own shortcut capsule, a thin vertical divider, then "Cancel" with an "Esc" capsule.
  This left=identity/status, right=actions layout is consistent across every state I saw,
  including the result-display panel (same two buttons reappear per the doc's own callout: "The
  same buttons appear when showing the result in a panel").
- **Collapsed / mini state**: the whole thing shrinks to a single small dark pill containing just
  three icon slots side by side (sparkle/AI icon, app-logo/mark, expand-arrows icon) — no text,
  no waveform. This reads as the "idle, out of the way" affordance, distinct from the full bar
  which appears once recording is active.
- **Even smaller "menu-bar-adjacent" indicator**: a tiny pill showing only a compact mid-line
  waveform icon when idle/quiet, versus a red-ringed circular mic glyph plus a compact live
  waveform when actively recording (visible amplitude ticks). This is the closest analogue in
  Superwhisper to what Murmure's notch treatment needs to do: signal "recording" state in a very
  small footprint via ring colour + a live waveform, not by growing the window.
- **Hierarchy**: waveform (what's happening now) dominates by size and position; status
  text/shortcuts are secondary and small; the mode name is present but understated (just a text
  label, not a icon+name badge) in the in-progress view — identity becomes more prominent later,
  in History.

### 2.2 Mini recording window / menu-bar-adjacent indicator

Covered above (2.1) — it's the same component family collapsed, not a separate design system.
Notably there is no separate "processing" visual distinct from "recording" in what I inspected —
the callouts I could read only distinguish idle vs. recording via the red ring and a denser
waveform; I did not find a screenshot of a "transcribing/processing" spinner state, so I'm not
asserting one exists in Superwhisper's chrome. Treat that as a gap, not a confirmed absence.

### 2.3 Menu bar item and its menu

Menu-bar glyph: a simple monochrome triangular/arrow-like mark (their brand mark — Murmure must
use its own glyph). Clicking opens a standard macOS menu (semi-opaque dark, rounded corners,
system font) with this structure, top to bottom:
1. Primary actions: "Start/Stop Recording" (with shortcut), "Transcribe File…", "History…",
   "Settings…" (with shortcut) — the two shortcut-bearing items are the two used most often.
2. Divider.
3. Context/config submenus: "Input Device ▸", "Select Mode ▸" — both fly-out submenus, i.e.
   settings you change often live directly in the menu rather than requiring a trip to the
   Settings window.
4. Divider.
5. App-lifecycle: version number (disabled/greyed, informational only), "Check for Updates…",
   "Quit" (with ⌘Q).

This is a completely conventional macOS status-item menu — no custom rendering, no icons next to
items, standard system menu font/spacing. The information architecture point worth keeping is the
tiering: frequent action → config shortcut → app lifecycle, each tier divided.

### 2.4 Settings window shell (sidebar + content pane)

- Fixed-width left sidebar (~220-260pt estimated) inside the same window as the content pane —
  not a separate panel/sheet. Sidebar items, top to bottom in the observed order: Home, Modes,
  Vocabulary, Configuration, Sound, History (History carries a small "external link" arrow glyph
  next to it, implying it opens a separate window rather than swapping the content pane in place —
  worth confirming behaviourally, but the visual affordance is distinct from the other five).
  A "Superwhisper PRO" account/tier chip is pinned at the sidebar's bottom edge, separated from
  the nav list by empty space (footer slot). **Murmure has no licence/tier — this footer slot is
  the single clearest place their B2C-SaaS chrome would NOT transfer.**
- Selected sidebar item gets a filled rounded-rect highlight behind the icon+label row (subtle
  grey, not the blue accent) — the accent colour is reserved for actionable buttons, not nav
  state, which is a deliberate restraint worth keeping.
- Content pane: page title (large) + one-to-two-line description paragraph under it in muted grey
  (present on Modes, Vocabulary — this "what is this section for" sentence appears to be a
  standing convention on every top-level section, not just complex ones).
  Below that, grouped row-cards as described in §1's density paragraph.
  A persistent top-right control appears in at least one section (Sound: a "System default"
  input-device selector with a headphone glyph) — i.e. some settings surface a
  contextually-relevant global control pinned to the pane header rather than buried in a row.

### 2.5 A settings section's internal layout (rows, labels, controls, help text)

Two row idioms recur everywhere:
- **Simple toggle row**: label (left) + optional small "?" info-glyph immediately after the label
  (inline, same line, not a tooltip-on-hover-only affordance — it reads as a persistent
  discoverability cue) + toggle switch (right-aligned). Rows of this kind are stacked inside one
  card with hairline dividers, no per-row background change.
- **Shortcut-recorder row**: bold label + a smaller muted description line beneath it (two-line
  left block) + a "reset" icon + the keycap-capsule sequence, right-aligned. This is denser
  information (name, purpose, current binding, reset) but still resolves to the same
  left=meaning/right=value split as every other row in the app.
- **Slider row**: label left, then a horizontal slider filling most of the remaining width with
  small mute/full-volume glyphs bookending it — the only row type observed that breaks the
  simple label+control-on-the-right split into a three-part (label / mute-icon / slider / icon)
  row, reserved for a genuinely continuous value.
- Help text placement is consistently inline-after-label via the "?" glyph, never a separate
  paragraph under the row (that pattern is reserved for the page-level description at the top of
  a whole section, not individual rows) — a strict two-tier explanation system: page-level prose
  for orientation, per-row "?" for the row-level detail on demand.

### 2.6 Modes list

- Page header follows the shell convention (title + one-paragraph explainer + a primary blue CTA
  "Create mode" pinned top-right of the header, not bottom of the list).
  Clicking "Create mode" opens a picker: a vertical list of mode templates, each row = icon in a
  tinted swatch + name, with exactly one row (the recommended default, "Super") carrying a
  muted "Recommended" trailing label — the only badge of its kind observed. Every other row is
  bare. This is a light-touch way to bias a first-time choice without blocking the others.
- Below the header, existing modes render as collapsible rows (chevron/caret at the row's right
  edge) inside one card, each row showing icon + name + a small coloured status dot (green =
  active/currently-selected mode). Expanding a row reveals its editor inline, in place, rather
  than navigating to a new pane — i.e. the list and the editor are the same view, not
  master-detail across two panes.

### 2.7 Mode editor (expanded row content)

Once a mode row is expanded, its fields — in the order observed — are:
1. **Preset** (dropdown, top) — re-selecting this swaps the mode's whole template (Super / Voice
   to text / Message / Mail / Note / Meeting / Custom), i.e. "Preset" is a re-entry point back
   into the same picker used at creation time, not a one-time choice.
2. **Language** (dropdown, unexpanded in what I saw, but present under Preset).
3. **Custom instructions** — a multi-line free-text textarea with a greyed placeholder example
   ("eg. Never use emoji" — I am paraphrasing the pattern, not the exact string) — only relevant
   once Preset = Custom.
4. Two model pickers side by side at the bottom of the visible card: a **language-model** chip
   (icon + name, e.g. a chat/LLM choice) and a **voice-model** chip (icon + name, the
   transcription engine) — each opens its own dropdown. The voice-model dropdown list shows a
   cloud glyph next to hosted-only entries and a small green "check" pill on the currently active
   one; a "Create custom" row sits pinned at the very bottom of that list, after a divider,
   letting the user register an unlisted/self-hosted endpoint.
5. A second, clearly demarcated **"Advanced settings"** sub-screen (its own back-chevron header,
   pushed in from the right rather than an accordion) holds: the two model pickers again, an
   "Activate when using" section (an "Add App" tile with a big "+" glyph, plus a text field +
   "Add website" button, for scoping a mode to specific apps/sites), a "Prompt Context" checkbox
   trio (Application / Copied text / Selected text — what contextual signals feed the prompt),
   and a "Use Examples to enhance the AI output" card holding paired "Spoken input" / "AI Output"
   textareas plus an "Add Example" button (few-shot examples, addable N times).

Overall the editor's information architecture is a clear **basic → advanced ladder**: preset,
language, instructions and the two model chips are "always visible once you expand a mode";
scoping rules, context-source toggles and few-shot examples are one level deeper, behind an
explicit "Advanced settings" push, never both visible at once.

### 2.8 Custom-mode advanced settings (specifically)

Confirmed via 2.7 above: app/website activation scoping, prompt-context checkboxes, and the
examples block are the three things Superwhisper considers "advanced" for a mode. Nothing about
audio/model-quality trade-offs lives here — those stay in the always-visible model-chip row, i.e.
"advanced" in their IA means "scoping and prompt-shaping", not "signal-processing knobs".

### 2.9 History (three-pane view)

- **Left pane**: a search field pinned at the top ("Search recordings"), then a scrolling list of
  recording rows. Each row: a 1-2 line excerpt of the transcribed text as its title (not a
  generic "Recording N"), then a second line with date, time, and duration — duration
  right-aligned. The currently-selected row gets a blue selection ring/border, not just a fill.
  Right-clicking a row opens a small context menu: "Process again", "Report issue", "Delete" —
  three actions, destructive one last.
- **Centre pane**: header bar with the full timestamp (e.g. "Apr 3, 2025 at 3:49 PM") on the
  left and a small icon cluster on the right: copy, reveal-in-folder, then a three-way segmented
  control (**Voice / Segments / AI**) that swaps what the right pane shows, and a final
  panel-toggle icon. Below the header: the actual transcribed/processed text, large and
  readable, left-aligned, no line numbers or chrome. At the very bottom of the centre pane: an
  audio scrubber (elapsed / waveform / total time) with a big centred circular play button and,
  to its right, a small icon row mirroring the header's Voice/Segments/AI affordance (a second,
  redundant entry point to the same tab switch, docked near the transcript's own playback
  controls) plus copy/reveal icons repeated again.
- **Right pane**: a metadata/detail inspector, organised into named sub-groups with the
  same key(left)/value(right) row idiom as Settings: "Recording" (duration, processing times,
  timestamp), "Configuration" (mode used, voice model, language model, language,
  translation/realtime/speakers/system-audio flags, app-context flag, app version), and "Prompt"
  (a scrollable read-only text block showing the actual system prompt sent to the model). This
  right pane is the "show your work" surface — every processing decision the app made for this
  one recording, laid out flat, no nesting.
- The three-way Voice/Segments/AI switch is the single most important IA idea in History: one
  recording, three lenses on it (raw audio-derived voice/text view, a segmented/diarized view,
  and the AI-post-processed view) — switching lenses keeps you on the same row/timestamp.

### 2.10 Vocabulary

Simplest surface inspected: page title + one-paragraph explainer ("helps recognize people's
names, company names, acronyms, slang, or words from other languages" — paraphrased), then one
card holding a single input row: a text field ("New word or sentence"), a secondary
"Replace with…" button (optional correction target), and a primary blue "Add to vocabulary"
button. Everything below that first row (not captured in the screenshot read) presumably lists
existing entries in the same key/value row idiom as everywhere else. The IA point: vocabulary
entry is modelled as two-sided (a word AND what it should be replaced with, if anything) rather
than a flat word list — closer to a text-replacement/autocorrect table than a simple dictionary.

---

## 3. Information architecture

- **Settings grouping** is by function-of-use, not by feature-recency: Home (dashboard/overview),
  Modes (the core customisation surface), Vocabulary (a narrow, single-purpose list), then
  Configuration (shortcuts + app-lifecycle toggles), Sound, History. Modes and Vocabulary sit
  above Configuration/Sound in the sidebar — the app foregrounds "what should dictation produce"
  ahead of "how does the app behave".
- **"Advanced" is reserved for two different things depending on context**, and Superwhisper is
  consistent about which is which: at the *app* level, "Advanced settings" (reached from
  Configuration) gates developer/power-user toggles — experimental-model flag, low-level
  paste/keypress-simulation behaviour, things with a real risk of breaking a workflow if flipped
  blind. At the *mode* level, "Advanced settings" gates scoping and prompt-shaping (app/website
  triggers, context checkboxes, few-shot examples) — a completely different kind of
  "advanced", never signal-processing. Both are named identically but the reader is expected to
  infer which "advanced" from where they clicked in — that's a mild inconsistency worth NOT
  copying literally; Murmure can afford more specific section names.
- **Modes expose options progressively**: preset template → language/instructions → model choice
  (all always visible) → scoping/context/examples (behind one more click). A new user only ever
  sees four fields; a power user can go one level deeper without ever leaving the same mode row.
- **At a glance vs. on demand**: the recording HUD shows only a waveform + a mode name at a
  glance; shortcuts, cancel, and the scan/context glyph are always-visible but visually
  secondary (smaller, dimmer). Settings rows show label + current value/state at a glance;
  the "?" glyph is the on-demand layer for a one-line explanation. History's centre pane shows
  the transcript at a glance; the right-hand inspector is the on-demand "why did it produce this"
  layer — always present (not a hidden drawer) but visually deprioritised (narrower column,
  smaller text) versus the transcript itself.
- **Mode identity travels with output**: the mode used for a given recording is recorded and
  shown back in History's Configuration group, not just applied silently — Superwhisper treats
  "which mode" as provenance metadata worth keeping per-recording, the same way it keeps model
  name and processing time.

## 4. What to keep, what to change for Murmure

### Keep / adapt

- **The two-row stage/control split for the recording HUD.** A near-black waveform "stage" over
  a slightly-lighter "control" strip, separated by a hairline, is a clean, legible pattern that
  translates well to a notch-rooted design: the notch's own black could BE the stage, with a
  control strip only appearing on hover/expansion rather than always-on — which is actually a
  simplification opportunity Superwhisper doesn't have (they have no hardware notch to blend into).
- **Left=identity/status, right=action(s)** as the row-level and bar-level default layout. This
  reads instantly and should carry over to the notch's expanded/hover state and to any
  paste-failure panel.
- **The mini-pill idle/recording indicator** (icon-only pill, ring/colour change on state) is
  close in spirit to what Murmure's idle-notch state needs — small footprint, state via colour +
  a live waveform rather than text. Superwhisper's version lives in a floating window near the
  cursor/menu bar; Murmure's equivalent IS the notch, so the component's *visual grammar*
  (ring colour for state, live waveform for "it's listening") transfers even though the container
  doesn't.
- **The three-way lens switch in History (Voice/Segments/AI)** generalises well even without
  Superwhisper's meeting/speaker features: Murmure still has "raw transcript" vs.
  "AI-post-processed result" as two lenses on one recording, so a two-way (or three-way if a
  segments-like raw-vs-cleaned view is useful) switch is worth keeping, just narrower in scope.
- **The settings sidebar shell** (fixed nav rail, grouped-card content pane, inline "?"
  help-glyph, hairline-divided rows within one card) is a solid, native-feeling pattern with
  nothing SaaS-specific about its *mechanics* — keep the mechanics, drop the PRO-tier footer.
  Given Murmure has far fewer settings (no cloud model roster, no meeting/speaker toggles), the
  sidebar itself may end up over-built for the content — worth checking during implementation
  whether 3-4 sections (Modes, Vocabulary, Configuration/Shortcuts, History) can share a single
  page before building a 6-item rail for a much smaller settings surface.
- **Vocabulary's two-sided word→replacement model** and its single always-visible add-row are
  directly reusable with zero adaptation.
- **Mode editor's basic→advanced ladder** (preset/instructions/models always visible; scoping,
  context-sources, few-shot examples one level deeper) is a good shape for Murmure's own modes,
  once "preset" is redefined around local-only capabilities.
- **Keyboard-shortcut-as-individual-keycaps** rendering (one capsule per key glyph) reads better
  than a single string and is a cheap, native-feeling win in SwiftUI.

### Change / do not carry over

- **No account/licence/tier chip anywhere.** The sidebar-footer "Superwhisper PRO" badge, any
  "check for updates against a licence", any cloud-model-provider iconography (the
  green/red/teal provider glyphs) — none of it applies. Murmure's model roster is local-only, so
  the "voice model" and "language model" dropdown-with-cloud-badges pattern collapses to, at
  most, a single local-model picker with no cloud/local distinction to render at all.
- **Meeting mode, speaker separation, system-audio capture** — visible in Superwhisper as a
  "Meeting" preset in the mode-template picker and as three toggle rows in History's Configuration
  group ("Separate Speakers Enabled", "System Audio Enabled"). Murmure drops all three; the mode
  picker's template list should not include a meeting-shaped entry, and History's inspector loses
  those two rows entirely (not just hidden — they describe capabilities Murmure never has).
- **"Transcribe File…" and any file-import entry point** in the menu — worth a deliberate
  decision rather than an automatic carry-over, since it's not one of the four states named in
  the brief (idle/recording/processing/insert); flag it as optional scope, not required parity.
- **The doc-site "Recommended" badge mechanic** on the create-mode picker is fine to keep as an
  idea (bias a first-time default) but pick different wording/placement rather than mirroring
  their exact badge look.

## 5. Anti-goals

- **Do not reuse their triangular brand mark**, its specific black-to-grey gradient treatment
  seen on every logo card, or the wordmark typography/lockup ("superwhisper" in the bold
  condensed-ish sans seen in the logo screenshots). Murmure needs its own glyph for the menu bar
  and app icon.
- **Do not sample or reuse their exact blue accent, or any provider-brand colour** (the green,
  red/orange, teal chips tied to specific cloud model providers) — those are third-party brand
  colours, not app-owned design tokens, and doubly out of scope since Murmure has no such
  providers to badge.
- **Do not copy their exact UI copy.** Strings like "Start/Stop Recording", "Push to Talk",
  "This helps Superwhisper recognize…", "Use Examples to enhance the AI output" are their
  wording; describe the same *function* in Murmure's own voice.
- **Do not build a licence/tier/account surface just because Superwhisper has one.** It exists
  to gate their cloud features and has no reason to exist in a 100%-local app; adding it "for
  parity" would be pure scope creep against Murmure's stated design.
- **Do not chase pixel-identical layout** for the mode editor's advanced panel or the History
  inspector — several fields there exist only to serve cloud/meeting features Murmure doesn't
  have (separate-speakers flag, system-audio flag, cloud voice-model badges). Copying the row
  list wholesale and just hiding rows later is how unused schema creeps in; design Murmure's
  inspector from its own actual capabilities instead.
- **Treat every visual measurement above as an estimate.** None of these paddings, radii, or type
  sizes were extracted from source (no CSS, no Sketch/Figma file, no pixel-ruler access) — they
  are read off screenshots by eye. Whoever implements this in SwiftUI should treat the numbers as
  a starting point to tune against Apple's own HIG spacing scale, not as a spec to hit exactly.
