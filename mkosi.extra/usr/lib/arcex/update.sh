#!/bin/bash

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

MIB_BYTES=$(( 1024 * 1024 ))
MIB_SECTORS=$(( MIB_BYTES / 512 ))
GPT_RESERVE_SECTORS=$(( MIB_SECTORS ))

# Read a partition's geometry (start, end, GUID) from sgdisk in one shot.
part_geom() { # disk partnum -> "start end guid" or non-zero if unreadable
    local disk="$1" n="$2" info
    info="$(sgdisk -i "$n" "$disk" 2>/dev/null)" || return 1
    awk -F': ' -v OFS=' ' \
        '/First sector/{s=$2} /Last sector/{e=$2} /Partition GUID code/{g=$2}
         END{if (s!="" && e!="" && g!="") print s,e,g; else exit 1}' <<<"$info"
}

# Extend /usr (p2, before the root partition) into any free space between it
# and root. With /usr no longer the last partition there is normally no room
# to gain in place (btrfs root can only shrink from the disk end, on the far
# side of /usr), so this usually returns non-zero and the caller falls back
# to staging, where the pre-boot recovery updater makes the same check.
grow_usr_trailing() {
    local disk="$1" usr="$2" need_bytes="$3"
    local u_num u_start u_end r_start usr_guid avail_sectors need_sectors
    u_num="$(lsblk -no PARTN "$usr")"
    read -r u_start u_end usr_guid <<<"$(part_geom "$disk" "$u_num")" || return 1

    # Free sectors between /usr end and the root START - the only in-place
    # room /usr can take without touching root data.
    read -r r_start _ _ <<<"$(part_geom "$disk" "$(( u_num + 1 ))")" || return 1
    avail_sectors=$(( r_start - u_end - 1 ))
    (( avail_sectors > 0 )) || return 1
    avail_sectors=$(( avail_sectors / MIB_SECTORS * MIB_SECTORS ))
    need_sectors=$(( (need_bytes + MIB_BYTES - 1) / MIB_BYTES * MIB_SECTORS ))
    (( avail_sectors >= need_sectors )) || return 1

    local new_u_end=$(( u_end + avail_sectors ))
    echo "growing /usr partition into free space before root (+$((avail_sectors*512)) bytes)"
    sgdisk --delete="$u_num" \
        --new="$u_num:$u_start:$new_u_end" \
        --typecode="$u_num:$usr_guid" --change-name="$u_num:arcex-usr" \
        "$disk" || return 1
    sgdisk -v "$disk" >/dev/null || return 1
    partx -u "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || true
    udevadm settle || true
    sleep 0.5
    return 0
}

PROG="${0##*/}"

usage() {
    cat <<EOF
arceX in-place /usr updater - update the OS userspace without re-flashing.

Modes:
  1. In-place (default): write a new /usr image onto the target disk.
       $PROG [options] <disk> <usr-image>

  2. Stage (--stage): copy a new /usr image (+ optional UKI) onto the
     installed system's root partition and arm the pre-boot recovery
     updater; the update is applied automatically on the next boot.
       $PROG --stage <usr-image> [--uki FILE]

  <disk>      whole block device holding an installed arceX image (e.g. /dev/sda)
  <usr-image> new /usr partition image from mkosi.output, raw or .zst

Options:
  --stage     stage the update for the next boot instead of writing now
  --uki FILE  also stage/sync a unified kernel image (raw or .zst)
  --dry-run   only report what would be done (in-place mode only)
  -h, --help  show this help

Notes:
  - in-place mode: run from a live/rescue system with no partition of <disk> mounted
  - stage mode: run on the installed arceX system (root partition arcex-root,
    ESP writable) - the update files land on the root partition and the marker
    on the ESP; the recovery UKI applies them before the next boot
  - only the read-only erofs /usr partition is ever written; /etc /var /home
    (btrfs) and the ESP stay as they are, so re-flashing is not needed
EOF
}

STAGE=0
DRY_RUN=0
UKI=
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --uki) [[ -n "${2:-}" ]] || die "--uki needs an argument"; UKI="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *) POS+=("$1"); shift ;;
    esac
done
POS+=("$@")
set -- "${POS[@]}"

[[ $DRY_RUN -eq 1 && $STAGE -eq 1 ]] && die "--dry-run is not supported in --stage mode"

