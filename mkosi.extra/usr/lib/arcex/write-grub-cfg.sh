#!/bin/bash
# Regenerate /grub/grub.cfg on an arceX ESP.
#
# Emits the full arceX GRUB menu (Boot/Update/Boot Windows with per-entry
# not-found error handling and the staged-update marker logic) as a static
# template. The output is byte-identical to the seed that ships in the image
# (mkosi.extra/efi/grub/grub.cfg) so regenerating here never drifts from a
# freshly built image. The "Boot arcex" entry finds the newest UKI via a glob,
# so the config does not depend on a specific image version.
#
# Used by the recovery updater after a UKI change and by the image finalize
# step (which discards the per-version entry mkosi appends to the seed).
#
# Usage: write-grub-cfg.sh <esp-mount-point>

set -euo pipefail

ESP="${1:?usage: write-grub-cfg.sh <esp-mount-point>}"

cat > "$ESP/grub/grub.cfg.new" <<'GRUB_EOF'
# arceX GRUB menu.
#
# mkosi keeps this file as the /grub/grub.cfg seed on the ESP and appends its
# own per-version chainload entry after a kernel install; the image finalize
# step then regenerates the config from this same template so the shipped
# firmware only ever sees the menu below. /usr/lib/arcex/write-grub-cfg.sh
# emits byte-identical output whenever an update touches the ESP, so the
# config can never drift.
#
# Menu:
#   Boot arcex   -> newest arcex_*_x86-64.efi UKI on the ESP (default)
#   Update arcex -> recovery UKI: applies any staged update, then reboots
#   Boot Windows -> chainloads the Windows Boot Manager (Windows 8/10/11;
#                   Windows 7 only if it was installed in UEFI mode)
#
# Staged updates: when the marker /EFI/updates/arcex.update exists on the ESP,
# boot the recovery UKI immediately (default index 1, timeout 0) so the staged
# update runs before the installed system boots.
#
# Error handling: every entry checks for its target first; if the file is
# missing it prints an error and drops back to this menu so you can select
# again (or press Ctrl-Alt-Del to reboot).

set timeout=3
set default=0

menuentry "Boot arcex" {
    set uki=""
    for f in /EFI/Linux/arcex_*_x86-64.efi; do
        [ -n "$f" ] && set uki="$f"
    done

    if [ -n "$uki" ]; then
        chainloader "$uki"
        boot
    fi

    echo "error: no arceX UKI found on the ESP (/EFI/Linux/arcex_*_x86-64.efi)."
    echo "Re-flash the disk or restore a UKI, then select a menu item again."
    sleep --interruptible 5
}

menuentry "Update arcex" {
    if [ -e /EFI/Linux/arcex-recovery.efi ]; then
        chainloader /EFI/Linux/arcex-recovery.efi
        boot
    fi

    echo "error: recovery UKI not found (/EFI/Linux/arcex-recovery.efi)."
    echo "The staged updater is missing - select another menu item."
    sleep --interruptible 5
}

menuentry "Boot Windows" {
    if [ -e /EFI/Microsoft/Boot/bootmgfw.efi ]; then
        chainloader /EFI/Microsoft/Boot/bootmgfw.efi
        boot
    fi

    echo "error: Windows Boot Manager not found (/EFI/Microsoft/Boot/bootmgfw.efi)."
    echo "Boot Windows from the firmware's own boot menu instead."
    sleep --interruptible 5
}

if [ -e /EFI/updates/arcex.update ]; then
    set default=1
    set timeout=0
fi
GRUB_EOF

mv -f "$ESP/grub/grub.cfg.new" "$ESP/grub/grub.cfg"