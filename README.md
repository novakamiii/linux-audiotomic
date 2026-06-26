# audiotomic

Turn any application's audio output into a microphone input — without capturing your
actual mic. Pick an app from the menu, and its audio becomes available as a
"microphone" that any other app can select.

Optionally pipe your real microphone into the mix too, so the virtual mic carries both
your voice and the app's audio.

You still hear everything normally. Only the routing changes.

## How it works

1. Lists every application currently playing audio (by inspecting PipeWire/PulseAudio
   sink-inputs).
2. Shows a picker — you choose which app to reroute.
3. Creates a virtual sink (`module-null-sink`), routes the app's audio into it, and
   loops it back to your speakers so you still hear it.
4. Wraps the null-sink's monitor in a **virtual source** (`module-virtual-source`).
   This is the key step — it creates a proper `Audio/Source` device (not a monitor) that
   shows up in every app's microphone selector.
5. **Optional**: with `--with-mic`, loops your default microphone into the same sink so
   the virtual input carries both the app audio and your voice.

The result: your chosen app appears as **`VirtualMicInput`** in Discord, OBS, Zoom,
Telegram — any app that can select a mic input.

Run the same command again to tear down everything and restore the app's audio to its
original output.

## Dependencies

### Required

- **`pactl`** — from PipeWire (`pipewire-pulse`) or PulseAudio (`pulseaudio-utils`)
- **`notify-send`** — from `libnotify` (for desktop notifications)
- Fish Shell

### Picker (one required)

The script auto-detects which picker you have, in this priority order:

| Picker | Package |
|---|---|
| `kdialog` | `kde-cli-tools` (KDE) |
| `wofi` | `wofi` (wlroots) |
| `rofi` | `rofi` (X11) |
| `fuzzel` | `fuzzel` (wlroots) |
| `fzf` | `fzf` (terminal) |

Install whichever fits your desktop. For example on Arch:

```sh
sudo pacman -S pipewire-pulse libnotify wofi
```

On Debian/Ubuntu:

```sh
sudo apt install pipewire-pulse libnotify-bin wofi
```

## Installation

Put `audiotomic.fish` in your Fish functions directory:

```sh
mkdir -p ~/.config/fish/functions
cp audiotomic.fish ~/.config/fish/functions/
```

Or clone the repo and symlink:

```sh
git clone https://github.com/yourname/audiotomic ~/.config/fish/functions/audiotomic
ln -s ~/.config/fish/functions/audiotomic/audiotomic.fish ~/.config/fish/functions/audiotomic.fish
```

Fish autoloads functions from this directory — no `source` needed.

## Usage

```sh
audiotomic                    # Route app audio to virtual mic
audiotomic --with-mic         # Also pipe your microphone into the virtual input
audiotomic -m                 # Same as --with-mic
audiotomic --help             # Print usage and exit
```

### First run

Shows a picker with all currently-playing applications. Select one to reroute its audio
to the virtual microphone.

The notification tells you the name to select in your target app.

### Second run (teardown)

Run `audiotomic` again (with or without flags) to tear down the virtual mic and restore
everything. The app's audio goes back to your normal output, and the virtual mic input
disappears.

### In your target app

After routing, select **`VirtualMicInput`** as your microphone input in Discord, Zoom,
OBS, Telegram, etc.

### With your real mic (`--with-mic`)

Pass `--with-mic` (or `-m`) to also pipe your default microphone into the virtual
input. Both the app audio and your voice will be heard through `VirtualMicInput`.

This is useful when you want to talk over the app's audio without setting up a separate
mixer in your streaming/recording software.

If no default microphone is detected or the loopback fails, the script warns you but
continues with app-only audio — it's non-fatal.

### Toggle state

The script stores its loaded PulseAudio modules in `/tmp/.audiotomic_modules`. You can
safely delete this file if something goes wrong, but running `audiotomic` again is the
clean way to tear down.

### Picker priority

The script checks pickers in this order: `kdialog` → `wofi` → `rofi` → `fuzzel` → `fzf`.
The first one found wins.

### Help

```sh
audiotomic --help
```

Prints usage information and exits without doing anything.

## Uninstall

```sh
# Teardown active routing first
audiotomic

# Remove the function
rm ~/.config/fish/functions/audiotomic.fish
```

## Technical details

- Uses `module-null-sink` to create a virtual sink (`VirtualMic`) that captures the
  app's audio.
- Uses `module-virtual-source` to wrap the null-sink's monitor into a proper
  `Audio/Source` device (`VirtualMicInput`) with `media.class = "Audio/Source"` rather
  than `"monitor"`. This is what makes it show up in application mic selectors.
- Uses `module-loopback` with `latency_msec=20` to:
  1. Loop the virtual sink's monitor back to the original output (so you hear it).
  2. **Optional**: pipe your default microphone into the virtual sink when `--with-mic`
     is given, mixing both streams into the virtual input.
- The loopback sink is resolved by matching the sink-input's `Sink:` index against
  `pactl list short sinks`. This correctly handles chains (e.g., apps routed through
  EasyEffects) by restoring to the intermediate sink, preserving the full audio
  pipeline.
- State is tracked in `/tmp/.audiotomic_modules` using two line types:
  - `MODULE <id>` — loaded PulseAudio module to unload on teardown (unloaded in
    reverse order — LIFO — so dependencies are released cleanly).
  - `MOVE <input-id> <sink-name>` — stream move to restore on teardown.
- On teardown, moves are restored first (forward pass), then modules are unloaded
  (reverse pass), ensuring no orphaned streams or dangling references.

### Audio flow

**Without mic:**
```
App → VirtualMic (null-sink) → loopback → speakers
         ↓
  VirtualMic.monitor → module-virtual-source → VirtualMicInput (mic)
```

**With `--with-mic`:**
```
Your mic ──→ loopback ──┐
                        ↓
App ─────────────────→ VirtualMic (null-sink) → loopback → speakers
                           ↓
                    VirtualMic.monitor → module-virtual-source → VirtualMicInput
```

## License

MIT