# ---------------------------------------------------------------------------
# --stage mode: stage an update for the pre-boot recovery updater.
# ---------------------------------------------------------------------------
if [[ $STAGE -eq 1 ]]; then
    [[ $# -eq 1 ]] || { usage; exit 1; }
    SRC="$1"
    [[ -e "$SRC" ]] || die "$SRC does not exist"

    name="$(basename "$SRC")"
    case "$name" in
        arcex_*_arcex_usr.raw|arcex_*_arcex_usr.raw.zst) ;;
        *) die "staged /usr image must be named arcex_<version>_<arch>_arcex_usr.raw(.zst), got: $name" ;;
    esac

    # Must run on the installed system (root partition labeled arcex-root).
    var_dev="$(findmnt -n -o SOURCE /var 2>/dev/null || true)"
    [[ -n "$var_dev" ]] || die "cannot resolve the mounted root partition"
    var_part="${var_dev%%\[*}"
    label="$(lsblk -n -o PARTLABEL "$var_part" 2>/dev/null || true)"
    [[ "$label" == "arcex-root" ]] ||
        die "not running on an arceX root (arcex-root); stage the update from the installed system"

    update_dir="/var/lib/arcex/updates"
    install -d -m 0755 "$update_dir"

    if [[ -f "$update_dir/$name" ]] && cmp -s "$update_dir/$name" "$SRC"; then
        echo "already staged :: $update_dir/$name"
    else
        echo "staging /usr image :: $update_dir/$name"
        install -m 0644 "$SRC" "$update_dir/$name"
    fi

    if [[ -n "$UKI" ]]; then
        [[ -e "$UKI" ]] || die "--uki: $UKI does not exist"
        uki_name="$(basename "$UKI")"
        case "$uki_name" in
            arcex_*_*.efi|arcex_*_*.efi.zst) ;;
            *) die "--uki: expected arcex_<version>_<arch>.efi(.zst), got: $uki_name" ;;
        esac
        if [[ -f "$update_dir/$uki_name" ]] && cmp -s "$update_dir/$uki_name" "$UKI"; then
            echo "already staged :: $update_dir/$uki_name"
        else
            echo "staging UKI :: $update_dir/$uki_name"
            install -m 0644 "$UKI" "$update_dir/$uki_name"
        fi
    fi

    # Arm the marker on the ESP so grub boots the recovery UKI next time.
    esp="$(lsblk -ln -o PATH,PARTLABEL | awk '$2 == "arcex-esp" { print $1; exit }')"
    [[ -n "$esp" ]] ||
        esp="$(lsblk -ln -o PATH,PARTTYPENAME | awk '$2 == "EFI System" { print $1; exit }')"
    [[ -n "$esp" ]] || die "no ESP found on this system"

    esp_mnt="$(findmnt -rn -S "$esp" -o TARGET 2>/dev/null || true)"
    mounted=0
    if [[ -z "$esp_mnt" ]]; then
        esp_mnt="/mnt/arcex-esp"
        mkdir -p "$esp_mnt"
        mount "$esp" "$esp_mnt" || die "failed to mount ESP ($esp) rw at $esp_mnt"
        mounted=1
    fi
    install -d "$esp_mnt/EFI/updates"
    : > "$esp_mnt/EFI/updates/arcex.update"
    sync
    echo "armed pre-boot update :: $esp_mnt/EFI/updates/arcex.update"
    if [[ $mounted -eq 1 ]]; then
        umount "$esp_mnt" || echo "warning: could not unmount ESP ($esp_mnt)" >&2
    fi

    echo "stage complete - reboot into the recovery updater to apply:"
    echo "  sudo reboot"
    exit 0
fi

# ---------------------------------------------------------------------------
# In-place mode (default): write the /usr image directly onto <disk>.
# ---------------------------------------------------------------------------
[[ $# -eq 2 ]] || { usage; exit 1; }
DISK="$1"
SRC="$2"

[[ -b "$DISK" ]] || die "$DISK is not a block device"
[[ -e "$SRC" ]] || die "$SRC does not exist"
DISK_ABS="$(readlink -f "$DISK")"
[[ -e "/sys/class/block/${DISK_ABS##*/}/partition" ]] &&
    die "$DISK is a partition; pass the whole disk (e.g. /dev/sda)"

USR="$(lsblk -ln -o PATH,PARTLABEL,TYPE "$DISK_ABS" |
        awk 'NF >= 3 && $2 == "arcex-usr" && $3 == "part" { print $1; exit }')"
[[ -n "$USR" ]] || die "no arcex-usr partition found on $DISK"
echo "using /usr partition :: $USR"

findmnt -rn -S "$USR" >/dev/null 2>&1 &&
    die "$USR is mounted; unmount it (boot from a live/rescue system) first"

BOOTROOT="$(findmnt -n -o SOURCE / 2>/dev/null | sed -E 's/[0-9]+$//' || true)"
if [[ -b "$BOOTROOT" && "$(readlink -f "$BOOTROOT")" == "$DISK_ABS" ]]; then
    die "$DISK is the boot device of the running system; run from a live/rescue system"
fi

case "$SRC" in
    *.zst) SRC_SIZE="$(zstd -qdc --no-progress "$SRC" 2>/dev/null | wc -c)"
           SRC_HASH="$(zstd -qdc --no-progress "$SRC" 2>/dev/null | sha256sum | cut -d' ' -f1)" ;;
    *)     SRC_SIZE="$(stat -c %s "$SRC")"
           SRC_HASH="$(sha256sum "$SRC" | cut -d' ' -f1)" ;;
