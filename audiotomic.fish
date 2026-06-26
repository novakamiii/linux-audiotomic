function audiotomic --description "Route a chosen application's audio to a virtual microphone"
    # Reroutes one running application's *playback* stream into a virtual mic
    # input, instead of capturing from a device/source. The app's audio is
    # also looped back to wherever it was originally playing, so you still
    # hear it normally while other apps see it as a "microphone".
    # Run once to enable (shows picker), run again to disable.
    # Deps: pactl (pipewire-pulse) + one of: kdialog wofi rofi fuzzel fzf
    #
    # Usage:
    #   audiotomic                   Route app audio to virtual mic
    #   audiotomic --with-mic        Also pipe your microphone into the virtual input
    #   audiotomic -m                Same as --with-mic

    # ─── PARSE FLAGS ───────────────────────────────────────────────
    set -l with_mic 0
    for arg in $argv
        switch $arg
            case --with-mic -m
                set with_mic 1
            case --help -h
                echo "Usage: audiotomic [--with-mic|-m]"
                echo ""
                echo "Route a playing application's audio to a virtual microphone."
                echo "Run again to disable."
                echo ""
                echo "Flags:"
                echo "  --with-mic, -m    Also pipe your microphone into the virtual input"
                return 0
        end
    end

    set -l STATE /tmp/.audiotomic_modules

    # ─── TOGGLE OFF ──────────────────────────────────────────────
    if test -f $STATE
        # Move any rerouted streams back to their original sink first
        for line in (cat $STATE)
            set -l parts (string split ' ' -- $line)
            if test "$parts[1]" = MOVE
                pactl move-sink-input $parts[2] $parts[3] 2>/dev/null
            end
        end
        # Then unload modules, most recently loaded first
        for line in (tac $STATE)
            set -l parts (string split ' ' -- $line)
            if test "$parts[1]" = MODULE
                pactl unload-module $parts[2] 2>/dev/null
            end
        end
        rm -f $STATE
        notify-send -i audio-input-microphone "Virtual Mic" "App routing stopped"
        return 0
    end

    # ─── COLLECT PLAYING APPLICATIONS (sink-inputs) ──────────────
    set -l si_index
    set -l si_sink
    set -l si_app
    set -l si_media

    set -l cur_index ""
    set -l cur_sink ""
    set -l cur_app ""
    set -l cur_media ""

    for line in (pactl list sink-inputs)
        set -l t (string trim $line)

        if string match -qr '^Sink Input #[0-9]+$' -- $t
            if test -n "$cur_index"
                set si_index $si_index $cur_index
                set si_sink $si_sink $cur_sink
                set si_app $si_app $cur_app
                set si_media $si_media $cur_media
            end
            set cur_index (string match -rg '^Sink Input #([0-9]+)$' -- $t)
            set cur_sink ""
            set cur_app ""
            set cur_media ""
        else if string match -qr '^Sink: ' -- $t
            set cur_sink (string replace 'Sink: ' '' $t)
        else if string match -qr '^application\.name = "' -- $t
            set cur_app (string match -rg '^application\.name = "(.*)"$' -- $t)
        else if string match -qr '^media\.name = "' -- $t
            set cur_media (string match -rg '^media\.name = "(.*)"$' -- $t)
        end
    end
    # flush last entry
    if test -n "$cur_index"
        set si_index $si_index $cur_index
        set si_sink $si_sink $cur_sink
        set si_app $si_app $cur_app
        set si_media $si_media $cur_media
    end

    if test (count $si_index) -eq 0
        notify-send -i dialog-error "Virtual Mic" "No applications are currently playing audio"
        return 1
    end

    # ─── DISPLAY ENTRIES ─────────────────────────────────────────
    set -l display_entries
    for i in (seq (count $si_index))
        set -l label $si_app[$i]
        test -z "$label" && set label $si_media[$i]
        test -z "$label" && set label "Unknown application"
        if test -n "$si_app[$i]"; and test -n "$si_media[$i]"; and test "$si_media[$i]" != "$si_app[$i]"
            set label "$label — $si_media[$i]"
        end
        set display_entries $display_entries "🎵  $label"
    end

    # ─── PICKER ──────────────────────────────────────────────────
    set -l chosen_index ""

    if command -q kdialog
        # kdialog --menu returns the tag (sink-input index), not the label
        set -l kargs
        for i in (seq (count $si_index))
            set kargs $kargs $si_index[$i] $display_entries[$i]
        end
        set chosen_index (kdialog \
            --title "Stream App to Virtual Mic" \
            --menu "Select an application whose audio should become microphone input:" \
            $kargs 2>/dev/null)
    else
        set -l chosen_display ""
        if command -q wofi
            set chosen_display (printf '%s\n' $display_entries | \
                wofi --dmenu --prompt "Stream app to mic:" --insensitive)
        else if command -q rofi
            set chosen_display (printf '%s\n' $display_entries | \
                rofi -dmenu -p "Stream app to mic:")
        else if command -q fuzzel
            set chosen_display (printf '%s\n' $display_entries | \
                fuzzel --dmenu --prompt "Stream app to mic: ")
        else if command -q fzf
            set chosen_display (printf '%s\n' $display_entries | \
                fzf --prompt "Stream app to mic: " --reverse --height 40%)
        else
            echo "audiotomic: no picker found — install kdialog, wofi, rofi, fuzzel, or fzf"
            return 1
        end

        # Reverse-look up sink-input index from the chosen display string
        for i in (seq (count $display_entries))
            if test "$display_entries[$i]" = "$chosen_display"
                set chosen_index $si_index[$i]
                break
            end
        end
    end

    test -z "$chosen_index" && return 0  # user cancelled

    # ─── RESOLVE THE APP'S CURRENT SINK (so we can restore it) ───
    set -l orig_sink_idx ""
    set -l chosen_label ""
    for i in (seq (count $si_index))
        if test "$si_index[$i]" = "$chosen_index"
            set orig_sink_idx $si_sink[$i]
            set chosen_label $display_entries[$i]
            break
        end
    end

    set -l orig_sink_name ""
    for line in (pactl list short sinks)
        set -l fields (string split \t -- $line)
        if test "$fields[1]" = "$orig_sink_idx"
            set orig_sink_name $fields[2]
            break
        end
    end

    if test -z "$orig_sink_name"
        notify-send -i dialog-error "Virtual Mic" "Couldn't resolve the app's current output device"
        return 1
    end

    # ─── CREATE VIRTUAL SINK ─────────────────────────────────────
    set -l state_lines

    set -l sink_mid (pactl load-module module-null-sink \
        sink_name=VirtualMic \
        'sink_properties=device.description=Virtual Microphone' 2>/dev/null)

    if test -z "$sink_mid"
        notify-send -i dialog-error "Virtual Mic" \
            "Failed to create virtual sink.\nIs PipeWire/PulseAudio running?"
        return 1
    end
    set state_lines $state_lines "MODULE $sink_mid"

    # ─── REROUTE THE APP'S STREAM INTO IT ────────────────────────
    if not pactl move-sink-input $chosen_index VirtualMic 2>/dev/null
        pactl unload-module $sink_mid 2>/dev/null
        notify-send -i dialog-error "Virtual Mic" \
            "Failed to reroute audio for:\n$chosen_label"
        return 1
    end
    set state_lines $state_lines "MOVE $chosen_index $orig_sink_name"

    # ─── LOOP BACK TO THE ORIGINAL OUTPUT SO YOU STILL HEAR IT ───
    set -l loop_mid (pactl load-module module-loopback \
        source=VirtualMic.monitor \
        sink=$orig_sink_name \
        latency_msec=20 2>/dev/null)

    if test -z "$loop_mid"
        pactl move-sink-input $chosen_index $orig_sink_name 2>/dev/null
        pactl unload-module $sink_mid 2>/dev/null
        notify-send -i dialog-error "Virtual Mic" \
            "Failed to loop audio back to your speakers"
        return 1
    end
    set state_lines $state_lines "MODULE $loop_mid"

    # ─── CREATE A VIRTUAL SOURCE so it shows up as an Input Device ──
    set -l vsrc_mid (pactl load-module module-virtual-source \
        source_name=VirtualMicInput \
        master=VirtualMic.monitor 2>/dev/null)

    if test -z "$vsrc_mid"
        pactl unload-module $loop_mid 2>/dev/null
        pactl move-sink-input $chosen_index $orig_sink_name 2>/dev/null
        pactl unload-module $sink_mid 2>/dev/null
        notify-send -i dialog-error "Virtual Mic" \
            "Failed to create virtual source.\nYour audio still plays, but no mic input was created."
        return 1
    end
    set state_lines $state_lines "MODULE $vsrc_mid"

    # ─── OPTIONAL: PIPE MICROPHONE INTO THE VIRTUAL SINK ─────────
    set -l mic_piped 0
    if test "$with_mic" -eq 1
        set -l default_source (pactl info | string match -rg '^Default Source: (.+)$')
        if test -z "$default_source"
            notify-send -i dialog-warning "Virtual Mic" \
                "Could not detect your microphone.\nPiping only app audio."
        else
            set -l mic_mid (pactl load-module module-loopback \
                source=$default_source \
                sink=VirtualMic \
                latency_msec=20 2>/dev/null)
            if test -z "$mic_mid"
                notify-send -i dialog-warning "Virtual Mic" \
                    "Could not pipe mic into virtual input.\nApp audio is still routed."
            else
                set state_lines $state_lines "MODULE $mic_mid"
                set mic_piped 1
            end
        end
    end

    printf '%s\n' $state_lines > $STATE

    # ─── NOTIFY ──────────────────────────────────────────────────
    if test "$mic_piped" -eq 1
        notify-send -i audio-input-microphone "Virtual Mic (with mic)" \
            "Routing: $chosen_label + your mic\n\nIn your app, select 'VirtualMicInput' as microphone"
    else
        notify-send -i audio-input-microphone "Virtual Mic" \
            "Routing: $chosen_label\n\nIn your app, select 'VirtualMicInput' as microphone"
    end
end
