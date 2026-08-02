# Keyboard shortcuts

MDSLens exposes its desktop keyboard commands from **Settings > Keyboard
shortcuts**. The defaults adapt to the host platform: macOS uses Command,
Windows and Linux use Ctrl, and Linux also offers H/J/K/L navigation. A
hardware keyboard is required on mobile devices; touch and stylus controls are
unchanged.

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
