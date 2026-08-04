# Keyboard shortcuts

MDSLens exposes its desktop keyboard commands from **Settings > Keyboard
shortcuts**. The defaults adapt to the host platform: macOS uses Command and
Windows/Linux use Ctrl. Arrow keys and H/J/K/L navigation are available on all
desktop platforms. A hardware keyboard is required on mobile devices; touch
and stylus controls are unchanged.

## Keyboard mode and Vim mode

**Settings > Keyboard mode** opens a dedicated mode panel. Standard shortcuts
remain the default; **Vim keyboard-only** is opt-in and keeps all ordinary
shortcuts while adding a complete keyboard-first workspace.

In Vim mode, press `:` (Shift+;) outside a text field to search every command,
then press Enter to run it. Use `j`/`k` or the arrow keys to move through the
results, and Escape to cancel. The same settings list is available without a
pointer through the `Open settings` command in that palette.

For the waveform workspace, `h`/`j`/`k`/`l` select the neighboring panel, `c`
opens the selected panel's context menu, and the menu itself accepts
`h`/`j`/`k`/`l` plus Enter. In Zoom/Move mode, Shift+H/J/K/L pans the selected
plot and `[`/`]` zoom out/in; `0` resets its scale. `p` and `z` switch Point
and Zoom/Move modes. In Point mode, h/l step the active crosshair. Open and
recent configurations are available with `o` and Shift+O, and save with `s`.
Tab/Shift+Tab and Enter/Space continue to operate focused controls and dialog
buttons normally.

## Shortcut sequences

A command can have a primary and an alternative shortcut. Each shortcut may be
one to four key strokes. For example, `Ctrl+G, R` means press Ctrl+G, release
it, then press R. The dispatcher waits briefly after a prefix so a shorter
command is not triggered before a longer sequence can complete. Pressing an
unrelated key completes a pending shorter command, if one exists, and starts a
new match with that key.

The settings are stored in the normal MDSLens preferences. Existing settings
that used the former `Ctrl/Cmd+Shift+R` Reset All command are migrated once so
that the same gesture becomes Refresh; Reset All receives the new
`Ctrl/Cmd+A, R` default. Explicitly cleared shortcuts remain cleared.

## Scope

- General commands open configuration, internal web pages, save configuration,
  change interaction mode, focus Shot, and refresh or stop loading.
- Global commands open Rate, Layout Setup, and multi-panel export.
- Current-panel commands open Rate, Data Source Setup, Panel Setup, or export
  the selected panel.
- Panel navigation selects the neighboring panel without changing the loaded
  data. Point navigation steps the synchronized crosshair when Point mode is
  active.
- Popup menus keep their own native focus and arrow/Enter behavior. Configured
  menu navigation shortcuts, including one-to-four-stroke sequences, are
  handled inside the open menu; Vim mode additionally maps H/J/K/L there. The
  page dispatcher does not steal those events.

While an input field is being edited, ordinary navigation and mode shortcuts
are suppressed so typing remains safe. Shot history navigation, global file
commands, refresh, and Escape keep working; this matches the desktop workflow
without making a text field unusable.
