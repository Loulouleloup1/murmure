# Design reference

`superwhisper-ui/` holds 74 screenshots from Superwhisper's public documentation
(mintcdn.com), downloaded as **study material** for layout, spacing and information
architecture. They are git-ignored on purpose: they are someone else's assets and must
never ship inside Murmure. Every pixel of Murmure's UI is drawn from scratch.

Source pages: `superwhisper.com/docs/get-started/{interface-rec-window, interface-menu-bar,
interface-history, interface-vocabulary, settings-overview, settings-advanced,
settings-shortcuts, settings-sound}` and `superwhisper.com/docs/modes/{modes, custom, super,
switching-modes}`.

A screen capture of the locally installed app was attempted and is currently **blocked**:
`screencapture` fails with "could not create image from display" because the terminal running
Claude Code has no **Screen Recording** permission. To unblock, grant it in System Settings →
Privacy & Security → Screen Recording, then re-run the capture. The documentation screenshots
cover the same surfaces, so this is not on the critical path.

`ui-design-notes.md` distils these screenshots into the design language Murmure targets.
