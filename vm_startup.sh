#!/bin/bash

progress_update_interval=1
looking_glass_flags=""
vm_name="Windoze"
backup_script="vm_backup.sh"

trap 'exit_me' EXIT # delete the tmpfile and kill the background process when we exit

exit_me () {
    if [ -e "$tmp_file" ]
    then
        rm "$tmp_file"
    fi
}

user=$(who | grep '('$DISPLAY')' | awk '{print $1}' | head -n 1)
uid=$(id -u $user)

if ! [ "$uid" = "$EUID" ]
then
    zenity --error --text "This script must be run by a user with an active graphical session."
    exit 1
fi


vm_exist=$(virsh --connect qemu:///system list --all | grep $vm_name)
if ([ -z "$vm_exist" ])
then
    zenity --error --text "Error: VM '$vm_name' doesn't exist. Please make sure that the variable 'vm_name' is set correctly."
    exit 1
fi

vmrunning=$(echo "$vm_exist" | awk '{ print $3}')
if ([ "$vmrunning" == "paused" ] || [ "$vmrunning" == "running" ])
then
    zenity --error --text "Error: VM '$vm_name' is already running."
    exit 1
fi

back_me_up () {
    bytes_done=0
    percent=0
    average_rate=0
    rate=0
    calculating="Calculating..."
    tmp_file=$(mktemp /tmp/windoze_backup_script.XXXXXX)
    pkexec bash -c "/home/$user/Scripts/$backup_script -n >> $tmp_file 2>&1" &
    Background_PID=$!
    block_dev_size=""
    while [ -e /proc/$Background_PID ] && [ -z "$block_dev_size" ] 
    do block_dev_size=$(grep -m 1 "bytes" $tmp_file | cut -d "=" -f 2-); done
    while [ -e /proc/$Background_PID ] && [ -e $tmp_file ] #while the background process is running
    do
        percent=$(echo "100 * $bytes_done / $block_dev_size" | bc)
        old_bytes_done=$bytes_done
        tmp_file_val=$(tail -1 $tmp_file | tr -d '\0')
        if [ -z "$(echo "$tmp_file_val" | grep -vx -E '[0-9]+')" ]; then bytes_done=$tmp_file_val; fi;
        old_rate=$rate
        new_rate=$(echo "scale=2; ($bytes_done - $old_bytes_done) / (1000000 * $progress_update_interval)" | bc)
        rate=$(echo "scale=2; ($old_rate + $new_rate) / 2" | bc)
        elapsed_time=$(ps -o etimes= -p "$Background_PID")
        if [ "$elapsed_time" -ne 0 ] && [ "$bytes_done" -ne 0 ]
        then
            average_rate=$(echo "scale=2; $bytes_done / $elapsed_time / 1000000" | bc)
            calculating=""
            time_remaining=$(echo "($block_dev_size - $bytes_done) / $average_rate / 1000000" | bc)
            remaining_hours=$(echo "$time_remaining" / 3600 | bc)
            remaining_minutes=$(echo "($time_remaining - (3600 * $remaining_hours)) / 60" | bc)
            remaining_seconds=$(echo "$time_remaining - (3600 * $remaining_hours) - (60 * $remaining_minutes)" | bc)
            if [ ! $remaining_hours -eq 0 ]
            then
                remaining_hours+=" Hours "
            else
                remaining_hours=""
            fi
            if [ ! $remaining_minutes -eq 0 ]
            then
                remaining_minutes+=" Minutes "
            else
                remaining_minutes=""
            fi
            if [ ! $remaining_seconds -eq 0 ]
            then
                remaining_seconds+=" Seconds "
            else
                remaining_seconds=""
            fi
        fi
        total_GB=$(echo "scale=2; $block_dev_size / 1000000000" | bc)
        done_GB=$(echo "scale=2; $bytes_done / 1000000000" | bc)
        if [ ${done_GB::1} == "." ]
        then
            done_GB=0$done_GB #if it starts with '.' we need to add a zero in front
        fi
        echo "$percent"
        echo "# $percent% complete ($done_GB / $total_GB GB)"\
        "\nTransfer Rate: $rate MB/s\nTime Remaining: $calculating$remaining_hours$remaining_minutes$remaining_seconds"
        sleep $progress_update_interval
    done | zenity --no-cancel --progress --percentage=0 --width=400 --title="Creating disk image..." --auto-close --auto-kill
    Error=$(grep -m 1 "Error" $tmp_file)
    if [ -n "$Error" ] || [ ! -s $tmp_file ]
    then
        zenity --error --text="Backup Failed. $Error"
        exit 1
    else
        zenity --info --width=600 --title="Backup complete"\
        --text "Backup of '$vm_name' completed sucessfully on $(date +"%B %-d, %Y") at $(date +"%-H:%M %p")."
    fi
}

if zenity --question --title="Backup?" --text="Do you want to backup the VM '$vm_name' now?"
then
    back_me_up
fi

virsh --connect qemu:///system start $vm_name # start the VM
sleep 5 | zenity --no-cancel --progress --pulsate --text="Waiting for VM '$vm_name' to start up" --title="VM starting" --auto-close --width=400
looking-glass-client $looking_glass_flags # open looking glass.

while [ $(virsh --connect qemu:///system list --all | grep $vm_name | awk '{ print $3}') != "shut" ]
do
    if zenity --question --text="Looking Glass Client has closed, but the VM '$vm_name' is still running. Do you want to relaunch Looking Glass Client?"
    then 
        looking-glass-client $looking_glass_flags
    else
        break
    fi
done

until [ $(virsh --connect qemu:///system list --all | grep $vm_name | awk '{ print $3}') == "shut" ]
do 
    echo "waiting..."
    zenity --no-cancel --progress --pulsate --text="Waiting for VM '$vm_name' to shut down" --title="VM shutting down" --auto-close --width=400
done


if zenity --question --title="Backup?" --text="Do you want to backup the VM '$vm_name' now?"
then
    back_me_up
fi


exit 0




