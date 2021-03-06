#!/bin/bash

set -e
set -v

# this script creates a new RAID device from scratch, given the drive letters 
# of the HDDs you want to use and the raid level. 

# it only works on centos, since it was written for use with xen server.

# raid level options: 0, 1, 5, 6 
# multidevice: the /dev/[xxx] name of the raid device comprising all the drives
# filesystem type: choose from ext2, ext3, or ext4
# drive list: JUST THE LETTERS of each /dev/sd[X] drive
# bash raid-autoconf.sh -r 5 -m md1 -e ext4 -d "a b d g"

# there is a confirmation sequence before anything is written.

# LIMITATION: this does not account for hot spares. NOTE that the 
# autoconf script will not account for leaving a drive unused as a hot swap. If 
# you want to do that, then you'll have to modify the script or just run the 
# commands manually. I'd have to rewrite the script with a ton more complexity to 
# account for that, and I'd rather just make a second, simpler script for that
# specific scenario.

while getopts ":r:d:m:e:c:" opt; do
  case $opt in
    r) raid_level="$OPTARG" ;;
    m) raid_multi_device="$OPTARG" ;;
    e) filesystemtype="$OPTARG" ;;
    d) drive_list="$OPTARG" ;;
    c) drive_count="$OPTARG" ;;
    \?) echo "Invalid option -$OPTARG. " >&2 ;;
  esac
done

[ -z "$raid_level" ]        && echo "raid level not specified."       && exit
[ -z "$raid_multi_device" ] && echo "multidevice not specified."      && exit
[ -z "$filesystemtype" ]    && echo "filesystem type not specified."  && exit
[ -z "$drive_list" ]        && echo "drive list not specified."       && exit
[ -z "$drive_count" ]       && echo "number of drives not specified." && exit

printf "Using RAID %s\n" "$raid_level"
printf "Using /dev/sd[X] drive letters: %s\n" "$drive_list"
printf "Multidevice specified:  /dev/%s\n" "$raid_multi_device"
printf "Filesystem chosen: %s\n" "$filesystemtype"
printf "Number of drives to be formatted: %s\n" "$drive_count"

for drive in ${drive_list[@]}                       # mount-related error checks
do
    if mount | grep /dev/sd$drive > /dev/null
    then 
      echo "ERROR: /dev/sd$drive is mounted."
      exit
    elif cat /proc/mdstat | grep sd$drive > /dev/null
    then
      echo "ERROR: /dev/sd$drive is part of a preexisting RAID device. Remove"
      echo "that device before proceeding."
      echo "https://www.looklinux.com/how-to-remove-raid-in-linux/"
      exit
    fi
done


echo "confirm: using drives ${drive_list[@]} for new RAID $raid_level array."
echo -n "ALL DATA ON ALL LISTED DRIVES WILL BE LOST! > "; read

[ `which parted   2>/dev/null` ] || yum install parted
[ `which mdadm    2>/dev/null` ] || yum install mdadm
[ `which xfsprogs 2>/dev/null` ] || yum install xfsprogs

sync && sync && sync                                # folklore, but doesn't hurt

for drive in ${drive_list[@]}; do                   # create new partition label
    echo -e "\tCreating partition label on /dev/sd$drive"
    sudo parted /dev/sd$drive mklabel gpt                                && sync
done

echo -n "press enter to continue > "; read

for drive in ${drive_list[@]}; do                 # create new primary partition
    echo -e "\tCreating new primary partition on /dev/sd$drive"
    sudo parted -a optimal /dev/sd$drive mkpart primary 0% 100%          && sync
done

for drive in ${drive_list[@]}; do                                 # turn on raid
    echo -e "\tactivating RAID on /dev/sd$drive"
    sudo parted /dev/sd$drive set 1 raid on                              && sync
done

for d in ${drive_list[@]}; do parted /dev/sd$d print; done   # verify formatting

echo -ne "Drive count: $drive_count\nMulti device name: $raid_multi_device\n"

devicelist=$(eval echo  /dev/sd{`echo "$drive_list" | tr ' ' ,`}1)
echo "Drives: $devicelist"

sudo mdadm  --create \
            --verbose /dev/$raid_multi_device \
            --level=$raid_level \
            --raid-devices=$drive_count $devicelist

# backup the raid multi device so it's persistent on reboot
mkdir -pv /etc/mdadm
sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf

# ensure the device is assembled on boot
# sudo update-initramfs -u                         # not available on the system
# sudo update-grub              # WATCH OUT! could mess up a separate boot drive
mdadm --verbose --detail -scan > /etc/mdadm.conf       # used to id RAID devices 

sudo mkfs.ext4 -F /dev/$raid_multi_device                # Create the filesystem

sudo mkdir -p /mnt/$raid_multi_device
sudo mount /dev/$raid_multi_device /mnt/$raid_multi_device

# add new mount to fstab
echo "/dev/$raid_multi_device /mnt/$raid_multi_device ext4 defaults,nofail,discard 0 0" | sudo tee -a /etc/fstab

# verify
df -h -t ext4
lsblk
cat /proc/mdstat
sudo mdadm --detail /dev/$raid_multi_device

echo "check the progress of the drive mirroring process with the command: \"cat"
echo " /proc/mdstat\""
