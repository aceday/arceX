#!/bin/bash

set -e

DISK=/dev/sdb

echo "WARNING: Destroying all data on $DISK"
sleep 3

# Create GPT
sgdisk --zap-all "$DISK"

# Create partitions
sgdisk \
  -n1:1MiB:+512MiB \
  -t1:ef00 \
  -n2:0:+4GiB \
  -n3:0:0 \
  "$DISK"

# Reload partition table
partprobe "$DISK"
sleep 2

# Format EFI
mkfs.fat -F32 "${DISK}1"

# Create BTRFS root
mkfs.btrfs -f "${DISK}3"


# Write EROFS /usr image
dd if=/root/usr.erofs \
   of="${DISK}2" \
   bs=4M \
   status=progress

sync