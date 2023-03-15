#!/bin/bash

num_threads=10 # sets the number of threads to be used by pigz
update_interval=0.5 # update frequency for progress bar

vm_name=Windoze
backup_image_location=/mnt/zen_back_base/Windoze_Disk_Image/Backup.img.gz # where to store (compressed) disk image
backup_xml_location=/mnt/zen_back_base/Windoze_Disk_Image/XML_Backup.xml
pci_addr=0000:04:00.0
btrbk_config_path=/etc/btrbk/windoze.conf

numeric_flag=""
verbose=0

usage() { echo "Usage: $0 [-n] [-v] " 1>&2; exit 1; }

while getopts "nv" opts;
do
    case "${opts}" in
        n) numeric_flag="-n -b";;
        v) verbose=1;;
        \?) usage;;
    esac
done

if [ "$EUID" -ne 0 ]
then
    echo "Error: This script requires root privilges. Please run as root."
    exit 1
fi

vm_exist=$(virsh --connect qemu:///system list --all | grep $vm_name)
if ([ -z "$vm_exist" ])
then
    echo "Error: VM '$vm_name' doesnt exist. Please make sure that the variable 'vm_name' is set correctly."
    exit 1
fi

vmrunning=$(echo "$vm_exist" | awk '{ print $3}')
if ([ "$vmrunning" == "paused" ] || [ "$vmrunning" == "running" ])
then
    echo "Error: VM '$vm_name' is running. Please shutdown before running this script."
    exit 1
fi

virsh --connect qemu:///system dumpxml $vm_name > $backup_xml_location
if [ $? -ne 0 ]
then
    echo "Error: Failed to backup XML file for VM '$vmname'."
    exit 1
elif [ $verbose -eq 1 ]
then
    echo "XML file for VM '$vm_name' has been backed up"
fi

find_block_dev () { for i in $(ls /sys/block | grep nvme); do 
    echo "$(cat /sys/block/$i/device/address) is $i" | grep $pci_addr | grep -o $i; done }
block_dev=$(find_block_dev)
counter=1
while  [ -z "$block_dev" ] && [ $counter -le 5 ]
do
    if [ $verbose -eq 1 ]
    then
        echo "Unable to find a block device with PCI address '$pci_addr' on attempt #$count. Attempting to reattach..."
    fi
    virsh nodedev-reattach $(echo "pci_$pci_addr" | tr ":." "_")
    sleep 0.5
    block_dev=$(find_block_dev)
    ((counter+=1))
done
if [ -z "$block_dev" ]
then
    echo "Error: Unable to find a block device with PCI address '$pci_addr'."
    exit 1
elif [ $verbose -eq 1 ]
then
    echo "Succesfully located block device '$block_dev' with PCI address '$pci_addr'."
fi

block_dev_path=/dev/$block_dev

if [ -n "$(lsblk -o MOUNTPOINTS -n $block_dev_path | grep /)" ]
then
    echo "Error: Device '$block_dev' at PCI address '$pci_addr' has partition(s) that are currently mounted. Please unmount them and re-run this script."
    exit 1
fi

block_dev_size=$(blockdev --getsize64 $block_dev_path) #size (in bytes) of the block device

if [ $? -ne 0 ]
then
    echo "Error: Cannot determine size of block device."
    exit 1
fi

if [ -n "$numeric_flag" ]
then
    echo "bytes=$block_dev_size"
fi

if [ $verbose -eq 1 ]
then
    echo "Block device is $block_dev_size bytes. Creating disk image now..."
fi

dd if=$block_dev_path bs=4096 status=none | pv $numeric_flag -s $block_dev_size -i $update_interval -f | pigz -1 -p $num_threads > $backup_image_location

if [ $? -ne 0 ]
then
    echo "Error: Failed to create disk image."
    exit 1
fi

btrbk -q -c $btrbk_config_path run #Run btrbk on the disk image location
if [ $? -ne 0 ]
then
    echo "Error: btrbk failed to create backup."
    exit 1
fi



