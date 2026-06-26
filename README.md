# audiotomic

Make any app's audio show up as a microphone input. Pick an app that's currently playing sound, and it becomes selectable as a mic in Discord, OBS, Zoom, or anything else that reads mic input.

You still hear the audio normally. Only the routing changes.

Optionally mix in your real mic so both your voice and the app audio go through the same virtual input.

Run it once to enable. Run it again to disable and restore everything.

## Modes

| Mode | What it does |
|---|---|
| `audiotomic` | Pick one or more apps to route as a mic (Application mode) |
| `audiotomic --desktop` | Route all desktop audio (everything through your speakers) as a mic |
| `audiotomic --with-mic` | Mix your real mic into the virtual input alongside the routed audio |

Modes can be combined: `audiotomic --desktop --with-mic` captures everything playing plus your voice.

## Usage

```sh
audiotomic                        # Pick apps to route (shows a picker)
audiotomic -d / --desktop         # Route all desktop audio instead
audiotomic -m / --with-mic        # Also include your real microphone
audiotomic -d -m                  # Desktop audio + mic combined
audiotomic --help                 # Print usage and exit
```

After enabling, select **`VirtualMicInput`** as your microphone in Discord, OBS, Zoom, etc.

Run `audiotomic` again at any time to stop and restore your original audio setup.

### Picking apps (Application mode)

A picker appears listing every app currently playing audio. You can select multiple apps — their audio gets merged into the same virtual input.

- **kdialog**: tick boxes, select multiple at once
- **wofi / rofi / fuzzel / fzf**: pick one at a time; a "Done" option appears to finish

## Installation

```sh
mkdir -p ~/.config/fish/functions
cp audiotomic.fish ~/.config/fish/functions/
```

Fish autoloads functions from that directory — no `source` or restart needed.

## Uninstall

```sh
audiotomic        # stop active routing first
rm ~/.config/fish/functions/audiotomic.fish
```

## Dependencies

### Required

**`pactl`** — the command-line interface to PipeWire or PulseAudio. This is what audiotomic uses to create virtual devices and move audio streams around. It comes with:
- `pipewire-pulse` if you're on PipeWire (most modern distros: Arch, Fedora, Ubuntu 22.04+)
- `pulseaudio-utils` if you're on PulseAudio

To check which you have: `pactl info | grep "Server Name"`

**`notify-send`** — sends the desktop notifications that confirm routing is active and tell you which mic name to select. Part of `libnotify` on most distros.

**Fish Shell** — audiotomic is written as a Fish function and requires Fish 3.x or later.

### Picker (one required)

audiotomic needs a way to display a list and let you pick from it. Install whichever fits your setup:

| Picker | Best for | Package |
|---|---|---|
| `kdialog` | KDE | `kde-cli-tools` |
| `wofi` | Wayland (wlroots/Hyprland) | `wofi` |
| `rofi` | X11 or Wayland (XWayland) | `rofi` |
| `fuzzel` | Wayland, minimal | `fuzzel` |
| `fzf` | Terminal-only setups | `fzf` |

The script checks for them in that order and uses the first one it finds. Only one is needed.

**Arch:**
```sh
sudo pacman -S pipewire-pulse libnotify wofi
```

**Debian/Ubuntu:**
```sh
sudo apt install pipewire-pulse libnotify-bin wofi
```

## How it works

audiotomic uses PipeWire/PulseAudio's module system to rewire audio on the fly:

1. Creates a virtual sink (`module-null-sink`) — a silent audio destination that captures whatever gets sent to it
2. Moves your chosen app's stream into that sink (or in Desktop mode, mirrors your speakers into it)
3. Loops the virtual sink's output back to your real speakers so you still hear everything
4. Wraps the virtual sink's monitor in a `module-virtual-source` — this makes it show up as a proper microphone input (`VirtualMicInput`) in every app's device list, rather than appearing as a monitor device

All state (loaded modules, moved streams) is saved to `/tmp/.audiotomic_modules`. Running audiotomic again reads that file, restores each stream to its original output, and unloads the modules in reverse order. If something goes wrong, you can delete that file and manually run `pactl unload-module <id>` for any leftover modules.

## License

MIT
