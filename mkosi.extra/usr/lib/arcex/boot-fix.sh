#!/bin/bash
# arceX UEFI NVRAM boot-order fixer.
#
# Windows updates sometimes reorder or hide UEFI boot entries, leaving the
# firmware to boot Windows first (or nothing) instead of GRUB. This script
# finds the boot entry that loads GRUB from the arceX ESP and moves it to the
# front of the boot order.
#
# It matches an entry by GPT partition UUID + loader path rather than by
# label/disk name, so it keeps working across disk renames and firmware
# re-registrations.
#
# Usage: boot-fix [--dry-run] [--add]

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

DRY_RUN=0
ADD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --add) ADD=1; shift ;;
        -h|--help)
            cat <<EOF
arceX UEFI boot-order fixer - restore GRUB as the first boot entry after
Windows Update reorders NVRAM.

Usage: boot-fix [--dry-run] [--add]

Options:
  --dry-run  show what would change without writing NVRAM
  --add      also create the arcex boot entry if none is registered
  -h, --help show this help

Notes:
  - run on the installed arceX system (or from the recovery shell) as root
  - the entry is matched by the arcex-esp partition UUID + loader path
    (\\EFI\\BOOT\\BOOTX64.EFI), not by disk name or label
EOF
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root (sudo boot-fix)"
command -v efibootmgr >/dev/null || die "'efibootmgr' is not installed"
[[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode"
[[ -e /dev/disk/by-partlabel/arcex-esp ]] ||
    die "arceX ESP (partlabel arcex-esp) not found"

ESP_PARTUUID="$(blkid -s PARTUUID -o value /dev/disk/by-partlabel/arcex-esp)"
DISK="$(readlink -f /dev/disk/by-partlabel/arcex-esp)"

arcex_entries() {
    efibootmgr -v | awk -v pu="$ESP_PARTUUID" '
        /^Boot[0-9A-Fa-f]{4}/ {
            line = $0
            file = ""
            if (match($0, /File\([^)]*\)/))
                file = substr($0, RSTART, RLENGTH)
            gsub(/\\/, "/", file)
            if (index(toupper(file), "EFI/BOOT/BOOTX64.EFI") > 0 &&
                index(toupper(line), toupper(pu)) > 0)
                print substr($1, 5, 4)
        }'
}

BOOT_ORDER="$(efibootmgr | awk '/^BootOrder:/ {print $2}')"
[[ -n "$BOOT_ORDER" ]] || die "efibootmgr reports no boot order"

is_first() { [[ "$BOOT_ORDER" == "$1" || "$BOOT_ORDER" == "$1,"* ]]; }

ENTRY="$(arcex_entries | head -n 1 || true)"
if [[ -z "$ENTRY" && $ADD -eq 1 ]]; then
    echo "no registered boot entry for arceX - creating one…"
    PART="$(lsblk -no PARTNUM "$DISK")"
    DEVDISK="$(lsblk -no PKNAME "$DISK")"
    [[ -n "$PART" && -n "$DEVDISK" ]] || die "cannot determine ESP disk/partition"
    [[ -e "/dev/$DEVDISK" ]] || die "disk /dev/$DEVDISK not found"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] efibootmgr --create --disk /dev/$DEVDISK --part $PART" \
            "--label arcex --loader '\\EFI\\BOOT\\BOOTX64.EFI'"
        exit 0
    fi
    efibootmgr --create --disk "/dev/$DEVDISK" --part "$PART" \
        --label "arcex" --loader '\EFI\BOOT\BOOTX64.EFI'
    ENTRY="$(arcex_entries | head -n 1 || true)"
fi
[[ -n "$ENTRY" ]] || die "no arceX boot entry registered (try boot-fix --add)"

if is_first "$ENTRY"; then
    echo "arceX (Boot${ENTRY}) is already first in boot order."
    exit 0
fi

REST="$(echo "$BOOT_ORDER" | tr ',' '\n' | grep -vx "$ENTRY" | paste -sd, -)"
NEW_ORDER="${ENTRY}"
[[ -n "$REST" ]] && NEW_ORDER="${NEW_ORDER},${REST}"

echo "reordering boot order: $BOOT_ORDER -> $NEW_ORDER"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] no changes written"
    exit 0
fi

efibootmgr -o "$NEW_ORDER"
echo "done - boot order now starts with arceX (Boot${ENTRY})."