# Can Murmure read back what Louis actually sent?

**Verdict: not feasible.** In the applications Louis dictates into, macOS Accessibility does not
expose the text he edits. The one app that exposes anything at all — Ghostty — exposes a rendered
screen rather than a field, never signals that it changed, and offers no way to locate Murmure's
own paste inside it. Slack and Cursor expose nothing whatsoever. The idea is sound and the signal
it would produce is the one this project actually lacks; the operating system simply does not
hand it to us on this machine.

This document reports what was measured, on this machine, on 2026-09-01, against the applications
that were already running. It is a feasibility finding, not a design, and no product code was
written.

---

## 1. How this was measured

Seven read-only probes, written in Swift and compiled with the system `swiftc`, using
`AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue`, `AXUIElementCopyAttributeNames`,
`AXUIElementCopyParameterizedAttributeNames`, `AXUIElementIsAttributeSettable`, `AXObserverCreate`
and `AXObserverAddNotification`.

The probe process reported `AXIsProcessTrusted() == true`, inherited from the terminal host
(Cursor) that owns this session. No permission dialog appeared and none could have: the prompting
variant `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: true)` was never called. This
confirms the premise the investigation started from — **reading AX attributes needs no grant beyond
the Accessibility permission Murmure already holds** for `CGEvent.post` in
`Murmure/PasteInserter.swift`. That premise is the one part of the idea that survives.

Constraints honoured throughout, and verifiable in the probe sources: no attribute value was ever
printed, logged or written to disk — only roles, attribute *names*, character *counts*, and
truncated SHA-256 digests used solely to detect that a value had changed. Nothing was written to
any element, no event was posted, no click was synthesised, `NSPasteboard` was never touched, and
no application was launched or quit. `AXReplaceRangeWithText` and `AXManualAccessibility` were
found but deliberately not exercised — both are writes into another process.

---

## 2. Per-app results, measured

| App | State | Focused element | `kAXValue` | `kAXSelectedText` | `AXValueChanged` |
|---|---|---|---|---|---|
| **Ghostty** `com.mitchellh.ghostty` | running | `AXTextArea` (17 attributes, stable identity over 12 s) | **readable** — the rendered screen, 10 892–11 041 chars, 84 lines | `noValue` | registration succeeds, **0 delivered in 90 s while the value changed 82 times** |
| **Slack** `com.tinyspeck.slackmacgap` | running | `apiDisabled` | `apiDisabled` | — | — |
| **Cursor** `com.todesktop.230313mzl4w4u92` | running, **frontmost** | `noValue` | window tree is nested empty `AXGroup`s, `AXValue` len 0 at every depth | — | 0 |
| **Claude Desktop** `com.anthropic.claudefordesktop` | installed, **not running** | not tested | not tested | not tested | not tested |
| **Terminal.app** | installed, **not running** | not tested | not tested | not tested | not tested |
| **iTerm2** | **not installed** | n/a | n/a | n/a | n/a |
| Finder (control) | running | — | — | — | **4 delivered in 45 s** |
| Notes, Safari, Notion, Excel | running, backgrounded | `noValue` | inconclusive — see §6 | — | — |

The system-wide element, `AXUIElementCreateSystemWide()` + `kAXFocusedUIElementAttribute`, returned
`cannotComplete` on every one of 20 consecutive attempts spaced one second apart, while Cursor was
frontmost. The generic entry point that an implementation would naturally reach for does not
resolve at all in his working context.

Slack's and Cursor's failures are **not** artefacts of those apps being unfocused. Slack's
*application* element reports zero attributes and `apiDisabled` — a structural fact about the
process, independent of focus. Cursor was measured while it was the frontmost application, with a
window present, and still yielded no focused element and an empty tree.

---

## 3. The three walls, in order

### Wall 1 — What Ghostty exposes is a screen, not a field

Ghostty's focused element is a single `AXTextArea` whose `kAXValue` is the whole terminal render.
`AXVisibleCharacterRange` covers the entire value (`loc=0 len=10892`), `kAXValue` is not settable,
and `AXSelectedText` returns `noValue`. A character census of one sample: 11 041 characters over
84 lines, **1 404 box-drawing characters (U+2500–U+257F) on 11 of the 84 lines**, 3 417 spaces,
244 further non-ASCII scalars, line widths ranging from 0 to 429 across 38 distinct values.

