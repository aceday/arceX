#!/bin/bash
# arceX pre-boot update recovery.
#
# Runs from the arceX-recovery UKI (a minimal initramfs, kernel cmdline
# contains "arcex.update"). Applies a staged update before the running system
# is booted:
#   1. mounts the ESP and the root partition by GPT label,
#      (layout: p1 ESP / p2 usr erofs / p3 root btrfs)
#   2. picks the newest staged /usr image under <root>/var/lib/arcex/updates,
#   3. writes it onto the arcex-usr partition (when it differs),
#   4. syncs the staged UKI onto the ESP and regenerates grub.cfg,
#   5. clears the update marker and reboots.
#
# On failure the marker is kept so the next boot retries.

set -euo pipefail

log() { echo "[arcex-update] $*"; }

fail() { echo "[arcex-update] error: $*" >&2; exit 1; }

MARKER="/EFI/updates/arcex.update"
UPDATES_DIR="var/lib/arcex/updates"
RECOVERY_UKI="arcex-recovery.efi"

SECTOR=512
MIB_BYTES=$(( 1024 * 1024 ))
MIB_SECTORS=$(( MIB_BYTES / SECTOR ))
GPT_RESERVE_SECTORS=$(( MIB_SECTORS ))

# Read a partition's geometry (start, end, GUID) from sgdisk in one shot.
part_geom() { # disk partnum -> "start end guid" or non-zero if unreadable
    local disk="$1" n="$2" info
    info="$(sgdisk -i "$n" "$disk" 2>/dev/null)" || return 1
    awk -F': ' -v OFS=' ' \
        '/First sector/{s=$2} /Last sector/{e=$2} /Partition GUID code/{g=$2}
         END{if (s!="" && e!="" && g!="") print s,e,g; else exit 1}' <<<"$info"
}

# Grow the /usr partition (p2, the partition immediately before root) to make
# room for a payload larger than the installed partition.
#
# Layout is p1 ESP / p2 usr (erofs) / p3 root (btrfs, LAST). With /usr no
# longer at the disk end, the only in-place room it can consume is the free
# gap that sits between its END and the root START. btrfs can only shrink
# from its END (the disk tail, on the far side of root), so root never yields
# that gap: the moment root is placed flush against /usr there is no free
# space for /usr to grow into without relocating the btrfs root (which is not
# safe to do pre-boot). Therefore this function grows /usr ONLY into any free
# space currently between it and root, and bails with a clear re-flash message
# when there is none.
grow_usr() {
    local need_bytes="$1" need_sectors
    local disk u_num r_num u_start u_end r_start usr_guid
    local gap_sectors new_u_end new_size

    disk="$(lsblk -no PKNAME "$USR_DEV" | head -n 1)"
    [[ -n "$disk" ]] || fail "cannot resolve the parent disk of $USR_DEV"
    u_num="$(lsblk -no PARTN "$USR_DEV" | head -n 1)"
    r_num="$(lsblk -no PARTN "$ROOT_DEV" | head -n 1)"
    [[ -n "$u_num" && -n "$r_num" ]] || fail "cannot resolve partition numbers"

    read -r u_start u_end usr_guid <<<"$(part_geom "$disk" "$u_num")" ||
        fail "cannot read $disk partition $u_num geometry"
    read -r r_start _ _ <<<"$(part_geom "$disk" "$r_num")" ||
        fail "cannot read $disk partition $r_num geometry"

    need_sectors=$(( (need_bytes + MIB_BYTES - 1) / MIB_BYTES * MIB_SECTORS ))

    # Room /usr can consume = free sectors between its END and root's START.
    gap_sectors=$(( r_start - u_end - 1 ))
    (( gap_sectors > 0 )) || gap_sectors=0
    gap_sectors=$(( gap_sectors / MIB_SECTORS * MIB_SECTORS ))

    if (( gap_sectors < need_sectors )); then
        fail "not enough free space after /usr to grow it ($((gap_sectors*SECTOR)) avail, need $((need_sectors*SECTOR))); /usr sits before the btrfs root which can only shrink from the disk end - re-flash a larger /usr instead"
    fi

    # /usr stays put; only its END extends right into the gap. Root is
    # untouched (no data move).
    new_u_end=$(( u_end + gap_sectors ))

    log "rewriting GPT: usr=$u_start-$new_u_end (root start unchanged at $r_start)"
    sgdisk --delete="$u_num" \
        --new="$u_num:$u_start:$new_u_end" \
        --typecode="$u_num:$usr_guid" --change-name="$u_num:arcex-usr" \
        "$disk" ||
        fail "sgdisk failed to resize /usr"

    sgdisk -v "$disk" >/dev/null || fail "GPT verification failed after /usr resize"

    partx -u "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
    udevadm settle || true
    sleep 0.5

    USR_DEV="$(readlink -f /dev/disk/by-partlabel/arcex-usr)"
    new_size="$(blockdev --getsize64 "$USR_DEV")"
    [[ "$new_size" -ge "$PAYLOAD_SIZE" ]] ||
        fail "/usr resize did not take effect ($new_size < $PAYLOAD_SIZE)"
    log "/usr partition grown to $new_size bytes"
    PART_SIZE="$new_size"
}