esac

NBYTES="$SRC_SIZE"
BLOCK=$((4 * 1024 * 1024))
BLOCKS=$(( (NBYTES + BLOCK - 1) / BLOCK ))

hash_used() {
    local h
    h="$(dd if="$1" bs="$BLOCK" count="$BLOCKS" status=none 2>/dev/null |
         head -c "$NBYTES" | sha256sum | cut -d' ' -f1)" || :
    [[ -n "$h" ]] || die "failed to read $1"
    printf '%s\n' "$h"
}

USR_SIZE="$(blockdev --getsize64 "$USR")"
if (( SRC_SIZE > USR_SIZE )); then
    echo "new /usr ($SRC_SIZE bytes) is larger than the installed /usr ($USR_SIZE bytes)"
    if grow_usr_trailing "$DISK_ABS" "$USR" "$(( SRC_SIZE - USR_SIZE ))"; then
        USR="$(lsblk -ln -o PATH,PARTLABEL,TYPE "$DISK_ABS" |
               awk 'NF >= 3 && $2 == "arcex-usr" && $3 == "part" { print $1; exit }')"
        USR_SIZE="$(blockdev --getsize64 "$USR")"
        echo "resolved /usr partition :: $USR ($USR_SIZE bytes)"
    else
        die "no free space before root to grow /usr in place; use 'update.sh --stage' + reboot so the recovery updater can retry, or re-flash a larger /usr"
    fi
fi

echo "new /usr image :: ${SRC_SIZE} bytes, sha256 ${SRC_HASH:0:16}…"
echo "target  /usr  :: ${USR_SIZE} bytes on $USR (${SRC_SIZE} bytes used for update)"

CUR_HASH="$(hash_used "$USR")"
if [[ "$CUR_HASH" == "$SRC_HASH" ]]; then
    echo "already up to date - nothing to write"
    exit 0
fi

echo "updating /usr partition in place (no re-flash)…"
WROTE=0
if [[ $DRY_RUN -eq 0 ]]; then
    case "$SRC" in
        *.zst) zstd -qdc --no-progress "$SRC" 2>/dev/null |
               dd of="$USR" bs=4M conv=fsync status=progress ;;
        *)     dd if="$SRC" of="$USR" bs=4M conv=fsync status=progress ;;
    esac
    WROTE=1
else
    echo "dry-run: skipping write"
fi

if [[ $WROTE -eq 1 ]]; then
    AFTER_HASH="$(hash_used "$USR")"
    [[ "$AFTER_HASH" == "$SRC_HASH" ]] ||
        die "verify failed after write: partition hash ${AFTER_HASH:0:16} != source ${SRC_HASH:0:16}"
    echo "ok - /usr updated and verified"
fi

if [[ -n "$UKI" ]]; then
    [[ $DRY_RUN -eq 1 ]] && { echo "dry-run: skipping --uki sync"; exit 0; }
    [[ -e "$UKI" ]] || die "--uki: $UKI does not exist"
    ESP="$(lsblk -ln -o PATH,PARTTYPENAME "$DISK_ABS" |
           awk 'NF >= 2 && $2 == "EFI System" { print $1; exit }')"
    [[ -n "$ESP" ]] || die "no ESP partition found on $DISK"
    ESP_MNT="$(findmnt -rn -S "$ESP" -o TARGET 2>/dev/null || true)"
    [[ -n "$ESP_MNT" ]] || die "ESP ($ESP) is not mounted; mount it read-write and rerun --uki"
    [[ -d "$ESP_MNT/EFI/Linux" ]] || die "no EFI/Linux dir on $ESP_MNT - not an arceX ESP?"
    name="$(basename "$UKI")"; name="${name%.zst}"; dst="$ESP_MNT/EFI/Linux/$name"
    case "$UKI" in
        *.zst) UKI_HASH="$(zstd -qdc --no-progress "$UKI" 2>/dev/null | sha256sum | cut -d' ' -f1)" ;;
        *)     UKI_HASH="$(sha256sum "$UKI" | cut -d' ' -f1)" ;;
    esac
    if [[ -f "$dst" ]] &&
       [[ "$(sha256sum "$dst" | cut -d' ' -f1)" == "$UKI_HASH" ]]; then
        echo "uki already current :: $ESP_MNT $name"
    else
        echo "updating uki :: $ESP_MNT $name"
        mkdir -p "$ESP_MNT/EFI/Linux"
        case "$UKI" in
            *.zst) zstd -qdc --no-progress "$UKI" 2>/dev/null > "$dst" ;;
            *)     cp -f "$UKI" "$dst" ;;
        esac
        sync
    fi
fi