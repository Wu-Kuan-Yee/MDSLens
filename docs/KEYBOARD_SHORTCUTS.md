# Keyboard shortcuts

MDSLens exposes its desktop keyboard commands from **Settings > Keyboard
shortcuts**. The defaults adapt to the host platform: macOS uses Command and
Windows/Linux use Ctrl. Arrow keys and H/J/K/L navigation are available on all
desktop platforms. A hardware keyboard is required on mobile devices; touch
and stylus controls are unchanged.

## Vim mode

**Settings > Vim mode (keyboard-only)** is an independent, opt-in mode and is
off by default. When enabled, the workspace keeps the ordinary shortcuts but
adds a keyboard-first command line: press `:` (Shift+;) anywhere outside a text
field, type a command name, and press Enter. Use `j`/`k` or the arrow keys to
move through matching commands, and Escape to cancel. Every application action
listed in the shortcut settings is available from this command line, so the
main workspace can be operated without a mouse. Tab/Shift+Tab and Enter/Space
continue to operate focused controls and dialog buttons normally.

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
  handled inside the open menu; the page dispatcher does not steal those
  events.

While an input field is being edited, ordinary navigation and mode shortcuts
are suppressed so typing remains safe. Shot history navigation, global file
commands, refresh, and Escape keep working; this matches the desktop workflow
without making a text field unusable.