That is a picture of the Claude Code TUI, not of an input field. The text Murmure pastes is drawn
inside a framed box, hard-wrapped at the terminal width, prefixed per line by border glyphs. **It
does not appear in the buffer as a contiguous substring of what we pasted**, so a diff against our
own output has nothing to anchor to. Recovering "the text currently in the input box" would mean
re-implementing the TUI's rendering in reverse, for every TUI he uses, and re-doing it whenever one
of them changes its layout.

The element also has no geometry (`AXSize` is `0.0 x 0.0`), the application reports
`AXWindows` count 0, and `AXFocusedWindow` returns the `AXApplication` itself whose only child is
the menu bar. There is therefore **no way to attribute the text area to a window or a tab** — with
several Ghostty tabs open there is one focused element and nothing to say which surface it belongs
to. The only parameterized attribute offered is `AXReplaceRangeWithText`: Ghostty gives us a way to
*write* a range and no way to *read* one.

### Wall 2 — "Sent" is not observable

This is the cleanest negative result of the investigation, and it was measured with a control
rather than assumed.

`AXObserverAddNotification` returned `success` for `AXValueChanged`, `AXSelectedTextChanged`,
`AXFocusedUIElementChanged` and `AXUIElementDestroyed`, registered both on Ghostty's application
element and directly on the `AXTextArea`. Across three listening windows totalling 90 seconds,
during which polling showed the buffer's digest change **82 times**, Ghostty delivered
**zero notifications**.

Two controls rule out a broken harness. A `Timer` on the same run loop fired 20 times in 20 seconds
and 45 times in 45 seconds, so the run loop was live and any posted notification would have been
delivered. And in the same 45-second window, with identical code and identical registration,
**Finder delivered 4 `AXValueChanged` notifications**. The plumbing works; Ghostty does not use it.

So there is no event-driven signal. Detection would have to be a polling loop — and the buffer
changes roughly once per second on its own, from spinners and streaming output, entirely
independently of anything Louis types. Polling would sample noise at a far higher rate than signal.

Worse, the value is the *visible screen* with no scrollback (inferred, see §6). When Louis presses
Enter, the TUI clears the input box and the sent text scrolls up into the transcript; as more output
arrives it leaves the readable region altogether. **The final state we need to capture is the one
state that is guaranteed to be evicted.**

### Wall 3 — In the other two apps there is nothing to read

Slack: zero attributes on the application element, `apiDisabled` for everything. Chromium builds its
accessibility tree lazily and Slack's is entirely off. The known lever is setting
`AXManualAccessibility = true` on the application element — a **write into another process** that
permanently turns on Slack's full accessibility tree, at a CPU and memory cost to Slack, for as long
as it runs. It was not exercised, per the constraints. It is the only untried avenue in this
investigation, and even if it worked it would leave Walls 2 and 3 untouched for Slack specifically
and would do nothing at all for the terminals, which is where he actually dictates.

Cursor: `AXManualAccessibility` and `AXEnhancedUserInterface` are both present on the application
element, so its tree is partly on — yet the window contains nothing but `AXGroup` nested inside
`AXGroup` to depth 4, every one with an empty `AXValue`, and no focused element. The editor and its
integrated terminal (xterm.js) publish nothing.

---

## 4. Observable versus inferred

**Observable, measured on this machine:** every cell in the table in §2; the character census; the
82 buffer changes against 0 Ghostty notifications against 4 Finder notifications; the 20 consecutive
`cannotComplete` results from the system-wide element; `AXReplaceRangeWithText` as Ghostty's sole
parameterized attribute; `AXIsProcessTrusted() == true` without a prompt.

**Inferred, and flagged as such:**

- *Ghostty's value is the visible screen with no scrollback.* Inferred from `AXVisibleCharacterRange`
  covering the whole value and from the line count staying at 84 while the character count moved
  between 10 892 and 11 041. Not confirmed by geometry, because Ghostty reports its size as 0×0.
- *The pasted text is not a contiguous substring of the buffer.* Inferred from the box-drawing census
  and from how a TUI must render a bordered input box. Not directly confirmed, because confirming it
  would have required pasting a known string into his live session.
- *Claude Desktop behaves like the other Electron apps.* This is a guess and nothing more. It was
  not running and was not launched.

---

## 5. If the read worked, would the diff be a correction signal?

Answering this on its merits, because the reasoning survives the verdict and bears on any future
attempt.

**Sometimes, and the "sometimes" has to be enforced by discarding almost everything.** Louis may fix
one word; he may rewrite the sentence; he may paste our text and then type four more paragraphs
before sending. Only the first is a correction. A workable filter would require *all* of: a long
common subsequence covering most of our text, a small number of changed spans (say at most three),
each span short (a few words), and a length ratio close to one. Anything else is discarded whole —
no partial credit, because a half-matched rewrite is exactly the case that looks like a correction
and is not.

