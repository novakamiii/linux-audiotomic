function audiotomic --description "Route application or desktop audio to a virtual microphone"
    # Reroutes audio into a virtual mic input visible to recording apps.
    # Three modes:
    #   (default)    Pick one or more running apps; their audio becomes the mic
    #   --desktop    Capture all desktop audio (everything through your speakers)
    #   --with-mic   Also pipe your real microphone into the virtual input
    #
    # The original audio always loops back so you still hear it normally.
    # Run once to enable (shows picker if needed), run again to disable.
    # Deps: pactl (pipewire-pulse) + one of: kdialog wofi rofi fuzzel fzf

    # ─── PARSE FLAGS ───────────────────────────────────────────────
    set -l with_mic 0
    set -l desktop_mode 0
    for arg in $argv
        switch $arg
            case --with-mic -m
                set with_mic 1
            case --desktop -d
                set desktop_mode 1
            case --help -h
                echo "Usage: audiotomic [--desktop|-d] [--with-mic|-m]"
                echo ""
                echo "Route audio to a virtual microphone (VirtualMicInput)."
                echo "Run again to disable."
                echo ""
                echo "Modes:"
                echo "  (default)           Pick one or more apps to route (Application mode)"
                echo "  --desktop, -d       Capture all desktop audio (Desktop audio mode)"
                echo ""
                echo "Flags:"
                echo "  --with-mic, -m      Also pipe your real microphone into the virtual input"
                return 0
        end
    end

    set -l STATE /tmp/.audiotomic_modules

    # ─── TOGGLE OFF ──────────────────────────────────────────────
    if test -f $STATE
        for line in (cat $STATE)
            set -l parts (string split ' ' -- $line)
            if test "$parts[1]" = MOVE
                pactl move-sink-input $parts[2] $parts[3] 2>/dev/null
            end
        end
        for line in (tac $STATE)
            set -l parts (string split ' ' -- $line)
            if test "$parts[1]" = MODULE
                pactl unload-module $parts[2] 2>/dev/null
            end
        end
        rm -f $STATE
        notify-send -i audio-input-microphone "Virtual Mic" "Routing stopped"
        return 0
    end

    # ─── RESOLVE DEFAULT SINK (needed for Desktop mode and loopback) ──
    set -l default_sink (pactl info | string match -rg '^Default Sink: (.+)$')
    if test -z "$default_sink"
        notify-send -i dialog-error "Virtual Mic" \
            "Could not detect your default audio output.\nIs PipeWire/PulseAudio running?"
        return 1
    end

    # ─── DESKTOP MODE ─────────────────────────────────────────────
    if test "$desktop_mode" -eq 1
        set -l state_lines

        # Virtual null sink
        set -l sink_mid (pactl load-module module-null-sink \
            sink_name=VirtualMic \
            'sink_properties=device.description=Virtual Microphone' 2>/dev/null)
        if test -z "$sink_mid"
            notify-send -i dialog-error "Virtual Mic" \
                "Failed to create virtual sink.\nIs PipeWire/PulseAudio running?"
            return 1
        end
        set state_lines $state_lines "MODULE $sink_mid"

        # Loopback: desktop monitor → virtual sink (captures all desktop audio)
        set -l desktop_loop_mid (pactl load-module module-loopback \
            source="$default_sink.monitor" \
            sink=VirtualMic \
            latency_msec=20 2>/dev/null)
        if test -z "$desktop_loop_mid"
            pactl unload-module $sink_mid 2>/dev/null
            notify-send -i dialog-error "Virtual Mic" \
                "Failed to loopback desktop audio into virtual sink"
            return 1
        end
        set state_lines $state_lines "MODULE $desktop_loop_mid"

        # Loopback: virtual sink monitor → original output (so you still hear it)
        set -l hear_loop_mid (pactl load-module module-loopback \
            source=VirtualMic.monitor \
            sink=$default_sink \
            latency_msec=20 2>/dev/null)
        if test -z "$hear_loop_mid"
            pactl unload-module $desktop_loop_mid 2>/dev/null
            pactl unload-module $sink_mid 2>/dev/null
            notify-send -i dialog-error "Virtual Mic" \
                "Failed to loop desktop audio back to your speakers"
            return 1
        end
        set state_lines $state_lines "MODULE $hear_loop_mid"

        # Virtual source so it appears as a mic input device
        set -l vsrc_mid (pactl load-module module-virtual-source \
            source_name=VirtualMicInput \
            'source_properties=device.description=Virtual Microphone Input' \
            master=VirtualMic.monitor 2>/dev/null)
        if test -z "$vsrc_mid"
            pactl unload-module $hear_loop_mid 2>/dev/null
            pactl unload-module $desktop_loop_mid 2>/dev/null
            pactl unload-module $sink_mid 2>/dev/null
            notify-send -i dialog-error "Virtual Mic" \
                "Failed to create virtual source."
            return 1
        end
        set state_lines $state_lines "MODULE $vsrc_mid"

        # Optional: real mic mixed in
        set -l mic_piped 0
        if test "$with_mic" -eq 1
            set -l default_source (pactl info | string match -rg '^Default Source: (.+)$')
            if test -z "$default_source"
                notify-send -i dialog-warning "Virtual Mic" \
                    "Could not detect your microphone.\nPiping only desktop audio."
            else
                set -l mic_mid (pactl load-module module-loopback \
                    source=$default_source \
                    sink=VirtualMic \
                    latency_msec=20 2>/dev/null)
                if test -z "$mic_mid"
                    notify-send -i dialog-warning "Virtual Mic" \
                        "Could not pipe mic into virtual input.\nDesktop audio is still routed."
                else
                    set state_lines $state_lines "MODULE $mic_mid"
                    set mic_piped 1
                end
            end
        end

        printf '%s\n' $state_lines > $STATE

        if test "$mic_piped" -eq 1
            notify-send -i audio-input-microphone "Virtual Mic — Desktop + Mic" \
                "Capturing: all desktop audio + your microphone\n\nSelect 'VirtualMicInput' as your microphone in recording apps"
        else
            notify-send -i audio-input-microphone "Virtual Mic — Desktop Audio" \
                "Capturing: all desktop audio\n\nSelect 'VirtualMicInput' as your microphone in recording apps"
        end
        return 0
    end

    # ─── APPLICATION MODE ─────────────────────────────────────────
    # Collect running sink-inputs (playing apps)
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

    # ─── BUILD DISPLAY LABELS ────────────────────────────────────
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

    # ─── PICKER (multi-select where supported) ────────────────────
    # chosen_indices: list of sink-input IDs selected by the user
    set -l chosen_indices

    if command -q kdialog
        # kdialog --checklist supports multi-select; returns space-separated tags
        set -l kargs
        for i in (seq (count $si_index))
            set kargs $kargs $si_index[$i] $display_entries[$i] off
        end
        set -l raw (kdialog \
            --title "Stream Apps to Virtual Mic" \
            --checklist "Select applications to route as microphone input:" \
            $kargs 2>/dev/null)
        # kdialog wraps each selection in quotes; strip them
        set chosen_indices (string replace -a '"' '' -- $raw)
    else
        # Text-based pickers: prompt to pick one entry at a time, loop until done
        set -l picker ""
        if command -q wofi
            set picker wofi
        else if command -q rofi
            set picker rofi
        else if command -q fuzzel
            set picker fuzzel
        else if command -q fzf
            set picker fzf
        else
            echo "audiotomic: no picker found — install kdialog, wofi, rofi, fuzzel, or fzf"
            return 1
        end

        # Build a mutable list of remaining entries (we remove picked ones)
        set -l remaining_indices $si_index
        set -l remaining_entries $display_entries
        set -l done_picking 0

        while test "$done_picking" -eq 0; and test (count $remaining_entries) -gt 0
            # Prepend a "Done" sentinel so the user can finish multi-select
            set -l menu_entries "✅  Done (route selected)" $remaining_entries

            set -l chosen_display ""
            switch $picker
                case wofi
                    set chosen_display (printf '%s\n' $menu_entries | \
                        wofi --dmenu --prompt "Add app to mic (pick Done when finished):" --insensitive)
                case rofi
                    set chosen_display (printf '%s\n' $menu_entries | \
                        rofi -dmenu -p "Add app to mic (pick Done when finished):")
                case fuzzel
                    set chosen_display (printf '%s\n' $menu_entries | \
                        fuzzel --dmenu --prompt "Add app to mic (Done when finished): ")
                case fzf
                    set chosen_display (printf '%s\n' $menu_entries | \
                        fzf --prompt "Add app to mic (Done when finished): " --reverse --height 40%)
            end

            # Cancelled / closed picker without choosing
            if test -z "$chosen_display"
                set done_picking 1
                break
            end

            # User chose "Done"
            if string match -q "✅  Done*" -- "$chosen_display"
                set done_picking 1
                break
            end

            # Match back to a remaining entry
            for i in (seq (count $remaining_entries))
                if test "$remaining_entries[$i]" = "$chosen_display"
                    set chosen_indices $chosen_indices $remaining_indices[$i]
                    # Remove from remaining so it can't be picked twice
                    set -e remaining_entries[$i]
                    set -e remaining_indices[$i]
                    break
                end
            end
        end
    end

    # Nothing selected (cancelled)
    if test (count $chosen_indices) -eq 0
        return 0
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

    # ─── ROUTE EACH CHOSEN APP ───────────────────────────────────
    set -l routed_labels
    set -l failed_labels

    for chosen_index in $chosen_indices
        # Find original sink and label for this stream
        set -l orig_sink_idx ""
        set -l chosen_label ""
        for i in (seq (count $si_index))
            if test "$si_index[$i]" = "$chosen_index"
                set orig_sink_idx $si_sink[$i]
                set chosen_label $display_entries[$i]
                break
            end
        end

        # Resolve numeric sink index → name
        set -l orig_sink_name ""
        for line in (pactl list short sinks)
            set -l fields (string split \t -- $line)
            if test "$fields[1]" = "$orig_sink_idx"
                set orig_sink_name $fields[2]
                break
            end
        end

        if test -z "$orig_sink_name"
            set failed_labels $failed_labels $chosen_label
            continue
        end

        # Move stream to virtual sink
        if not pactl move-sink-input $chosen_index VirtualMic 2>/dev/null
            set failed_labels $failed_labels $chosen_label
            continue
        end
        set state_lines $state_lines "MOVE $chosen_index $orig_sink_name"

        # Loopback: virtual sink → original output (so you still hear the app)
        set -l loop_mid (pactl load-module module-loopback \
            source=VirtualMic.monitor \
            sink=$orig_sink_name \
            latency_msec=20 2>/dev/null)
        if test -n "$loop_mid"
            set state_lines $state_lines "MODULE $loop_mid"
        end

        set routed_labels $routed_labels $chosen_label
    end

    # Nothing routed successfully — clean up and abort
    if test (count $routed_labels) -eq 0
        for line in (tac $state_lines)
            set -l parts (string split ' ' -- $line)
            if test "$parts[1]" = MOVE
                pactl move-sink-input $parts[2] $parts[3] 2>/dev/null
            else if test "$parts[1]" = MODULE
                pactl unload-module $parts[2] 2>/dev/null
            end
        end
        notify-send -i dialog-error "Virtual Mic" \
            "Failed to reroute audio for any selected application"
        return 1
    end

    # ─── VIRTUAL SOURCE (appears as a mic input device) ──────────
    set -l vsrc_mid (pactl load-module module-virtual-source \
        source_name=VirtualMicInput \
        'source_properties=device.description=Virtual Microphone Input' \
        master=VirtualMic.monitor 2>/dev/null)

    if test -z "$vsrc_mid"
        # Non-fatal: audio still routes, just won't appear as a nice source name
        notify-send -i dialog-warning "Virtual Mic" \
            "Virtual source creation failed.\nUse 'VirtualMic.monitor' as microphone instead."
    else
        set state_lines $state_lines "MODULE $vsrc_mid"
    end

    # ─── OPTIONAL: MIX IN REAL MICROPHONE ────────────────────────
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
    set -l routed_list (string join "\n  • " $routed_labels)
    set -l notice "Routing:\n  • $routed_list"

    if test (count $failed_labels) -gt 0
        set -l failed_list (string join ", " $failed_labels)
        set notice "$notice\n\n⚠ Failed to route: $failed_list"
    end

    if test "$mic_piped" -eq 1
        set notice "$notice\n  • Your microphone"
    end

    set notice "$notice\n\nSelect 'VirtualMicInput' as your microphone in recording apps"

    notify-send -i audio-input-microphone "Virtual Mic — Application Audio" $notice
end
