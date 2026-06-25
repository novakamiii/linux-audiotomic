function phonetoggle
    set -l MAC "3C:AF:B7:5F:02:DB"
    set -l NAME "Paulo 13c"

    set -l connected (bluetoothctl info $MAC | grep "Connected:" | string match -r "yes")

    if test -n "$connected"
        fish -c "
            bluetoothctl -- disconnect $MAC >/dev/null 2>&1
            notify-send -i bluetooth 'Bluetooth Audio' 'Disconnected $NAME'
        " &
        disown
    else
        fish -c "
            bluetoothctl -- connect $MAC >/dev/null 2>&1
            and notify-send -i bluetooth 'Bluetooth Audio' 'Connected $NAME (AAC)'
            or notify-send -i dialog-error 'Bluetooth Audio' 'Failed to connect $NAME'
        " &
        disown
    end
end
