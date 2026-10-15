# Ruby MIDI-to-Keyboard Driver (Arch Linux / X11)

A configurable MIDI-note-to-keyboard driver with a Tk GUI, JSON mapping file,
velocity thresholds, per-channel mappings, and held-key tracking.

## Important requirements

- Linux running an **X11** desktop session.
- Ruby with Tk bindings available (`require "tk"` must work).
- ALSA MIDI utilities (`aconnect`, `aseqdump`).
- `xdotool`.

`xdotool` sends simulated key events to the active X11 session. This is not a
Wayland-native implementation.

## Install on Arch Linux

```bash
sudo pacman -S ruby tk tcl alsa-utils xdotool
```

Check your session:

```bash
echo "$XDG_SESSION_TYPE"
```

It should print `x11`.

Check Ruby Tk:

```bash
ruby -e 'require "tk"; puts "Tk OK"'
```

If that fails, your Ruby build does not include compatible Tk bindings. On
some Ruby/mise installations, installing `tk` system packages alone does not
make `require "tk"` work. Use a Ruby installation built with Tcl/Tk support
or adapt the GUI to another toolkit.

Check MIDI utilities and device visibility:

```bash
aconnect -l
aseqdump -l
```

Make the script executable and run it:

```bash
chmod +x midi_driver.rb
ruby midi_driver.rb
```

Connect your MIDI keyboard, click **Refresh**, select its input port, and click
**Start**. Select an existing mapping or enter a channel, note, key, and minimum
velocity, then click **Save / update mapping**. Click **Learn note…** and press
a key on the MIDI keyboard to fill in its channel and note.

## Mapping format

Mapping IDs are `CHANNEL:NOTE`. MIDI channel numbering here is ALSA's zero-based
numbering (0–15). Example:

```json
"0:60": { "key": "space", "min_velocity": 1 },
"1:60": { "key": "ctrl+c", "min_velocity": 50 }
```

These are different mappings because the channel differs.

Common `xdotool` key names include:

- `space`
- `Return`
- `Escape`
- `Tab`
- `a`, `b`, `1`
- `F1`
- `Left`, `Right`, `Up`, `Down`
- `ctrl+c`, `ctrl+shift+Tab`, `alt+F4`

Use xdotool key names, not shell commands. Avoid binding dangerous shortcuts
unless you intentionally want the MIDI keyboard to trigger them.

## Velocity behavior

Each mapping has a `min_velocity` from 1 to 127. A Note On below that threshold
is ignored. Note Off still releases a key if that note previously activated it.
This version uses velocity as a threshold, not as continuous pressure or volume.

## Troubleshooting

### No MIDI ports appear

Run `aconnect -l` and `aseqdump -l` in a terminal. Confirm the device is
connected and visible to ALSA. For PipeWire, make sure ALSA MIDI clients are
available in your session.

### The GUI says `require "tk"` failed

This is a Ruby/Tk packaging issue, common with some custom Ruby builds. Verify
with `ruby -e 'require "tk"'`. The driver needs a Ruby build with Tk support.

### MIDI notes are logged but keyboard events do not work

Confirm `echo "$XDG_SESSION_TYPE"` reports `x11`, and try:

```bash
xdotool key space
```

Some applications ignore synthetic input or require focus. Test in a plain text
editor first.

### Keys seem stuck

The driver releases keys on Note Off and when the application stops. If the MIDI
device disconnects without sending Note Off, stop the driver or close the GUI.
Always test with harmless mappings first.

## Scope / limitations

- Uses ALSA's `aseqdump` text output, so parsing may need adjustment for a
  particular ALSA version or MIDI bridge.
- Simultaneous notes mapped to the same key are tracked independently but this
  basic version sends a key-up when either note is released. For robust
  overlapping same-key chords, a shared-key reference counter should be added.
- The GUI uses Ruby Tk, which may not be enabled in every Ruby distribution.
- Key events target the current X11 session and focused application.