**The failure mode is asymmetric and silent.** A false positive does not announce itself. It writes a
term into the vocabulary, that term biases every subsequent transcription, and the damage accumulates
across sessions with no moment at which anyone is shown what happened. That is worse than having no
vocabulary at all. The mitigation is not a better classifier: it is to **never auto-adopt**. Every
candidate goes into a queue Louis confirms item by item, which downgrades the classifier's job from
"be right" to "be a tolerable filter for a human queue" — a far weaker requirement, and the only
honest one.

**And the distinction Louis drew must be carried into whatever consumes the signal.** His objection to
putting `paire → PR` in the vocabulary is correct and it is a design constraint, not an anxiety. A
*replacement* forces the substitution and destroys "une paire de chaussures" every time. Whisper's
`initialPrompt` biases instead: adding `PR` to the prompt makes that token more likely without ever
forcing it, so both readings stay available and context decides. The captured diff's correct
destination is therefore the prompt vocabulary, never a find-and-replace table. Any future work on
this signal that lands it in a replacement map has misused it.

---

## 6. The privacy bound

Reading the focused element means Murmure sees text Louis never dictated. Today the app sees exactly
two things: audio he pressed a key to record, and the text it produced from that audio. Reading a
focused field would let it see **the contents of whatever he happens to be looking at** — and in
Ghostty's case, reading the focused element *is* reading the entire visible terminal: the whole
Claude Code conversation, source under review, anything echoed to the screen. That is a categorical
change in what the app can observe, not an increment.

The tightest bound worth proposing, stated as rules an implementation could be held to:

1. **Armed only by a dictation.** The read window opens when Murmure pastes and closes at the earlier
   of a fixed timeout or the first read that satisfies the stop condition. At no other moment may any
   foreign element be read.
2. **One element only.** Only the element that held focus at paste time. If focus has moved, the
   window closes immediately with no read at all.
3. **Nothing read touches disk.** The buffer lives in memory for the life of the window and is
   discarded. Only extracted candidate span *pairs* — a word or short phrase, before and after — may
   outlive it.
4. **Only spans overlapping our own paste are extractable.** Everything outside the region Murmure
   itself wrote is discarded before any persistence.
5. **No persistence without per-item confirmation** by Louis.
6. **Never read an element whose value is a screen buffer rather than a field.**

**Be clear that this bound cannot be held where it matters.** Rule 4 is unenforceable in Ghostty,
because the region occupied by our paste cannot be located in a reflowed TUI render — so "discard
everything outside it" has no definable inside. And rule 6, applied honestly, disqualifies Ghostty
outright. The bound is tight only in apps that expose a real field, which are not the apps he uses.

---

## 7. What could not be determined

- **Claude Desktop.** Installed, not running, not launched per the constraints. Entirely untested.
  It is the one remaining app in his stated set that might behave differently, and it is a real gap.
- **Terminal.app.** Not running, not launched. Its AX behaviour differs from Ghostty's and is
  reputed to be richer; this was not verified and no claim is made either way.
- **Whether Slack becomes readable under `AXManualAccessibility`.** Not exercised, because it is a
  write into another process.
- **Notes, Safari, Notion, Excel.** All returned `noValue`, which is the correct answer for a
  background app with no active text cursor and therefore says nothing about whether they would be
  readable when focused. These rows are inconclusive, not negative.
- **Whether Ghostty exposes scrollback.** See §4; inferred, not confirmed.

---

## 8. What this does not close off

Not a plan, and not in scope — but the finding points somewhere, and it would be unhelpful to leave
it unsaid.

The signal Louis described is the right signal. What makes it unreachable is only the choice of
*where* to observe it: in someone else's process, through an API those processes do not implement.
Murmure already owns a moment when the text is in its own hands and already has a surface on screen.
A correction made **inside Murmure**, before or just after the paste, produces the identical pair —
our text and his — with a perfect before/after, no diff heuristics, no classifier, no polling, no
foreign process, and no expansion at all of what the app can see. It also needs no Accessibility
read, and it cannot be poisoned by a wholesale rewrite because the rewrite is visibly his.

That trade is worth putting to Louis: the Accessibility route buys the ability to capture a
correction he makes *elsewhere*, and the measurements say it cannot deliver it in his apps anyway.