# Wait for udev to create the by-partlabel symlinks we rely on.
for _ in $(seq 1 100); do
    [[ -e /dev/disk/by-partlabel/arcex-esp ]] && break
    sleep 0.1
done
udevadm settle || true

[[ -e /dev/disk/by-partlabel/arcex-esp ]] || fail "ESP (partlabel arcex-esp) not found"
[[ -e /dev/disk/by-partlabel/arcex-root ]] || fail "root partition (partlabel arcex-root) not found"
[[ -e /dev/disk/by-partlabel/arcex-usr ]] || fail "/usr partition (partlabel arcex-usr) not found"

ESP_DEV="$(readlink -f /dev/disk/by-partlabel/arcex-esp)"
ROOT_DEV="$(readlink -f /dev/disk/by-partlabel/arcex-root)"
USR_DEV="$(readlink -f /dev/disk/by-partlabel/arcex-usr)"

mkdir -p /esp /root
mount -t vfat "$ESP_DEV" /esp || fail "failed to mount ESP"
mount -t btrfs "$ROOT_DEV" /root || fail "failed to mount root partition"
trap 'umount /esp /root 2>/dev/null || true' EXIT

if [[ ! -f "/esp/$MARKER" ]]; then
    log "no staged update (no marker) - leaving system untouched"
    exit 1
fi

[[ -d "/root/$UPDATES_DIR" ]] || fail "no $UPDATES_DIR on root partition"
SRC_DIR="/root/$UPDATES_DIR"

# Newest staged /usr image (raw or zstd), e.g. arcex_1.0_x86-64_arcex_usr.raw[.zst]
USR="$(ls -1 "$SRC_DIR"/arcex_*_arcex_usr.raw* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "$USR" ]] || fail "no staged /usr image (arcex_*_arcex_usr.raw*) in $SRC_DIR"
log "staged /usr image :: $(basename "$USR")"

case "$USR" in
    *.zst) PAYLOAD_NAME="$(basename "$USR" .zst)"; PAYLOAD_EXTRACT="zstd -qdc --no-progress" ;;
    *)     PAYLOAD_NAME="$(basename "$USR")"; PAYLOAD_EXTRACT="cat" ;;
esac
PREFIX="${PAYLOAD_NAME%_arcex_usr.raw}"            # -> arcex_<version>_<arch>
PAYLOAD_SIZE="$($PAYLOAD_EXTRACT "$USR" | wc -c)"

# A staged UKI for the same version/arch is optional; if present it replaces
# the kernel on the ESP.
STAGED_UKI=""
for cand in "$SRC_DIR/$PREFIX.efi" "$SRC_DIR/$PREFIX.efi.zst"; do
    if [[ -e "$cand" ]]; then STAGED_UKI="$cand"; break; fi
done

PART_SIZE="$(blockdev --getsize64 "$USR_DEV")"

if (( PAYLOAD_SIZE > PART_SIZE )); then
    log "new /usr ($PAYLOAD_SIZE bytes) is larger than the installed /usr ($PART_SIZE bytes); growing it"
    grow_usr "$(( PAYLOAD_SIZE - PART_SIZE ))"
fi

log "target /usr :: $USR_DEV ($PAYLOAD_SIZE / $PART_SIZE bytes)"

SRC_HASH="$($PAYLOAD_EXTRACT "$USR" | sha256sum | cut -d' ' -f1)"
CUR_HASH="$(head -c "$PAYLOAD_SIZE" "$USR_DEV" | sha256sum | cut -d' ' -f1)"

if [[ "$CUR_HASH" == "$SRC_HASH" ]]; then
    log "/usr already up to date (no write needed)"
else
    log "writing /usr partition…"
    $PAYLOAD_EXTRACT "$USR" | dd of="$USR_DEV" bs=4M conv=fsync status=progress
    AFTER_HASH="$(head -c "$PAYLOAD_SIZE" "$USR_DEV" | sha256sum | cut -d' ' -f1)"
    [[ "$AFTER_HASH" == "$SRC_HASH" ]] || fail "verify failed after write"
    log "/usr updated and verified"
fi

if [[ -n "$STAGED_UKI" ]]; then
    case "$STAGED_UKI" in
        *.zst) zstd -qdc --no-progress "$STAGED_UKI" > "/esp/EFI/Linux/$PREFIX.efi" ;;
        *)     cp -f "$STAGED_UKI" "/esp/EFI/Linux/$PREFIX.efi" ;;
    esac
    log "installed UKI /EFI/Linux/$PREFIX.efi"

    # Drop previous versioned UKIs (keep the recovery UKI) so the boot menu
    # only shows the freshly installed kernel.
    for old in /esp/EFI/Linux/*.efi; do
        name="$(basename "$old")"
        [[ "$name" == "$RECOVERY_UKI" || "$name" == "$PREFIX.efi" ]] && continue
        log "removing stale UKI $name"
        rm -f "$old"
    done
fi

/usr/lib/arcex/write-grub-cfg.sh /esp || fail "failed to regenerate grub.cfg"
log "regenerated grub.cfg"

# Apply succeeded: clear the marker, persist, and boot the updated system.
rm -f "/esp/$MARKER"
sync
log "rebooting into updated system…"
systemctl reboot || reboot -f