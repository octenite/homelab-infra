#!/bin/sh
# Prints the block device that holds, or shall hold, the datastore. Disk
# names on this VM swap between boots, so the disk is found by what is on
# it, in this order: the label of its filesystem; the name of its GPT
# partition (a first run that was interrupted between partitioning and
# formatting leaves exactly that); and, before either exists, the one disk
# with nothing on it. The role's guard then decides whether the disk found
# may be used.
# Usage: pbs-datastore-disk.sh <label>
set -eu
label=$1

dev=$(lsblk -rno PKNAME,LABEL | awk -v l="$label" '$2 == l { print $1; exit }')
if [ -z "$dev" ]; then
	dev=$(lsblk -rno PKNAME,PARTLABEL | awk -v l="$label" '$2 == l { print $1; exit }')
fi
if [ -n "$dev" ]; then
	echo "/dev/$dev"
	exit 0
fi

for d in $(lsblk -dnro NAME,TYPE | awk '$2 == "disk" { print $1 }'); do
	children=$(lsblk -nro NAME "/dev/$d" | wc -l)
	fstype=$(lsblk -dnro FSTYPE "/dev/$d")
	if [ "$children" -eq 1 ] && [ -z "$fstype" ]; then
		echo "/dev/$d"
		exit 0
	fi
done
echo "no disk carries the label $label and no empty disk exists" >&2
exit 1
